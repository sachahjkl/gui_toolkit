#+build linux
package tk_http

// A WebSocket over libcurl's raw connection (CONNECT_ONLY = 1, curl_easy_send and curl_easy_recv, libcurl 7.18.1 and
// later): curl does the TCP, the TLS and a proxy's tunnel; the upgrade and the frames are ours (frame.odin).
// Distributions build libcurl without its WebSocket API (src/md/features/streams.md). curl_easy_recv never blocks: a
// wait is a poll of the socket and of a pipe that ws_stop writes to.

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

@(private = "file") SOCKET_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"   // RFC 6455's
// The upgrade's answer, its head at most.
@(private = "file") HANDSHAKE_MAX :: 64 * 1024
@(private = "file") RECV_CHUNK :: 16 * 1024
// How long a close (ours, or the echo of the server's) may wait to go out: the socket ends after it anyway.
@(private = "file") CLOSE_LIMIT :: time.Second

Socket :: struct {
	h:          rawptr,        // libcurl's handle: the connection, TLS included
	lock:       sync.Mutex,    // one libcurl call at a time, and a frame sent whole: the reader's (a pong, a close), the senders'
	fd:         posix.FD,
	wake:       [2]posix.FD,   // ws_stop writes to [1]; a wait polls [0] beside the socket
	stopped:    bool,          // atomic
	closed:     bool,          // the reader's: a close came, or the connection ended
	max_bytes:  int,
	input:      [dynamic]u8,   // the bytes received and not yet a whole frame
	buf:        [dynamic]u8,   // the message being read, then the one given
	kind:       Message_Kind,
	assembling: bool,          // a message's first frame was read and not its last
}

ws_connect_system :: proc(url, http_url: string, req: Request) -> (^Socket, Error) {
	sync.once_do(&curl_once, curl_load)
	if !curl_found { return nil, .No_Client }
	c := &curl_lib
	if c.easy_send == nil || c.easy_recv == nil { return nil, .No_Client }
	u, _ := url_parse(http_url)
	h := c.easy_init()
	if h == nil { return nil, .No_Client }
	// (the scheme of the upgrade's request: curl connects, with TLS for https, and sends nothing)
	c.easy_setopt(h, CURLOPT_URL, strings.clone_to_cstring(http_url, context.temp_allocator))
	c.easy_setopt(h, CURLOPT_CONNECT_ONLY, i64(1))
	c.easy_setopt(h, CURLOPT_PROTOCOLS_STR, cstring("http,https"))   // (7.85; an older libcurl refuses the option, harmless)
	c.easy_setopt(h, CURLOPT_HTTP_VERSION, i64(CURL_HTTP_VERSION_1_1))   // (TLS's ALPN offers no HTTP/2: an upgrade is HTTP/1.1's)
	c.easy_setopt(h, CURLOPT_HTTPPROXYTUNNEL, i64(1))   // (a proxy carries the bytes; it does not answer for the server)
	c.easy_setopt(h, CURLOPT_NOSIGNAL, i64(1))
	c.easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, i64(req.timeout / time.Millisecond))
	if c.easy_perform(h) != 0 { c.easy_cleanup(h); return nil, .Unreachable }
	fd, found := active_socket(h)
	if !found { c.easy_cleanup(h); return nil, .Unreachable }
	s := new(Socket)
	s.h, s.fd, s.max_bytes = h, fd, req.max_bytes
	if posix.pipe(&s.wake) != .OK {
		c.easy_cleanup(h)
		free(s)
		return nil, .Unreachable
	}
	s.input = make([dynamic]u8)
	s.buf = make([dynamic]u8)
	if err := handshake(s, u, req); err != .None {
		socket_free(s)
		return nil, err
	}
	return s, .None
}

@(private = "file")
active_socket :: proc(h: rawptr) -> (posix.FD, bool) {
	c := &curl_lib
	fd: i32 = -1   // (curl_socket_t: an int)
	if c.easy_getinfo(h, CURLINFO_ACTIVESOCKET, &fd) == 0 && fd >= 0 { return posix.FD(fd), true }
	last: i64 = -1   // (a libcurl before 7.45: a long)
	if c.easy_getinfo(h, CURLINFO_LASTSOCKET, &last) == 0 && last >= 0 { return posix.FD(last), true }
	return -1, false
}

