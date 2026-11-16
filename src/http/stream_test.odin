package tk_http

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:log"
import "core:net"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "../ascii"

// The events a test's callback saw, their strings copied (an Event's point into the parser).
@(private = "file")
Seen :: struct {
	events:     [dynamic]Event,
	stop_after: int,   // 0: never .Stop
}

@(private = "file")
collect :: proc(user: rawptr, e: Event) -> Keep_Going {
	s := (^Seen)(user)
	append(&s.events, Event{
		type  = strings.clone(e.type, context.temp_allocator),
		data  = strings.clone(e.data, context.temp_allocator),
		id    = strings.clone(e.id, context.temp_allocator),
		retry = e.retry,
	})
	return s.stop_after > 0 && len(s.events) >= s.stop_after ? .Stop : .Continue
}

// The events of `text` fed whole, then fed one byte at a time: both must give the same.
@(private = "file")
parse_both_ways :: proc(t: ^testing.T, text: string, loc := #caller_location) -> []Event {
	whole := Seen{events = make([dynamic]Event, context.temp_allocator)}
	p: Event_Parser
	event_parser_init(&p)
	event_parser_feed(&p, transmute([]u8)text, collect, &whole)
	event_parser_destroy(&p)

	bytes := Seen{events = make([dynamic]Event, context.temp_allocator)}
	event_parser_init(&p)
	for i in 0 ..< len(text) { event_parser_feed(&p, transmute([]u8)text[i:i + 1], collect, &bytes) }
	event_parser_destroy(&p)
	testing.expect_value(t, len(bytes.events), len(whole.events), loc = loc)
	for e, i in whole.events {
		if i < len(bytes.events) { testing.expect_value(t, bytes.events[i], e, loc = loc) }
	}
	return whole.events[:]
}

@(test)
an_event_stream_s_fields :: proc(t: ^testing.T) {
	events := parse_both_ways(t, ": a comment\n\nevent: greet\ndata: one\ndata: two\nid: 7\n\ndata: three\n\nretry: 1500\ndata:four\n\n")
	testing.expect_value(t, len(events), 3)
	if len(events) != 3 { return }
	testing.expect_value(t, events[0], Event{type = "greet", data = "one\ntwo", id = "7"})
	// (the last id stays, the type does not; no space after the colon is fine)
	testing.expect_value(t, events[1], Event{type = "message", data = "three", id = "7"})
	testing.expect_value(t, events[2], Event{type = "message", data = "four", id = "7", retry = 1500})
}

@(test)
an_event_stream_s_line_ends :: proc(t: ^testing.T) {
	for text in ([]string{"data: a\r\ndata: b\r\n\r\n", "data: a\rdata: b\r\r", "data: a\ndata: b\n\n", "data: a\r\ndata: b\n\r"}) {
		events := parse_both_ways(t, text)
		testing.expect_value(t, len(events), 1)
		if len(events) == 1 { testing.expect_value(t, events[0].data, "a\nb") }
	}
	// (a CR at the end of one block, its LF at the start of the next: one line end)
	seen := Seen{events = make([dynamic]Event, context.temp_allocator)}
	p: Event_Parser
	event_parser_init(&p)
	defer event_parser_destroy(&p)
	event_parser_feed(&p, transmute([]u8)string("data: x\r"), collect, &seen)
	event_parser_feed(&p, transmute([]u8)string("\ndata: y\r"), collect, &seen)
	event_parser_feed(&p, transmute([]u8)string("\n\r\n"), collect, &seen)
	testing.expect_value(t, len(seen.events), 1)
	if len(seen.events) == 1 { testing.expect_value(t, seen.events[0].data, "x\ny") }
}

