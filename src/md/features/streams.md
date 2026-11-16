# Streams and sockets in `tk_http`

`gt:http` reads a server's event stream (Server-Sent Events) and holds a WebSocket over `ws://` or `wss://`. Three
copies existed: opencode native (ureq and tungstenite, in a Rust library), Wren (its own WebSocket on WinHTTP's
asynchronous API, for its pages) and the toolkit's CDP client (its own frame codec over a plain TCP socket). The CDP
client now uses this package; opencode native can drop ureq and tungstenite for it.

## Decisions

- **The system's client does the connection.** libcurl on Linux, WinHTTP on Windows: the TCP, TLS and its
  certificates, a proxy. On Windows WinHTTP also does the WebSocket (the upgrade, the frames, the pings).
- **On Linux the WebSocket is ours, over curl's raw connection.** `CURLOPT_CONNECT_ONLY` = 1, then `curl_easy_send` and
  `curl_easy_recv` (libcurl 7.18.1): we write the upgrade, check `Sec-WebSocket-Accept` and speak the frames
  (`frame.odin`). Distributions build libcurl without its WebSocket API (nixpkgs: `websocketSupport ? false`; before
  8.11 it was off by default), and `gt:cdp` drives every program's automation through this socket: a dependency on that
  API breaks them on such a machine.
- **One codec in the toolkit.** `frame.odin` is the codec `gt:cdp` had, moved here and made private; its tests came with
  it. `gt:cdp` uses `ws_*`. The devtools server (`src/devtools/server.odin`) speaks the server's side and keeps its own.
- **TLS asks for HTTP/1.1.** `CURL_HTTP_VERSION_1_1` keeps ALPN from agreeing on HTTP/2, where an upgrade does not
  exist. A proxy is a tunnel (`HTTPPROXYTUNNEL`): it carries the bytes and answers nothing for the server.
- **Every call blocks, on a worker.** As `request`. A stream or a socket lives on a thread of its own, never the
  interface's.
- **An event stream is a callback, not a handle.** `events(url, req, on_event, user, stop)` runs until the stream ends.
  libcurl pushes the bytes (`easy_perform` and its write callback); a pull API (`stream_next`) needs curl's multi
  interface or a thread. The callback returns `Keep_Going`: `.Stop` ends the stream at once.
- **The SSE parser is pure.** `Event_Parser` takes bytes in any cut (a CR at the end of one block and its LF at the start
  of the next) and gives events. It follows the WHATWG rules: LF, CRLF or CR end a line; a blank line dispatches; `:`
  starts a comment; `data:` lines join with `\n`; one space after the colon is dropped; `id:` with a NUL is ignored and
  the last id stays for the next events; `retry:` with digits only sets the stream's reconnection time; an event with no
  `data:` line is not dispatched; a BOM at the start is dropped; an event cut by the end of the stream is dropped.
  The event's strings point into the parser: valid during the callback only (no copy per event).
- **No reconnection in the package.** The caller decides when to call `events` again, with `Last-Event-ID` from the last
  `Event.id` and after `Event.retry`. The policy (back-off, a status that means "give up") is the program's.
