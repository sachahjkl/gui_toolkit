# http: requests over HTTP and HTTPS, event streams, WebSockets

`import http "gt:http"` (the package is named `tk_http`: a program may have an `http` package of its own). Requests over
HTTP or HTTPS with what the system has: WinHTTP on Windows (its proxy settings and certificates), libcurl on Linux, loaded at
run time (`libcurl.so.4`: a program that never asks for a URL starts on a system without it). Every request blocks: call it
on a thread of its own.

## A GET

```odin
status, body, err := http.get("https://github.com/me/app/releases/latest/download/update-linux-x64.json",
                              {max_bytes = 16 * 1024, user_agent = "app/1.2.3", timeout = 30 * time.Second})
```

- Redirects are followed (at most `MAX_REDIRECTS`; Windows never follows https to http).
- `status` is the status of the last answer. A status that is not 2xx is no error: the caller reads it (404: no such file).
- `max_bytes` bounds the body (0: `MAX_BYTES`, 64 MiB): a larger one is `.Too_Large`, and nothing is returned.
- `timeout` bounds the whole request (0: `TIMEOUT`, 5 minutes).
- `connect_timeout` bounds the name's lookup and the connection, each time one is made (a redirect to another host makes
  one). 0: `timeout` bounds them. A server that does not answer is `.Unreachable` after it, not after the whole
  `timeout`.
- `compressed = true` asks for a compressed answer (`Accept-Encoding: gzip, deflate`, `ACCEPT_ENCODING`) and gives the
  body decoded; `max_bytes` bounds the decoded body. The answer's headers say what came (`Content-Encoding`). An
  `Accept-Encoding` header in `headers` with `compressed` false is sent as given, and its body is given as it came.

```odin
res, err := http.request("GET", "http://127.0.0.1:4096/session", {compressed = true, connect_timeout = 2 * time.Second})
```

## Any request

```odin
form, content_type := http.multipart({
	http.form_text("reqtype", "fileupload"),
	http.form_file("fileToUpload", "shot.png", "image/png", png),
}, context.temp_allocator)
res, err := http.request("POST", "https://example.com/upload", {
	headers = {{"Content-Type", content_type}, {"Authorization", "Bearer ..."}},
	body    = form,
})
defer http.response_destroy(&res)
location, found := http.header_value(res.headers, "Location")
```

- `request(method, url, req)`: any method that is a token (GET, POST, PUT, PATCH, DELETE, HEAD...). `get` is a call of it.
- `Request.headers` are sent as given; a header the caller names replaces the client's own (the User-Agent too). Nothing
  is added to a body: without a `Content-Type` header, none is sent (libcurl's form type and its `Expect: 100-continue`
  are removed).
- `Request.body`: nil sends none; POST, PUT and PATCH send an empty one then.
- A method that is not a token, a header name that is not a token, or a header value with a line break is `.Bad_Request`,
  before anything is sent.
- `Response`: `status`, `body`, `headers` (the last answer's, in order), `url` (the address that answered, after the
  redirects), `header_text` (the lines as received). `response_destroy` frees it, with the request's allocator.
- `header_value(headers, name)`: the first header of that name; names compare without case.
- A redirect of a request with a body is followed as browsers do: 303 (and 301, 302 after a POST) becomes a GET.

## Form bodies

Pure procedures: no system call, testable anywhere.

- `multipart(fields)` gives a `multipart/form-data` body and its `Content-Type` with the boundary. A `Form_Field` is a text
  (`form_text(name, value)`) or a file (`form_file(name, file_name, content_type, bytes)`; an empty content type is
  `application/octet-stream`). The boundary is random and occurs in no field. A quote or a line break in a name or file
  name is written `%22`, `%0D`, `%0A`, as browsers do.
- `form_urlencoded(params)` gives an `application/x-www-form-urlencoded` body from `Param`s: `a=1&b=x+y`.
- `query_append(url, params)` adds params to a URL's query string (`?` or `&`, before a fragment).
- `form_encode(s)` encodes one name or value: letters, digits and `*-._` stay, a space is `+`, any other byte is `%XX`.
- `component_encode(s)` encodes one part of a URL (a path's segment, a query's value outside a form): RFC 3986's
  unreserved characters (letters, digits, `-._~`) stay, any other byte is `%XX` (a space `%20`, a slash `%2F`).