@(test)
an_event_stream_s_edge_cases :: proc(t: ^testing.T) {
	// No data line: no event; its type does not leak into the next.
	events := parse_both_ways(t, "event: lone\n\ndata: x\n\n")
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 { testing.expect_value(t, events[0].type, "message") }

	// An empty data line is an event with empty data; a field with no colon is the field with an empty value.
	events = parse_both_ways(t, "data\n\ndata:\n\n")
	testing.expect_value(t, len(events), 2)
	if len(events) == 2 { testing.expect_value(t, events[0].data, ""); testing.expect_value(t, events[1].data, "") }

	// One space is dropped, not two; a colon in the value stays.
	events = parse_both_ways(t, "data:  two spaces: kept\n\n")
	if len(events) == 1 { testing.expect_value(t, events[0].data, " two spaces: kept") }

	// An id with a NUL is ignored; an empty id resets it; a retry that is not digits is ignored; an unknown field too.
	events = parse_both_ways(t, "id: 1\ndata: a\n\nid: 2\x003\nretry: 12a\nfoo: bar\ndata: b\n\nid\ndata: c\n\n")
	testing.expect_value(t, len(events), 3)
	if len(events) == 3 {
		testing.expect_value(t, events[0].id, "1")
		testing.expect_value(t, events[1].id, "1")
		testing.expect_value(t, events[1].retry, 0)
		testing.expect_value(t, events[2].id, "")
	}

	// A BOM at the start is dropped; an event the stream cuts is not given.
	events = parse_both_ways(t, "\uFEFFdata: first\n\ndata: cut")
	testing.expect_value(t, len(events), 1)
	if len(events) == 1 { testing.expect_value(t, events[0].data, "first") }
	// (a BOM later is part of the field's name)
	events = parse_both_ways(t, "data: a\n\n\uFEFFdata: b\n\n")
	testing.expect_value(t, len(events), 1)
}

@(test)
an_event_stream_stops_when_asked_or_too_large :: proc(t: ^testing.T) {
	seen := Seen{events = make([dynamic]Event, context.temp_allocator), stop_after = 1}
	p: Event_Parser
	event_parser_init(&p)
	testing.expect_value(t, event_parser_feed(&p, transmute([]u8)string("data: 1\n\ndata: 2\n\n"), collect, &seen), Keep_Going.Stop)
	testing.expect_value(t, len(seen.events), 1)
	testing.expect(t, !p.too_large)
	event_parser_destroy(&p)

	seen = Seen{events = make([dynamic]Event, context.temp_allocator)}
	event_parser_init(&p, 8)
	testing.expect_value(t, event_parser_feed(&p, transmute([]u8)string("data: 12345678\n\n"), collect, &seen), Keep_Going.Stop)
	testing.expect(t, p.too_large, "a line over max_bytes")
	testing.expect_value(t, event_parser_feed(&p, transmute([]u8)string("data: 1\n\n"), collect, &seen), Keep_Going.Stop)
	testing.expect_value(t, len(seen.events), 0)
	event_parser_destroy(&p)
}

// A loopback server for `count` connections: /events (a stream, then the end), /two (two events), anything else 404 on
// HTTP; /socket a WebSocket that echoes each message, answers "frag" with "fr" + a ping "p" + "ag", a pong with
// "pong <its data>", "bye" with a close (1000, "done") and a close with a close.
@(private = "file")
Loop :: struct {
	socket: net.TCP_Socket,
	port:   int,
	count:  int,
	thread: ^thread.Thread,
}

@(private = "file") STREAM_BODY :: ": hello\n\nevent: greet\ndata: one\ndata: two\nid: 7\n\ndata: three\r\n\r\nretry: 1500\ndata:four\n\n"
@(private = "file") SOCKET_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"   // RFC 6455's
@(private = "file") BIG_MESSAGE :: 70_000   // (past a frame's 16-bit length)

@(private = "file")
Conn :: struct {
	sock: net.TCP_Socket,
	buf:  [dynamic]u8,
}

@(private = "file")
fill :: proc(c: ^Conn, n: int) -> bool {
	for len(c.buf) < n {
		chunk: [4096]u8
		got, err := net.recv_tcp(c.sock, chunk[:])
		if err != nil || got <= 0 { return false }
		append(&c.buf, ..chunk[:got])
	}
	return true
}

@(private = "file")
take :: proc(c: ^Conn, n: int) -> []u8 {
	out := slice.clone(c.buf[:n], context.temp_allocator)
	remove_range(&c.buf, 0, n)
	return out
}

// A frame of a client (masked), unmasked.
@(private = "file")
frame_read :: proc(c: ^Conn) -> (opcode: u8, payload: []u8, ok: bool) {
	if !fill(c, 2) { return }
	h := take(c, 2)
	opcode = h[0] & 0x0f
	n := int(h[1] & 0x7f)
	switch n {
	case 126:
		if !fill(c, 2) { return }
		e := take(c, 2)
		n = int(e[0]) << 8 | int(e[1])
	case 127:
		if !fill(c, 8) { return }
		n = 0
		for b in take(c, 8) { n = n << 8 | int(b) }
	}
	if !fill(c, 4 + n) { return }
	mask := take(c, 4)
	payload = take(c, n)
	for i in 0 ..< n { payload[i] ~= mask[i % 4] }
	return opcode, payload, true
}

