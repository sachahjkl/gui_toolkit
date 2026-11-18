#+build windows
package tk_http

// A stream and a socket on WinHTTP's asynchronous mode: a wait that runs out, or a stop, leaves the operation in flight
// instead of ending the connection (its synchronous calls cannot be left). A Job holds the handles, the buffer an
// operation writes to and the events its callback sets. src/md/features/streams.md says why.

import "base:intrinsics"
import "core:strings"
import "core:sync"
import "core:time"
import win "core:sys/windows"

foreign import winhttp_async "system:Winhttp.lib"

@(private) Status_Callback :: #type proc "system" (h: HINTERNET, ctx: uintptr, status: u32, info: rawptr, info_length: u32)

@(default_calling_convention = "system", private)
foreign winhttp_async {
	WinHttpSetStatusCallback :: proc(h: HINTERNET, callback: Status_Callback, flags: u32, reserved: uintptr) -> uintptr ---
	WinHttpSetOption :: proc(h: HINTERNET, option: u32, buffer: rawptr, length: u32) -> win.BOOL ---
	WinHttpWebSocketCompleteUpgrade :: proc(h: HINTERNET, ctx: uintptr) -> HINTERNET ---
	WinHttpWebSocketSend :: proc(ws: HINTERNET, buffer_type: u32, buffer: rawptr, length: u32) -> u32 ---
	WinHttpWebSocketReceive :: proc(ws: HINTERNET, buffer: rawptr, length: u32, read: ^u32, buffer_type: ^u32) -> u32 ---
	WinHttpWebSocketShutdown :: proc(ws: HINTERNET, status: u16, reason: rawptr, reason_length: u32) -> u32 ---
	WinHttpWebSocketQueryCloseStatus :: proc(ws: HINTERNET, status: ^u16, reason: rawptr, reason_length: u32, consumed: ^u32) -> u32 ---
}

@(private) WINHTTP_FLAG_ASYNC                        :: 0x1000_0000
@(private) WINHTTP_OPTION_CONTEXT_VALUE              :: 45
@(private) WINHTTP_OPTION_RECEIVE_TIMEOUT            :: 7
@(private) WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET      :: 114
@(private) WINHTTP_INVALID_STATUS_CALLBACK           :: ~uintptr(0)
@(private) WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS     :: 0x017E_0000
@(private) WINHTTP_CALLBACK_FLAG_HANDLES             :: 0x0000_0C00
@(private) WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING    :: 0x0000_0800
@(private) WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE :: 0x0002_0000
@(private) WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE    :: 0x0004_0000
@(private) WINHTTP_CALLBACK_STATUS_READ_COMPLETE     :: 0x0008_0000
@(private) WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE    :: 0x0010_0000
@(private) WINHTTP_CALLBACK_STATUS_REQUEST_ERROR     :: 0x0020_0000
@(private) WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE :: 0x0040_0000
@(private) WEB_SOCKET_SEND_OPERATION                 :: 0
@(private) WEB_SOCKET_BINARY_MESSAGE                 :: 0
@(private) WEB_SOCKET_BINARY_FRAGMENT                :: 1
@(private) WEB_SOCKET_UTF8_MESSAGE                   :: 2
@(private) WEB_SOCKET_UTF8_FRAGMENT                  :: 3
@(private) WEB_SOCKET_CLOSE                          :: 4

// A wait of a Job looks at a Stop flag this often.
@(private) STOP_POLL_MS :: 250
// How long job_end waits for WinHTTP's last callbacks before it leaks the Job rather than free it under them.
@(private) JOB_END_LIMIT_MS :: 10_000
@(private) JOB_CHUNK :: 64 * 1024

@(private)
Async_Result :: struct {
	result: uintptr,
	error:  u32,
}

@(private)
Web_Socket_Async_Result :: struct {
	async:     Async_Result,
	operation: i32,
}

@(private)
Web_Socket_Status :: struct {
	bytes: u32,
	kind:  i32,
}