## A server's event stream

```odin
on_event :: proc(user: rawptr, e: http.Event) -> http.Keep_Going {
	fmt.println(e.type, e.data)   // e's strings are valid during the call only
	return .Continue
}
stop: http.Stop                  // another thread: http.stop_ask(&stop)
status, err := http.events("https://host/event", {headers = {{"Authorization", auth}}}, on_event, nil, &stop)
```

- `events(url, req, on_event, user, stop)` reads a Server-Sent Events stream (GET) until the server ends it, `on_event`
  returns `.Stop`, or `stop_ask(&stop)` is called from another thread (seen within about a second: `.Stopped`). Call it
  on a worker.
- `Event`: `type` (`"message"` when the stream names none), `data` (the `data:` lines joined by `\n`), `id` (the last
  `id:` of the stream), `retry` (the last `retry:`, in milliseconds; 0: none).
- `req.timeout` is the longest silence, not the whole stream (0: `STREAM_SILENCE`, 2 minutes). Any byte restarts it: a
  server's heartbeat comment is enough. A silence is `.Unreachable`. `req.max_bytes` bounds one line and one event.
- `req.connect_timeout` bounds the connection (0: the silence does). `req.compressed` asks for a compressed stream,
  decoded as it comes.
- An `Accept: text/event-stream` header is added when `req.headers` has no Accept.
- A status that is not 2xx gives no event and no error: read `status`. The end of the stream is no error either. There
  is no reconnection: call `events` again, with a `Last-Event-ID` header from the last `Event.id`, after `Event.retry`.
- `Event_Parser` (`event_parser_init`, `event_parser_feed`, `event_parser_destroy`) is the parser alone: bytes in any cut,
  the WHATWG rules (LF, CRLF or CR; comments; one space after the colon dropped; an event with no data line not given).

## WebSockets

```odin
s, err := http.ws_connect("wss://host/socket", {headers = {{"Authorization", auth}}})
if err != .None { return }
defer http.ws_close(s)
http.ws_send(s, transmute([]u8)string(`{"hello":1}`))   // any thread
for {
	m, e := http.ws_recv(s)                                // the reader's thread
	if e != .None || m.kind == .Close { break }
	handle(m.data)                                         // valid until the next ws_recv
}
```

- `ws_connect(url, req)`: `ws://` or `wss://`. `req.headers` go with the handshake; `req.timeout` bounds the handshake,
  `req.connect_timeout` its connection (0: `timeout`); `req.max_bytes` bounds one message; `req.compressed` does
  nothing (a handshake has no body). A server that answers without the upgrade is `.Refused`.
- `ws_recv(s, wait)`: the next whole message, `.Text` or `.Binary`; a ping is answered with a pong. `wait` = 0
  waits without limit; when a wait runs out, `.Timed_Out`, and the socket stays open. The server's close is a `.Close`
  message (`code`, the reason in `data`); the calls after it are `.Closed`.
- `ws_send(s, data, kind)`: `.Text` (the default) or `.Binary`, from any thread, one at a time.
- `ws_stop(s)`, from any thread: a waiting `ws_recv` returns `.Stopped` at once, and every call after it too.
- `ws_close(s)`: sends the close (1000) if the socket is open and frees it. Call it on the reader's thread, after its last
  `ws_recv`, when no other thread uses the socket.
- Windows: WinHTTP's WebSocket. Linux: any libcurl (7.18.1 or later), with or without its own WebSocket API: curl makes
  the connection (TLS, a proxy as a tunnel), the package writes the upgrade and the frames.
- A frame that breaks the protocol (masked by the server, an unknown opcode) ends the socket: `.Closed`.

## Errors

`Error`: `No_Client` (Linux without libcurl), `Bad_Url` (not http or https, credentials in the address), `Bad_Request`,
`Unreachable` (the name, the network, TLS, the time limit), `Too_Large`; for streams and sockets `Stopped`, `Timed_Out`,
`Closed` and `Refused` (no upgrade, or a wrong `Sec-WebSocket-Accept`). `error_text` says it in a sentence.

`url_parse` gives the parts of an http or https URL (secure, host, port, path with its query).

The Updater (`docs/update.md`) downloads with it.