// A frame of a server (not masked); !fin: a message's fragment that more follow.
@(private = "file")
frame_write :: proc(c: ^Conn, opcode: u8, payload: []u8, fin := true) {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, (fin ? 0x80 : 0) | opcode)
	n := len(payload)
	switch {
	case n < 126:   append(&out, u8(n))
	case n < 65536: append(&out, 126, u8(n >> 8), u8(n))
	case:
		append(&out, 127)
		for shift := 56; shift >= 0; shift -= 8 { append(&out, u8(u64(n) >> uint(shift))) }
	}
	append(&out, ..payload)
	net.send_tcp(c.sock, out[:])
}

@(private = "file")
serve_socket :: proc(c: ^Conn, head: string) {
	key := ""
	for line in strings.split_lines(head, context.temp_allocator) {
		if colon := strings.index_byte(line, ':'); colon > 0 && ascii.lower(line[:colon], context.temp_allocator) == "sec-websocket-key" {
			key = strings.trim_space(line[colon + 1:])
		}
	}
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)strings.concatenate({key, SOCKET_GUID}, context.temp_allocator))
	digest: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, digest[:])
	accept, _ := base64.encode(digest[:], allocator = context.temp_allocator)
	answer := fmt.tprintf("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
	net.send_tcp(c.sock, transmute([]u8)answer)
	for {
		opcode, payload, ok := frame_read(c)
		if !ok { return }
		switch opcode {
		case 8:
			frame_write(c, 8, payload)
			return
		case 1, 2:
			switch string(payload) {
			case "bye":
				frame_write(c, 8, {0x03, 0xE8, 'd', 'o', 'n', 'e'})
			case "frag":
				// (a ping between the fragments of a message: the client answers it and joins them)
				frame_write(c, 1, transmute([]u8)string("fr"), fin = false)
				frame_write(c, 9, transmute([]u8)string("p"))
				frame_write(c, 0, transmute([]u8)string("ag"))
			case:
				frame_write(c, opcode, payload)
			}
		case 10:
			// (the pong of the client: said back as a message, so that the test sees it came with the ping's data)
			frame_write(c, 1, transmute([]u8)strings.concatenate({"pong ", string(payload)}, context.temp_allocator))
		}
	}
}

@(private = "file")
loop_start :: proc(t: ^testing.T, count: int) -> ^Loop {
	s := new(Loop)
	s.count = count
	sock, err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil, "listen")
	s.socket = sock
	ep, _ := net.bound_endpoint(sock)
	s.port = ep.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Loop) {
		for _ in 0 ..< s.count {
			client, _, err := net.accept_tcp(s.socket)
			if err != nil { return }
			c := Conn{sock = client, buf = make([dynamic]u8, context.temp_allocator)}
			end := -1
			for end < 0 {
				if !fill(&c, len(c.buf) + 1) { break }
				end = strings.index(string(c.buf[:]), "\r\n\r\n")
			}
			if end >= 0 {
				head := string(take(&c, end + 4))
				path := ""
				if parts := strings.split(head[:max(strings.index(head, "\r\n"), 0)], " ", context.temp_allocator); len(parts) >= 2 { path = parts[1] }
				switch path {
				case "/events": net.send_tcp(client, transmute([]u8)fmt.tprintf("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n%s", STREAM_BODY))
				case "/two":    net.send_tcp(client, transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: 1\n\ndata: 2\n\n"))
				case "/socket": serve_socket(&c, head)
				case "/open":
					// (one small event, the connection kept open as a live server's: the client must see it before
					// any close, and before a whole read chunk fills)
					net.send_tcp(client, transmute([]u8)string("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: hello\n\n"))
					for fill(&c, len(c.buf) + 1) {}   // (until the client goes)
				case:           net.send_tcp(client, transmute([]u8)string("HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\nConnection: close\r\n\r\ndata"))
				}
			}
			net.close(client)
			free_all(context.temp_allocator)
		}
	})
	return s
}