@(private)
Job :: struct {
	session, connect, request, socket: HINTERNET,
	chunk:        []u8,         // where a read or a receive in flight writes: freed after the last callback
	done:         win.HANDLE,   // auto-reset: a step of the handshake, a read or a receive completed (or failed)
	sent:         win.HANDLE,   // auto-reset: a WebSocket send completed (or failed)
	stop:         win.HANDLE,   // manual-reset: ws_stop
	closed:       win.HANDLE,   // manual-reset: the last of our handles said HANDLE_CLOSING
	open:         i32,          // atomic: our handles (the request, the socket) not yet closing
	failure:      u32,          // done's: 0, or the error of the operation
	bytes:        u32,          // done's: what a read or a receive gave
	kind:         i32,          // done's: a receive's buffer type
	send_failure: u32,          // sent's
}

// WinHTTP's threads. The handles that carry the job as their context are the request and the socket; the session's and
// the connection's callbacks have none.
@(private = "file")
on_status :: proc "system" (h: HINTERNET, ctx: uintptr, status: u32, info: rawptr, info_length: u32) {
	j := (^Job)(rawptr(ctx))
	if j == nil { return }
	switch status {
	case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE, WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
		j.failure = 0
		win.SetEvent(j.done)
	case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
		j.failure = 0
		j.bytes = (^u32)(info)^
		win.SetEvent(j.done)
	case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
		j.failure = 0
		if h == j.socket {
			st := (^Web_Socket_Status)(info)
			j.bytes, j.kind = st.bytes, st.kind
		} else {
			j.bytes = info_length
		}
		win.SetEvent(j.done)
	case WINHTTP_CALLBACK_STATUS_WRITE_COMPLETE:
		j.send_failure = 0
		win.SetEvent(j.sent)
	case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
		if h == j.socket {
			r := (^Web_Socket_Async_Result)(info)
			if r.operation == WEB_SOCKET_SEND_OPERATION {
				j.send_failure = max(r.async.error, 1)
				win.SetEvent(j.sent)
			} else {
				j.failure = max(r.async.error, 1)
				win.SetEvent(j.done)
			}
		} else {
			r := (^Async_Result)(info)
			j.failure = max(r.error, 1)
			win.SetEvent(j.done)
		}
	case WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING:
		if intrinsics.atomic_sub(&j.open, 1) == 1 { win.SetEvent(j.closed) }
	}
}