// The upgrade (RFC 6455, 4.1): our request, the server's 101 with the accept of our key. Frames may follow its head in
// the same bytes: they stay in s.input.
@(private = "file")
handshake :: proc(s: ^Socket, u: Url, req: Request) -> Error {
	nonce: [16]u8
	crypto.rand_bytes(nonce[:])
	key, _ := base64.encode(nonce[:], allocator = context.temp_allocator)
	host := u.host
	if u.port != (u.secure ? 443 : 80) { host = fmt.tprintf("%s:%d", u.host, u.port) }
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n", u.path, host, key)
	if req.user_agent != "" { fmt.sbprintf(&b, "User-Agent: %s\r\n", req.user_agent) }
	for hd in req.headers { fmt.sbprintf(&b, "%s: %s\r\n", hd.name, hd.value) }
	strings.write_string(&b, "\r\n")
	deadline, bounded := deadline_of(req.timeout)
	if send_all(s, transmute([]u8)strings.to_string(b), deadline, bounded) != .None { return .Unreachable }

	end := -1
	for {
		end = strings.index(string(s.input[:]), "\r\n\r\n")
		if end >= 0 { break }
		if len(s.input) > HANDSHAKE_MAX { return .Refused }
		if read_more(s, deadline, bounded) != .None { return .Unreachable }
	}
	head := strings.clone(string(s.input[:end]), context.temp_allocator)
	remove_range(&s.input, 0, end + 4)
	line_end := strings.index(head, "\r\n")
	status_line := line_end < 0 ? head : head[:line_end]
	fields := strings.fields(status_line, context.temp_allocator)
	if len(fields) < 2 || fields[1] != "101" { return .Refused }
	accept, has_accept := header_value(headers_parse(head, context.temp_allocator), "Sec-WebSocket-Accept")
	if !has_accept || accept != accept_of(key) { return .Refused }
	return .None
}

// What the server must answer to `key`: base64(SHA-1(key + the protocol's GUID)).
@(private = "file")
accept_of :: proc(key: string) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)strings.concatenate({key, SOCKET_GUID}, context.temp_allocator))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	out, _ := base64.encode(digest[:], allocator = context.temp_allocator)
	return out
}

// A client frame's mask: random, so that no byte the program sends is a request a proxy on the way reads.
@(private = "file")
mask_new :: proc() -> (m: [4]u8) {
	crypto.rand_bytes(m[:])
	return
}

@(private = "file")
Ready :: enum {
	Ready,
	Stopped,
	Timed_Out,
}

// Until the socket can be read (or written), a stop, or the deadline.
@(private = "file")
wait_ready :: proc(s: ^Socket, write: bool, deadline: time.Tick, bounded: bool) -> Ready {
	for {
		if sync.atomic_load(&s.stopped) { return .Stopped }
		fds := [2]posix.pollfd{
			{fd = s.fd, events = write ? {.OUT} : {.IN}},
			{fd = s.wake[0], events = {.IN}},
		}
		n := posix.poll(raw_data(fds[:]), len(fds), i32(ms_left(deadline, bounded)))
		if n < 0 {
			if posix.errno() == .EINTR { continue }
			return .Ready   // (libcurl's next call says what is wrong)
		}
		if n == 0 { return .Timed_Out }
		if .IN in fds[1].revents { return .Stopped }
		return .Ready
	}
}

// Sends `bytes` whole. The caller holds the lock (or is the only thread: the handshake).
@(private = "file")
send_all :: proc(s: ^Socket, bytes: []u8, deadline: time.Tick, bounded: bool) -> Error {
	c := &curl_lib
	at := 0
	for at < len(bytes) {
		sent: uint
		code := c.easy_send(s.h, raw_data(bytes[at:]), uint(len(bytes[at:])), &sent)
		at += int(sent)
		if code == CURLE_AGAIN {
			switch wait_ready(s, true, deadline, bounded) {
			case .Stopped:   return .Stopped
			case .Timed_Out: return .Timed_Out
			case .Ready:
			}
			continue
		}
		if code != 0 { return .Closed }
	}
	return .None
}

// What comes next, into s.input. libcurl is asked before any poll: TLS may hold decrypted bytes the socket no longer
// shows. CURLE_AGAIN is the only "poll now".
@(private = "file")
read_more :: proc(s: ^Socket, deadline: time.Tick, bounded: bool) -> Error {
	c := &curl_lib
	chunk: [RECV_CHUNK]u8
	for {
		if sync.atomic_load(&s.stopped) { return .Stopped }
		got: uint
		sync.mutex_lock(&s.lock)
		code := c.easy_recv(s.h, &chunk[0], len(chunk), &got)
		sync.mutex_unlock(&s.lock)
		if code == CURLE_AGAIN {
			switch wait_ready(s, false, deadline, bounded) {
			case .Stopped:   return .Stopped
			case .Timed_Out: return .Timed_Out
			case .Ready:
			}
			continue
		}
		if code != 0 || got == 0 { return .Closed }   // (0 bytes: the server ended the connection)
		append(&s.input, ..chunk[:got])
		return .None
	}
}