// (the listener shut down first: a test that ends early leaves no thread in accept; on Linux a close alone does not
// wake it)
@(private = "file")
loop_end :: proc(s: ^Loop) {
	net.shutdown(s.socket, .Both)
	net.close(s.socket)
	thread.join(s.thread)
	thread.destroy(s.thread)
	free(s)
}

// A stream through the system's client: its events, its end, a stop of the callback, a status that is not 2xx.
@(test)
an_event_stream_over_http :: proc(t: ^testing.T) {
	s := loop_start(t, 3)
	defer loop_end(s)

	seen := Seen{events = make([dynamic]Event, context.temp_allocator)}
	status, err := events(fmt.tprintf("http://127.0.0.1:%d/events", s.port), {}, collect, &seen)
	if err == .No_Client { log.info("no HTTP client on this system: the stream is not tested"); return }
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 200)
	testing.expect_value(t, len(seen.events), 3)
	if len(seen.events) == 3 {
		testing.expect_value(t, seen.events[0], Event{type = "greet", data = "one\ntwo", id = "7"})
		testing.expect_value(t, seen.events[2], Event{type = "message", data = "four", id = "7", retry = 1500})
	}

	seen = Seen{events = make([dynamic]Event, context.temp_allocator), stop_after = 1}
	status, err = events(fmt.tprintf("http://127.0.0.1:%d/two", s.port), {}, collect, &seen)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(seen.events), 1)

	seen = Seen{events = make([dynamic]Event, context.temp_allocator)}
	status, err = events(fmt.tprintf("http://127.0.0.1:%d/missing", s.port), {}, collect, &seen)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, status, 404)
	testing.expect_value(t, len(seen.events), 0)   // (the body of a 404 is not parsed)

	_, err = events("ftp://127.0.0.1/x", {}, collect, &seen)
	testing.expect_value(t, err, Error.Bad_Url)
}

// A live stream's first event arrives while the connection stays open: WinHTTP's read of a whole chunk waited for the
// chunk to fill or the server to close, so a server's first event (a hundred bytes) never came on Windows.
@(test)
an_open_stream_s_first_event_comes_at_once :: proc(t: ^testing.T) {
	s := loop_start(t, 1)
	defer loop_end(s)
	seen := Seen{events = make([dynamic]Event, context.temp_allocator), stop_after = 1}
	_, err := events(fmt.tprintf("http://127.0.0.1:%d/open", s.port), {timeout = 5 * time.Second}, collect, &seen)
	if err == .No_Client { log.info("no HTTP client on this system: the stream is not tested"); return }
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(seen.events), 1)
}

// A WebSocket to the loopback: on Linux 127.0.0.1 is a connection of our own and `localhost` (a name) libcurl's; on
// Windows both are WinHTTP's.
@(test)
a_web_socket_over_the_loopback :: proc(t: ^testing.T) {
	s := loop_start(t, 2)
	defer loop_end(s)
	socket_conversation(t, fmt.tprintf("ws://127.0.0.1:%d/socket", s.port))
}

@(test)
a_web_socket_to_localhost :: proc(t: ^testing.T) {
	s := loop_start(t, 2)
	defer loop_end(s)
	socket_conversation(t, fmt.tprintf("ws://localhost:%d/socket", s.port))
}

// Two sockets to `url`, a server of loop_start's: a wait that runs out keeps it, a text and a large binary message come
// back whole, the server's close is a .Close message, then .Closed. A stop from another thread ends a waiting ws_recv.
@(private = "file")
socket_conversation :: proc(t: ^testing.T, url: string) {
	sock, err := ws_connect(url, {timeout = 10 * time.Second})
	if err == .No_Client { log.infof("%s: the WebSocket is not tested", error_text(err)); return }
	testing.expect_value(t, err, Error.None)
	if sock == nil { return }

	_, err = ws_recv(sock, 50 * time.Millisecond)
	testing.expect_value(t, err, Error.Timed_Out)

	testing.expect_value(t, ws_send(sock, transmute([]u8)string("hello")), Error.None)
	m: Message
	m, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.kind, Message_Kind.Text)
	testing.expect_value(t, string(m.data), "hello")

	big := make([]u8, BIG_MESSAGE, context.temp_allocator)
	for i in 0 ..< len(big) { big[i] = u8(i) }
	testing.expect_value(t, ws_send(sock, big, .Binary), Error.None)
	m, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.kind, Message_Kind.Binary)
	testing.expect(t, slice.equal(m.data, big), "the large message whole")

	testing.expect_value(t, ws_send(sock, transmute([]u8)string("frag")), Error.None)
	m, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, string(m.data), "frag")   // (the fragments joined, the ping between them not given)
	m, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, string(m.data), "pong p")   // (the client answered the ping with its data)

	testing.expect_value(t, ws_send(sock, transmute([]u8)string("bye")), Error.None)
	m, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.kind, Message_Kind.Close)
	testing.expect_value(t, m.code, 1000)
	testing.expect_value(t, string(m.data), "done")
	_, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.Closed)
	ws_close(sock)

	sock, err = ws_connect(url, {timeout = 10 * time.Second})
	testing.expect_value(t, err, Error.None)
	if sock == nil { return }
	stopper := thread.create_and_start_with_poly_data(sock, proc(s: ^Socket) { ws_stop(s) })
	_, err = ws_recv(sock, 10 * time.Second)
	testing.expect_value(t, err, Error.Stopped)
	thread.join(stopper)
	thread.destroy(stopper)
	testing.expect_value(t, ws_send(sock, transmute([]u8)string("late")), Error.Stopped)
	ws_close(sock)
}