// The session, the connection and the request of `method` to `u`, asynchronous, with req's headers; the request carries
// the job as its context.
@(private)
job_start :: proc(method: string, u: Url, req: Request) -> (j: ^Job, err: Error) {
	j = new(Job)
	j.chunk = make([]u8, JOB_CHUNK)
	j.done = win.CreateEventW(nil, false, false, nil)
	j.sent = win.CreateEventW(nil, false, false, nil)
	j.stop = win.CreateEventW(nil, true, false, nil)
	j.closed = win.CreateEventW(nil, true, false, nil)
	if j.done == nil || j.sent == nil || j.stop == nil || j.closed == nil { job_end(j); return nil, .Unreachable }
	agent := req.user_agent != "" ? req.user_agent : "tk_http"
	j.session = WinHttpOpen(win.utf8_to_wstring(agent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, nil, nil, WINHTTP_FLAG_ASYNC)
	if j.session == nil { job_end(j); return nil, .Unreachable }
	if WinHttpSetStatusCallback(j.session, on_status, WINHTTP_CALLBACK_FLAG_ALL_COMPLETIONS | WINHTTP_CALLBACK_FLAG_HANDLES, 0) == WINHTTP_INVALID_STATUS_CALLBACK {
		job_end(j)
		return nil, .Unreachable
	}
	winhttp_timeouts(j.session, req)
	j.connect = WinHttpConnect(j.session, win.utf8_to_wstring(u.host), u16(u.port), 0)
	if j.connect == nil { job_end(j); return nil, .Unreachable }
	j.request = WinHttpOpenRequest(j.connect, win.utf8_to_wstring(method), win.utf8_to_wstring(u.path), nil, nil, nil, u.secure ? WINHTTP_FLAG_SECURE : 0)
	if j.request == nil { job_end(j); return nil, .Unreachable }
	ctx := uintptr(j)
	if !WinHttpSetOption(j.request, WINHTTP_OPTION_CONTEXT_VALUE, &ctx, size_of(ctx)) {
		WinHttpCloseHandle(j.request)   // (no context: no callback of it to wait for)
		j.request = nil
		job_end(j)
		return nil, .Unreachable
	}
	sync.atomic_add(&j.open, 1)
	winhttp_compression(j.request, req)
	for hd in req.headers {
		line := win.utf8_to_wstring(strings.concatenate({hd.name, ": ", hd.value}, context.temp_allocator))
		if !WinHttpAddRequestHeaders(j.request, line, WINHTTP_NO_LENGTH, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE) { job_end(j); return nil, .Bad_Request }
	}
	return j, .None
}

@(private)
Job_Wait :: enum {
	Done,
	Stopped,
	Timed_Out,
}

// Until `event`, the job's stop event (when `stoppable`), `stop` asked, or the deadline.
@(private)
job_wait :: proc(j: ^Job, event: win.HANDLE, deadline: time.Tick, bounded: bool, stoppable: bool, stop: ^Stop) -> Job_Wait {
	handles := [2]win.HANDLE{event, j.stop}
	for {
		slice := STOP_POLL_MS
		if bounded { slice = min(slice, ms_left(deadline, true)) }
		r := win.WaitForMultipleObjects(stoppable ? 2 : 1, &handles[0], false, u32(slice))
		switch {
		case r == win.WAIT_OBJECT_0:     return .Done
		case r == win.WAIT_OBJECT_0 + 1: return .Stopped
		case r != win.WAIT_TIMEOUT:      return .Stopped   // (a failed wait: give up)
		}
		if stop_asked(stop) { return .Stopped }
		if bounded && ms_left(deadline, true) == 0 { return .Timed_Out }
	}
}

// Sends the request, with `body` (receive's POST), and waits for its answer's headers: its status. The body is read by
// WinHTTP until the send completes, which this waits for.
@(private)
job_handshake :: proc(j: ^Job, stoppable: bool, stop: ^Stop, body: []u8 = nil) -> (status: int, err: Error) {
	data: rawptr = len(body) > 0 ? rawptr(raw_data(body)) : nil
	if !WinHttpSendRequest(j.request, nil, 0, data, u32(len(body)), u32(len(body)), uintptr(j)) { return 0, .Unreachable }
	if job_wait(j, j.done, {}, false, stoppable, stop) != .Done { return 0, .Stopped }
	if j.failure != 0 { return 0, .Unreachable }
	if !WinHttpReceiveResponse(j.request, nil) { return 0, .Unreachable }
	if job_wait(j, j.done, {}, false, stoppable, stop) != .Done { return 0, .Stopped }
	if j.failure != 0 { return 0, .Unreachable }
	code: u32
	size := u32(size_of(code))
	if !WinHttpQueryHeaders(j.request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, nil, &code, &size, nil) { return 0, .Unreachable }
	return int(code), .None
}

// Closes the handles, waits for their last callbacks, then frees the job. (If they never come, the job is leaked: freed,
// a late callback would write into freed memory.)
@(private)
job_end :: proc(j: ^Job) {
	if j.socket != nil { WinHttpCloseHandle(j.socket) }
	if j.request != nil { WinHttpCloseHandle(j.request) }
	if sync.atomic_load(&j.open) > 0 && win.WaitForSingleObject(j.closed, JOB_END_LIMIT_MS) != win.WAIT_OBJECT_0 { return }
	if j.connect != nil { WinHttpCloseHandle(j.connect) }
	if j.session != nil { WinHttpCloseHandle(j.session) }
	for e in ([]win.HANDLE{j.done, j.sent, j.stop, j.closed}) {
		if e != nil { win.CloseHandle(e) }
	}
	delete(j.chunk)
	free(j)
}

events_system :: proc(url: string, req: Request, parser: ^Event_Parser, on_event: Event_Proc, user: rawptr, stop: ^Stop) -> (status: int, err: Error) {
	u, _ := url_parse(url)
	j: ^Job
	if j, err = job_start("GET", u, req); err != .None { return }
	defer job_end(j)
	if status, err = job_handshake(j, false, stop); err != .None { return }
	if status < 200 || status > 299 { return status, .None }
	for {
		// (what has come first, then that much: a read of a whole chunk waits until the chunk is full, and an open
		// stream's first event, a hundred bytes, never filled one)
		if !WinHttpQueryDataAvailable(j.request, nil) { return status, .Unreachable }
		deadline, bounded := deadline_of(req.timeout)
		switch job_wait(j, j.done, deadline, bounded, false, stop) {
		case .Stopped:   return status, .Stopped
		case .Timed_Out: return status, .Unreachable   // (silence)
		case .Done:
		}
		if j.failure != 0 { return status, .Unreachable }
		if j.bytes == 0 { return status, .None }   // (the server ended the stream)
		if !WinHttpReadData(j.request, raw_data(j.chunk), min(j.bytes, u32(len(j.chunk))), nil) { return status, .Unreachable }
		switch job_wait(j, j.done, deadline, bounded, false, stop) {
		case .Stopped:   return status, .Stopped
		case .Timed_Out: return status, .Unreachable
		case .Done:
		}
		if j.failure != 0 { return status, .Unreachable }
		if j.bytes == 0 { return status, .None }
		if event_parser_feed(parser, j.chunk[:j.bytes], on_event, user) == .Stop {
			return status, parser.too_large ? .Too_Large : .None
		}
	}
}

// receive on the asynchronous job, as a stream: a stop or a silence leaves a read in flight instead of waiting for it.
receive_system :: proc(method, url: string, req: Request, sink: ^Receive_Sink, stop: ^Stop, allocator := context.allocator) -> (res: Response, err: Error) {
	u, _ := url_parse(url)
	if u64(len(req.body)) > 0xFFFF_FFFF { return {}, .Too_Large }   // (WinHTTP counts a body in 32 bits)
	j: ^Job
	if j, err = job_start(method, u, req); err != .None { return }
	defer job_end(j)
	if req.no_redirects {
		policy := u32(WINHTTP_OPTION_REDIRECT_POLICY_NEVER)
		WinHttpSetOption(j.request, WINHTTP_OPTION_REDIRECT_POLICY, &policy, size_of(policy))
	}
	status: int
	if status, err = job_handshake(j, false, stop, req.body); err != .None { return {}, err }
	head := query_text(j.request, WINHTTP_QUERY_RAW_HEADERS_CRLF, false, context.temp_allocator)
	receive_head(sink, status, headers_parse(head, context.temp_allocator), req.compressed)
	reading: if !sink.refused && method != "HEAD" {
		for {
			// (what has come first, then that much: a read of a whole chunk waits until the chunk is full)
			if !WinHttpQueryDataAvailable(j.request, nil) { return {}, .Unreachable }
			deadline, bounded := deadline_of(req.timeout)
			switch job_wait(j, j.done, deadline, bounded, false, stop) {
			case .Stopped:   return {}, .Stopped
			case .Timed_Out: return {}, .Unreachable   // (silence)
			case .Done:
			}
			if j.failure != 0 { return {}, .Unreachable }
			if j.bytes == 0 { break reading }   // (the whole body came)
			if !WinHttpReadData(j.request, raw_data(j.chunk), min(j.bytes, u32(len(j.chunk))), nil) { return {}, .Unreachable }
			switch job_wait(j, j.done, deadline, bounded, false, stop) {
			case .Stopped:   return {}, .Stopped
			case .Timed_Out: return {}, .Unreachable
			case .Done:
			}
			if j.failure != 0 { return {}, .Unreachable }
			if j.bytes == 0 { break reading }
			if !receive_feed(sink, j.chunk[:j.bytes]) {
				if sink.too_large { return {}, .Too_Large }
				break reading   // (the caller's .Stop: its answer stands)
			}
		}
	}
	effective := query_text(j.request, WINHTTP_OPTION_URL, true, context.temp_allocator)
	return receive_response(status, effective != "" ? effective : url, head, allocator), .None
}
