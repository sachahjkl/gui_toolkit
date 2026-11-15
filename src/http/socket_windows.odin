#+build windows
package tk_http

// A WebSocket on WinHTTP's own (WinHttpWebSocket*), asynchronous: the Job of stream_windows.odin. A receive whose wait
// ran out stays in flight; the next ws_recv waits for it again.

import "core:sync"
import "core:time"
import win "core:sys/windows"

Socket :: struct {
	job:        ^Job,
	lock:       sync.Mutex,   // one send at a time: WinHTTP takes one in flight
	stopped:    bool,         // atomic
	closed:     bool,         // the reader's: a close came, or the connection ended
	pending:    bool,         // the reader's: a receive is in flight (a wait ran out before it completed)
	max_bytes:  int,
	buf:        [dynamic]u8,  // the message being read, then the one given
	kind:       Message_Kind,
	assembling: bool,         // a message's first fragment was read and not its last
}

ws_connect_system :: proc(url, http_url: string, req: Request) -> (^Socket, Error) {
	u, _ := url_parse(http_url)
	j, err := job_start("GET", u, req)
	if err != .None { return nil, err }
	if !WinHttpSetOption(j.request, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, nil, 0) { job_end(j); return nil, .Unreachable }
	status: int
	if status, err = job_handshake(j, false, nil); err != .None { job_end(j); return nil, err }
	if status != 101 { job_end(j); return nil, .Refused }
	j.socket = WinHttpWebSocketCompleteUpgrade(j.request, uintptr(j))
	if j.socket == nil { job_end(j); return nil, .Unreachable }
	sync.atomic_add(&j.open, 1)
	WinHttpCloseHandle(j.request)   // (the socket lives on without it)
	j.request = nil
	// (the handshake's time limit is not a socket's: a socket may stay silent as long as it lives)
	forever := u32(0)
	WinHttpSetOption(j.socket, WINHTTP_OPTION_RECEIVE_TIMEOUT, &forever, size_of(forever))
	s := new(Socket)
	s.job, s.max_bytes = j, req.max_bytes
	s.buf = make([dynamic]u8)
	return s, .None
}

ws_recv_system :: proc(s: ^Socket, wait: time.Duration) -> (Message, Error) {
	if s.closed { return {}, .Closed }
	if !s.assembling { clear(&s.buf) }
	deadline, bounded := deadline_of(wait)
	j := s.job
	for {
		if sync.atomic_load(&s.stopped) { return {}, .Stopped }
		if !s.pending {
			if WinHttpWebSocketReceive(j.socket, raw_data(j.chunk), u32(len(j.chunk)), nil, nil) != 0 {
				s.closed, s.assembling = true, false
				return {}, .Closed
			}
			s.pending = true
		}
		switch job_wait(j, j.done, deadline, bounded, true, nil) {
		case .Stopped:   return {}, .Stopped
		case .Timed_Out: return {}, .Timed_Out   // (the receive stays in flight, the message in progress in buf)
		case .Done:
		}
		s.pending = false
		if j.failure != 0 { s.closed, s.assembling = true, false; return {}, .Closed }
		switch j.kind {
		case WEB_SOCKET_CLOSE:
			s.closed, s.assembling = true, false
			clear(&s.buf)
			status: u16
			reason: [123]u8   // (RFC 6455: a close's reason fits in 123 bytes)
			consumed: u32
			code := 1005
			if WinHttpWebSocketQueryCloseStatus(j.socket, &status, &reason[0], len(reason), &consumed) == 0 {
				code = int(status)
				append(&s.buf, ..reason[:min(int(consumed), len(reason))])
			}
			return Message{.Close, s.buf[:], code}, .None
		case WEB_SOCKET_BINARY_MESSAGE, WEB_SOCKET_BINARY_FRAGMENT, WEB_SOCKET_UTF8_MESSAGE, WEB_SOCKET_UTF8_FRAGMENT:
			if !s.assembling {
				s.kind = j.kind == WEB_SOCKET_UTF8_MESSAGE || j.kind == WEB_SOCKET_UTF8_FRAGMENT ? .Text : .Binary
				s.assembling = true
			}
			if len(s.buf) + int(j.bytes) > s.max_bytes { s.closed, s.assembling = true, false; return {}, .Too_Large }
			append(&s.buf, ..j.chunk[:j.bytes])
			if j.kind == WEB_SOCKET_BINARY_MESSAGE || j.kind == WEB_SOCKET_UTF8_MESSAGE {
				s.assembling = false
				return Message{s.kind, s.buf[:], 0}, .None
			}
		}
	}
}

ws_send_system :: proc(s: ^Socket, data: []u8, kind: Message_Kind) -> Error {
	if u64(len(data)) > 0xFFFF_FFFF { return .Too_Large }   // (WinHTTP counts a message in 32 bits)
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	if sync.atomic_load(&s.stopped) { return .Stopped }
	j := s.job
	kind_of := u32(kind == .Binary ? WEB_SOCKET_BINARY_MESSAGE : WEB_SOCKET_UTF8_MESSAGE)
	if WinHttpWebSocketSend(j.socket, kind_of, raw_data(data), u32(len(data))) != 0 { return .Closed }
	// (WinHTTP reads `data` until the send completes: a stop does not cut this wait; WinHTTP's send time limit bounds it)
	job_wait(j, j.sent, {}, false, false, nil)
	return j.send_failure != 0 ? .Closed : .None
}

ws_stop_system :: proc(s: ^Socket) {
	sync.atomic_store(&s.stopped, true)
	win.SetEvent(s.job.stop)
}

ws_close_system :: proc(s: ^Socket) {
	j := s.job
	// (1000: a normal close; the server's answer is not awaited: closing the handle ends the receive in flight)
	if !s.closed { WinHttpWebSocketShutdown(j.socket, 1000, nil, 0) }
	job_end(j)
	delete(s.buf)
	free(s)
}
