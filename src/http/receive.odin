package tk_http

// A body received in chunks: `receive` gives each chunk of the answer's body to a callback on the request's thread and
// keeps none of it, so a file of any size takes the memory of one chunk. src/md/features/downloads.md says why a
// callback, why silence is its time limit and why no bound by default.

import "core:strconv"
import "core:strings"
import "../ascii"

// One chunk of a body, and how far the transfer is. `bytes` is valid during the callback only (the client reuses its
// buffer).
Body_Part :: struct {
	bytes:    []u8,
	status:   int,   // the answer's (a 2xx: receive gives no chunk of another)
	received: i64,   // the bytes given so far, this chunk's included
	length:   i64,   // the body's length (its Content-Length); -1: not known (none, or Request.compressed)
}

// What receive calls for each chunk, on the request's thread: .Stop ends the transfer at once (receive returns .None).
Part_Proc :: #type proc(user: rawptr, part: Body_Part) -> Keep_Going

// The answer of `method` to `url`, its body given to `on_part` chunk by chunk and kept nowhere. Blocks: call it on a
// worker. The answer is the last one, after the redirects; one that is not 2xx gives no chunk and no Error (its status
// says it, as `request`). `req.timeout` is the longest silence (0: STREAM_SILENCE), not the whole transfer's time;
// `req.max_bytes` bounds the body when it is above 0 (0: no bound; past it: .Too_Large). `stop` (any thread, stop_ask)
// ends it with .Stopped. res holds the status, the headers and the address that answered, never a body; it is empty
// when err != .None.
receive :: proc(method, url: string, req: Request, on_part: Part_Proc, user: rawptr, stop: ^Stop = nil, allocator := context.allocator) -> (res: Response, err: Error) {
	if err = request_check(method, url, req); err != .None { return }
	r := req
	if r.timeout <= 0 { r.timeout = STREAM_SILENCE }
	sink := Receive_Sink{on_part = on_part, user = user, max_bytes = i64(max(r.max_bytes, 0)), length = -1}
	res, err = receive_system(method, url, r, &sink, stop, allocator)
	if err == .None && r.compressed {
		// (as request: a body given decoded says no encoding and no encoded length)
		n := 0
		for h in res.headers {
			if ascii.equal_fold(h.name, "Content-Encoding") || ascii.equal_fold(h.name, "Content-Length") { continue }
			res.headers[n] = h
			n += 1
		}
		res.headers = res.headers[:n]
	}
	return
}

// What one transfer's chunks share with the system's client, on the request's thread.
@(private)
Receive_Sink :: struct {
	on_part:   Part_Proc,
	user:      rawptr,
	max_bytes: i64,    // 0: no bound
	status:    int,    // the answer's, once its head came (0: none yet)
	length:    i64,
	received:  i64,
	refused:   bool,   // not 2xx: no chunk is given
	by_caller: bool,   // on_part said .Stop
	too_large: bool,   // past max_bytes
}

// The head of the answer that is kept (after the redirects): its status, and its length when the body comes as sent.
@(private)
receive_head :: proc(s: ^Receive_Sink, status: int, headers: []Header, compressed: bool) {
	s.status = status
	s.refused = status < 200 || status > 299
	s.length = -1
	// (a body decoded as it is read is longer than the bytes the header counts)
	if compressed { return }
	if v, ok := header_value(headers, "Content-Length"); ok {
		if n, parsed := strconv.parse_i64_of_base(strings.trim_space(v), 10); parsed && n >= 0 { s.length = n }
	}
}

// One chunk to the caller. False: the transfer stops (the caller's .Stop, or past max_bytes).
@(private)
receive_feed :: proc(s: ^Receive_Sink, bytes: []u8) -> bool {
	if s.max_bytes > 0 && s.received + i64(len(bytes)) > s.max_bytes {
		s.too_large = true
		return false
	}
	s.received += i64(len(bytes))
	if s.on_part(s.user, {bytes = bytes, status = s.status, received = s.received, length = s.length}) == .Stop {
		s.by_caller = true
		return false
	}
	return true
}

// The Response of a transfer: its status, the address that answered and its head's text (cloned with `allocator`).
@(private)
receive_response :: proc(status: int, url, head: string, allocator := context.allocator) -> (res: Response) {
	res.status = status
	res.url = strings.clone(url, allocator)
	res.header_text = strings.clone(head, allocator)
	res.headers = headers_parse(res.header_text, allocator)
	return
}
