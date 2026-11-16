# Connections reused by `gt:http`'s requests

`http.request` and `http.get` keep their connections open and reuse them for the next request to the same server. Each
request made its own connection before (0.287.0 to 0.288.1): libcurl's easy handle was made and cleaned per request,
and WinHTTP's session was opened and closed per request, and each one holds its connection cache. opencode native moved
from ureq (a connection pool) to `gt:http` in its 0.63.0, and a remote server behind a TLS tunnel became slow: a TCP
connection and a TLS handshake per request, dozens of requests per screen.

## Decisions

- **One pool for the process, and no client object.** Every `request` reuses connections; a program changes nothing.
  `http.Client`, kept by the program and given to each call, was refused: every program wants reuse, and a program
  that forgets its client gets the old cost again. No request needs to be kept apart from another one: no cookie is
  kept, and each request gives its own headers.
- **Linux: a stack of idle easy handles, one thread per handle at a time.** A request takes an idle handle that last
  spoke to the same origin (scheme, host and port), else it makes a new one. After the request, `curl_easy_reset` clears
  the options and keeps the connections, and the handle goes back to the stack. The number of connections to one server
  is then the number of requests to it that run at the same time.
- **Refused on Linux: libcurl's share interface with `CURL_LOCK_DATA_CONNECT`.** Its documentation says that sharing
  connections between concurrent threads is not supported. A handle per request in flight needs no lock around libcurl.
- **Bounded idle connections.** At most `POOL_IDLE` handles wait in the stack. A handle returned to a full stack ends
  the oldest one and its connections. libcurl keeps at most 5 connections per handle and does not reuse a connection
  that was idle for longer than 118 s (`CURLOPT_MAXAGE_CONN`).
- **Windows: one WinHTTP session for the process.** WinHTTP pools the connections of a session by server.
  `WinHttpConnect` and `WinHttpOpenRequest` stay per request: they make no connection. The time limits go on the
  request handle, and a request's `user_agent` goes as its `User-Agent` header (the session's agent is `tk_http`).
- **Keep-alive is the default of both clients** (HTTP/1.1). A reused connection that the server or a tunnel closed
  while it was idle is detected by the client, which connects again for that request.
- **An event stream and a WebSocket keep a connection of their own.** They hold it for their whole life, and the
  pool's connections are for requests that end.

## Subtle points

- The origin match makes the reuse independent of the order in which threads return handles. Without it, a request
  takes the handle that another thread returned last, which holds a connection to another server.
- `curl_easy_reset` runs when the handle goes back to the stack. The handle then holds no pointer to the request's
  buffers, its header list or its sink.
- A request whose answer is larger than `max_bytes` ends with its connection closed by the client. The next request
  connects again.

## The test

`connection_test.odin`: a server on the loopback that keeps its connections open and counts the sockets it accepts.
Five requests in a row open one connection. Four threads that make five requests each open four connections at most.