- **For a stream, `timeout` is the longest silence.** A stream has no end to wait for; a dead connection (a machine that
  slept) only shows as silence. Any byte, a comment (a server's heartbeat) included, restarts the clock. Default
  `STREAM_SILENCE`, 2 minutes. `max_bytes` bounds one line and one event's data.
- **A stream that is not 2xx gives its status and no event.** The body (an error page) is not parsed.
- **A stop from another thread.** `Stop` is a flag (`stop_ask`, atomic). libcurl's progress callback reads it about once
  a second; Windows reads it between waits of 250 ms. Closing a handle from another thread was refused: a use after
  free on a handle the worker still holds.
- **A socket: one reader, any number of senders, one closer.** `ws_recv` on the worker; `ws_send` from any thread (a
  lock, and a frame goes out whole); `ws_stop` from any thread wakes a waiting `ws_recv` at once (Linux: a pipe in the
  `poll`; Windows: an event in the wait); `ws_close` on the worker, after the reader returned. This is opencode native's
  shape: one thread reads, the browser tools send.
- **A wait that runs out keeps the socket.** `ws_recv(s, wait)` gives `.Timed_Out` and the message in progress stays: the
  next call goes on. CDP's `pump` needs it (100 ms waits between screencast frames). On Windows this needs WinHTTP's
  asynchronous mode: its synchronous receive cannot be left without ending the socket.
- **A message is whole.** Fragments are joined (bounded by `max_bytes`). A ping is answered with a pong (Linux: by the
  reader, under the send lock; Windows: by WinHTTP); pings and pongs are not given. A close from the server is echoed
  with its code and given as a `.Close` message; the calls after it are `.Closed`. `data` points into the socket: valid
  until the next `ws_recv`.
- **What is not the protocol ends the socket.** A masked frame from the server, a reserved bit (no extension is asked),
  an unknown opcode, a continuation with no message or a message inside another: `.Closed`. A frame whose head says it
  is larger than `max_bytes` is refused before its bytes come: `.Too_Large`.
- **A refused upgrade is `Refused`.** A server that answers but not with 101 (401, 404), or with a wrong
  `Sec-WebSocket-Accept`, is told apart from one that cannot be reached.
- **The connection has a bound of its own (`Request.connect_timeout`), for a request, a stream and a socket.** A
  program that probes a server (opencode native, at its start) must learn in a second that nothing answers, while the
  request, once connected, may take minutes. 0 keeps `timeout` as the bound (libcurl's own is 300 s, WinHTTP's 60 s with
  no bound on the name's lookup): WinHTTP's lookup bound is set with its connection's, as libcurl's bound covers both.
- **A compressed answer is the system client's work (`Request.compressed`).** libcurl (`CURLOPT_ACCEPT_ENCODING`) and
  WinHTTP (`WINHTTP_OPTION_DECOMPRESSION`) decode as the bytes come, so a stream is decoded event by event and
  `max_bytes` counts decoded bytes. Both ask for `gzip, deflate`, what WinHTTP decodes: the two systems ask a server the
  same. Refused: our `gt:flate` over the body (a second copy, and a stream would need its own inflater per read). A
  socket ignores it: the handshake has no body.

## Refused alternatives

- **libcurl's WebSocket API (`curl_ws_*`, `CONNECT_ONLY` = 2).** The first version used it: the frames were curl's. It
  is missing from libcurl before 7.86 and from the many builds without `--enable-websockets` (nixpkgs' among them), and
  the CDP client cannot fail on them.
- **Our own socket over `core:net`.** What CDP had: no TLS, no proxy. curl's raw connection gives both.
- **A Rust crate (tungstenite, ureq).** A second toolchain and a static library per program, and its own TLS beside the
  system's certificates.
- **Wren's asynchronous manager.** A page's WebSocket (back-pressure, queued handshakes per host, a loop thread) is a
  browser's need. A program needs a blocking socket on a worker. Wren keeps its own.

## Subtle points

- `curl_easy_recv` never blocks: `CURLE_AGAIN` means "poll the socket". It is asked before any poll: TLS may hold
  decrypted bytes that the socket no longer shows, and a poll first would wait for bytes already there. A recv of 0
  bytes with no error is the server's end of the connection.
- `curl_easy_send` can send part of a frame: the rest goes in the next call, the lock held, so that two senders' frames
  never mix.
- The socket comes from `CURLINFO_ACTIVESOCKET` (7.45), else `CURLINFO_LASTSOCKET` (a long, before it).
- A client frame's mask is random (`crypto.rand_bytes`), as RFC 6455 asks: a proxy must not read a request in it.
- WinHTTP's callbacks run on its threads and can come after a handle is closed, until its `HANDLE_CLOSING`. The job that
  holds the buffers is freed after the last one; if it never comes (bounded wait), the job is leaked, not freed under
  WinHTTP.