// The socket is over for the reader: `err` says why.
@(private = "file")
ended :: proc(s: ^Socket, err: Error) -> (Message, Error) {
	s.closed, s.assembling = true, false
	return {}, err
}

// A control frame of ours (a pong, a close), sent whole under the lock; bounded: the socket goes on, or ends, anyway.
@(private = "file")
send_control :: proc(s: ^Socket, opcode: u8, payload: []u8, limit: time.Duration) {
	frame := ws_encode(opcode, payload, mask_new(), context.temp_allocator)
	deadline, bounded := deadline_of(limit)
	sync.mutex_lock(&s.lock)
	send_all(s, frame, deadline, bounded)
	sync.mutex_unlock(&s.lock)
}

ws_recv_system :: proc(s: ^Socket, wait: time.Duration) -> (Message, Error) {
	if s.closed { return {}, .Closed }
	if !s.assembling { clear(&s.buf) }
	deadline, bounded := deadline_of(wait)
	for {
		if sync.atomic_load(&s.stopped) { return {}, .Stopped }
		opcode, fin, payload, used, complete := ws_decode(s.input[:])
		if !complete {
			if used > s.max_bytes + WS_HEAD_MAX { return ended(s, .Too_Large) }
			#partial switch e := read_more(s, deadline, bounded); e {
			case .None:
			case .Closed: return ended(s, .Closed)
			case:         return {}, e   // (.Stopped, .Timed_Out: a message in progress stays in input and buf)
			}
			continue
		}
		// (a server's frame is not masked, and no extension was agreed: anything else is not this protocol)
		if s.input[1] & 0x80 != 0 || s.input[0] & 0x70 != 0 { return ended(s, .Closed) }
		switch opcode {
		case WS_PING:
			pong := ws_encode(WS_PONG, payload, mask_new(), context.temp_allocator)
			remove_range(&s.input, 0, used)
			sync.mutex_lock(&s.lock)
			send_all(s, pong, {}, false)
			sync.mutex_unlock(&s.lock)
		case WS_PONG:
			remove_range(&s.input, 0, used)
		case WS_CLOSE:
			s.closed, s.assembling = true, false
			clear(&s.buf)
			status := 1005   // (RFC 6455: a close with no code)
			if len(payload) >= 2 {
				status = int(payload[0]) << 8 | int(payload[1])
				append(&s.buf, ..payload[2:])
			}
			// (the closing handshake: the server's code goes back)
			echo := make([]u8, min(len(payload), 2), context.temp_allocator)
			copy(echo, payload)
			remove_range(&s.input, 0, used)
			send_control(s, WS_CLOSE, echo, CLOSE_LIMIT)
			return Message{.Close, s.buf[:], status}, .None
		case WS_TEXT, WS_BINARY, WS_CONTINUATION:
			// (a continuation with no message, or a message inside another: not this protocol)
			if (opcode == WS_CONTINUATION) != s.assembling { return ended(s, .Closed) }
			if opcode != WS_CONTINUATION {
				s.kind = opcode == WS_BINARY ? .Binary : .Text
				s.assembling = true
			}
			if len(s.buf) + len(payload) > s.max_bytes { return ended(s, .Too_Large) }
			append(&s.buf, ..payload)
			remove_range(&s.input, 0, used)
			if fin {
				s.assembling = false
				return Message{s.kind, s.buf[:], 0}, .None
			}
		case:
			return ended(s, .Closed)
		}
	}
}

ws_send_system :: proc(s: ^Socket, data: []u8, kind: Message_Kind) -> Error {
	if sync.atomic_load(&s.stopped) { return .Stopped }
	frame := ws_encode(kind == .Binary ? WS_BINARY : WS_TEXT, data, mask_new())
	defer delete(frame)
	sync.mutex_lock(&s.lock)
	defer sync.mutex_unlock(&s.lock)
	return send_all(s, frame, {}, false)
}

ws_stop_system :: proc(s: ^Socket) {
	sync.atomic_store(&s.stopped, true)
	one := [1]u8{1}
	posix.write(s.wake[1], raw_data(one[:]), len(one))
}

ws_close_system :: proc(s: ^Socket) {
	// (1000: a normal close; the server's answer is not awaited)
	if !s.closed { send_control(s, WS_CLOSE, {0x03, 0xE8}, CLOSE_LIMIT) }
	socket_free(s)
}

@(private = "file")
socket_free :: proc(s: ^Socket) {
	curl_lib.easy_cleanup(s.h)
	posix.close(s.wake[0])
	posix.close(s.wake[1])
	delete(s.input)
	delete(s.buf)
	free(s)
}