when ODIN_OS == .Linux {
	// A socket to this machine holds no libcurl handle: gt:cdp's client then works where libcurl cannot be loaded (a
	// program's Nix shell without curl), where 0.287.0's answered .No_Client. A name (localhost) is libcurl's.
	@(test)
	a_web_socket_to_this_machine_needs_no_libcurl :: proc(t: ^testing.T) {
		s := loop_start(t, 2)
		defer loop_end(s)
		sock, err := ws_connect(fmt.tprintf("ws://127.0.0.1:%d/socket", s.port), {timeout = 10 * time.Second})
		testing.expect_value(t, err, Error.None)
		if sock != nil {
			testing.expect(t, sock.h == nil, "a connection of our own, not libcurl's")
			ws_close(sock)
		}
		sock, err = ws_connect(fmt.tprintf("ws://localhost:%d/socket", s.port), {timeout = 10 * time.Second})
		if err == .No_Client { return }
		testing.expect_value(t, err, Error.None)
		if sock != nil {
			testing.expect(t, sock.h != nil, "a name goes through libcurl")
			ws_close(sock)
		}
	}

	@(test)
	a_loopback_literal :: proc(t: ^testing.T) {
		for host in ([]string{"127.0.0.1", "127.1.2.254", "::1", "[::1]"}) { testing.expectf(t, loopback_literal(host), "%s is the loopback", host) }
		for host in ([]string{"localhost", "128.0.0.1", "127.0.0", "127.0.0.1.1", "127.0.0.256", "127.0.0.1000", "127..0.1", "127.0.0.+1", "::2", "[::1", "", "example.com"}) {
			testing.expectf(t, !loopback_literal(host), "%s is not a loopback literal", host)
		}
	}
}

@(test)
a_web_socket_that_cannot_be :: proc(t: ^testing.T) {
	_, err := ws_connect("http://127.0.0.1/x")
	testing.expect_value(t, err, Error.Bad_Url)
	_, err = ws_connect("ws://127.0.0.1/x", {headers = {{"X-Bad", "a\r\nb"}}})
	testing.expect_value(t, err, Error.Bad_Request)

	// (a port just freed: nothing listens there)
	sock, listen_err := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, listen_err == nil, "listen")
	ep, _ := net.bound_endpoint(sock)
	net.close(sock)
	_, err = ws_connect(fmt.tprintf("ws://127.0.0.1:%d/x", ep.port), {timeout = 10 * time.Second})
	testing.expect(t, err == .Unreachable || err == .No_Client, error_text(err))

	seen := Seen{events = make([dynamic]Event, context.temp_allocator)}
	_, err = events(fmt.tprintf("http://127.0.0.1:%d/x", ep.port), {timeout = 10 * time.Second}, collect, &seen)
	testing.expect(t, err == .Unreachable || err == .No_Client, error_text(err))
}

// A server that answers the upgrade with a 404 is Refused, not Unreachable.
@(test)
a_web_socket_refused :: proc(t: ^testing.T) {
	s := loop_start(t, 1)
	defer loop_end(s)
	_, err := ws_connect(fmt.tprintf("ws://127.0.0.1:%d/missing", s.port), {timeout = 10 * time.Second})
	if err == .No_Client { return }
	testing.expect_value(t, err, Error.Refused)
}
