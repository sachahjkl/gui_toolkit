package tk_http

// WebSockets over ws:// and wss://, with the system's client (libcurl, WinHTTP): the handshake, the frames and TLS are
// theirs. One thread reads (ws_recv) and closes (ws_close); any thread sends (ws_send) or stops (ws_stop).
// src/md/features/streams.md says why.

import "core:strings"
import "core:time"

Message_Kind :: enum {
	Text,
	Binary,
	Close,   // the server closed the socket: `code` and its reason in `data`; the calls after it are .Closed
}

// One whole message (its fragments joined). `data` points into the socket: valid until the next ws_recv.
Message :: struct {
	kind: Message_Kind,
	data: []u8,
	code: int,   // .Close: the server's close code (1000: normal; 1005: none given)
}

// (Socket: the system's own struct, in socket_linux.odin, socket_windows.odin and socket_other.odin)

// A WebSocket to `url` (ws:// or wss://). `req.headers` go with the handshake (Authorization); `req.timeout` bounds the
// handshake (0: TIMEOUT); `req.max_bytes` bounds one message (0: MAX_BYTES). No redirect is followed.
ws_connect :: proc(url: string, req := Request{}) -> (s: ^Socket, err: Error) {
	// (url_parse knows http and https: the same address with the scheme of its handshake)
	http_url: string
	switch {
	case strings.has_prefix(url, "ws://"):  http_url = strings.concatenate({"http://", url[len("ws://"):]}, context.temp_allocator)
	case strings.has_prefix(url, "wss://"): http_url = strings.concatenate({"https://", url[len("wss://"):]}, context.temp_allocator)
	case: return nil, .Bad_Url
	}
	if err = request_check("GET", http_url, req); err != .None { return }
	r := req
	if r.max_bytes <= 0 { r.max_bytes = MAX_BYTES }
	if r.timeout <= 0 { r.timeout = TIMEOUT }
	return ws_connect_system(url, http_url, r)
}

// The next whole message. `wait`: the longest wait (0: no limit); when it runs out, .Timed_Out and the socket stays
// open (a message in progress goes on at the next call). Pings are answered by the system's client and not given. A
// message larger than max_bytes ends the socket: .Too_Large.
ws_recv :: proc(s: ^Socket, wait: time.Duration = 0) -> (m: Message, err: Error) {
	return ws_recv_system(s, wait)
}

// Sends one message, .Text or .Binary (a .Close is ws_close's). Any thread: the sends are one at a time.
ws_send :: proc(s: ^Socket, data: []u8, kind := Message_Kind.Text) -> Error {
	if kind == .Close { return .Bad_Request }
	return ws_send_system(s, data, kind)
}

// Any thread: a ws_recv that waits returns .Stopped at once, and every call after it too. The socket stays to close.
ws_stop :: proc(s: ^Socket) { ws_stop_system(s) }

// Sends the close (1000) if the socket is still open, then frees it. The reader's thread, after its last ws_recv; no
// other thread may use the socket during it or after.
ws_close :: proc(s: ^Socket) {
	if s != nil { ws_close_system(s) }
}

// Where a wait ends: now + wait, or never (wait 0).
@(private)
deadline_of :: proc(wait: time.Duration) -> (deadline: time.Tick, bounded: bool) {
	if wait <= 0 { return {}, false }
	return time.tick_add(time.tick_now(), wait), true
}

// The milliseconds left until `deadline`, at least 0; -1: no deadline.
@(private)
ms_left :: proc(deadline: time.Tick, bounded: bool) -> int {
	if !bounded { return -1 }
	left := time.tick_diff(time.tick_now(), deadline)
	return max(int(time.duration_milliseconds(left) + 0.999), 0)
}
