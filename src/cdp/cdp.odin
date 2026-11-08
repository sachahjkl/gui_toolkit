// A client of the Chrome DevTools Protocol for tools: a toolkit window's devtools server (src/devtools, TOOLKIT_DEVTOOLS=<port>) or a
// browser's own. One WebSocket for a whole run, calls answered in order, the events that come between them handled on the way
// (a screencast's frames: screencast.odin). docs/cdp.md says what each part does.
package tk_cdp

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:slice"
import "core:strings"
import "core:time"

// (above what any wait asks of a window: it answers at its own timeout)
READ_LIMIT :: 75 * time.Second
@(private) CHUNK :: 64 * 1024
@(private) ACK_ID :: -1   // a call no one waits for: its answer is dropped
@(private) MASK :: [4]byte{0x63, 0x64, 0x70, 0x74}
@(private) SOCKET_KEY :: "dGtfY2RwIHRrX2NkcCB0aw=="

// The opcodes of RFC 6455 a client meets.
WS_TEXT  :: 1
WS_CLOSE :: 8
WS_PING  :: 9
WS_PONG  :: 10

Client :: struct {
	sock:    net.TCP_Socket,
	port:    int,
	next_id: int,
	buf:     [dynamic]byte,
	session: string,   // a browser: the page the calls go to ("": the connection's own target)
	screencast: ^Screencast,   // a screencast in progress: where its frames go
	failure: string,   // what the last call that failed said
	quiet:   bool,     // a failure is not printed (the caller says it)
}

// One frame of what a client sends: masked, as the protocol wants it.
ws_encode :: proc(opcode: u8, payload: []byte, mask: [4]byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, 0, len(payload) + 14, allocator)
	append(&out, 0x80 | opcode)
	n := len(payload)
	switch {
	case n < 126:
		append(&out, 0x80 | u8(n))
	case n < 65536:
		append(&out, 0x80 | 126, u8(n >> 8), u8(n))
	case:
		append(&out, 0x80 | 127)
		for shift := 56; shift >= 0; shift -= 8 { append(&out, u8(u64(n) >> uint(shift))) }
	}
	append(&out, mask[0], mask[1], mask[2], mask[3])
	for b, i in payload { append(&out, b ~ mask[i % 4]) }
	return out[:]
}

// The first frame of `buf`, a server's (not masked). !complete: more bytes are needed.
ws_decode :: proc(buf: []byte) -> (opcode: u8, fin: bool, payload: []byte, used: int, complete: bool) {
	if len(buf) < 2 { return }
	opcode, fin = buf[0] & 0x0f, buf[0] & 0x80 != 0
	n := int(buf[1] & 0x7f)
	at := 2
	switch n {
	case 126:
		if len(buf) < 4 { return }
		n = int(buf[2]) << 8 | int(buf[3])
		at = 4
	case 127:
		if len(buf) < 10 { return }
		n = 0
		for i in 2 ..< 10 { n = n << 8 | int(buf[i]) }
		at = 10
	}
	if len(buf) < at + n { return }
	return opcode, fin, buf[at:at + n], at + n, true
}

// A string as JSON, quotes included: what goes into the parameters of a call.
quote :: proc(s: string) -> string {
	data, err := json.marshal(s, allocator = context.temp_allocator)
	return err == nil ? string(data) : `""`
}

integer :: proc(v: json.Value) -> (int, bool) {
	#partial switch n in v {
	case json.Integer: return int(n), true
	case json.Float:   return int(n), true
	}
	return 0, false
}

number :: proc(v: json.Value) -> f64 {
	#partial switch n in v {
	case json.Integer: return f64(n)
	case json.Float:   return f64(n)
	}
	return 0
}

str :: proc(v: json.Value) -> string {
	s, _ := v.(json.String)
	return s
}

// A value as JSON.stringify writes it (`indent` spaces a level; 0: on one line), whole numbers without ".0": what a tool prints of
// an answer. The keys are sorted (a parsed object keeps no order).
stringify :: proc(v: json.Value, indent := 0) -> string {
	b := strings.builder_make(context.temp_allocator)
	write_value(&b, v, indent, 0)
	return strings.to_string(b)
}

@(private)
write_value :: proc(b: ^strings.Builder, v: json.Value, indent, depth: int) {
	newline :: proc(b: ^strings.Builder, indent, depth: int) {
		if indent == 0 { return }
		strings.write_byte(b, '\n')
		for _ in 0 ..< indent * depth { strings.write_byte(b, ' ') }
	}
	switch x in v {
	case nil, json.Null:         strings.write_string(b, "null")
	case json.Boolean:           strings.write_string(b, x ? "true" : "false")
	case json.Integer:           fmt.sbprintf(b, "%d", x)
	case json.Float:             strings.write_string(b, json_number(x))
	case json.String:            strings.write_string(b, quote(x))
	case json.Array:
		if len(x) == 0 { strings.write_string(b, "[]"); return }
		strings.write_byte(b, '[')
		for item, i in x {
			if i > 0 { strings.write_byte(b, ',') }
			newline(b, indent, depth + 1)
			write_value(b, item, indent, depth + 1)
		}
		newline(b, indent, depth)
		strings.write_byte(b, ']')
	case json.Object:
		if len(x) == 0 { strings.write_string(b, "{}"); return }
		keys := make([dynamic]string, 0, len(x), context.temp_allocator)
		for k in x { append(&keys, k) }
		slice.sort(keys[:])
		strings.write_byte(b, '{')
		for k, i in keys {
			if i > 0 { strings.write_byte(b, ',') }
			newline(b, indent, depth + 1)
			strings.write_string(b, quote(k))
			strings.write_string(b, indent > 0 ? ": " : ":")
			write_value(b, x[k], indent, depth + 1)
		}
		newline(b, indent, depth)
		strings.write_byte(b, '}')
	}
}

// A call as it is sent. `params`: a JSON object. `session`: "" for the connection's own target.
request :: proc(id: int, method, params, session: string) -> string {
	if session == "" { return fmt.tprintf(`{{"id":%d,"method":%s,"params":%s}}`, id, quote(method), params) }
	return fmt.tprintf(`{{"id":%d,"method":%s,"params":%s,"sessionId":%s}}`, id, quote(method), params, quote(session))
}

// Is `text` the answer to the call `id`? Its result, or its error's message.
answer :: proc(raw: string, id: int, allocator := context.temp_allocator) -> (result: json.Value, failure: string, mine: bool) {
	v, err := json.parse_string(raw, allocator = allocator)
	if err != nil { return nil, "", false }
	o, is_object := v.(json.Object)
	if !is_object { return nil, "", false }
	n, has_id := integer(o["id"])
	if !has_id || n != id { return nil, "", false }
	if e, failed := o["error"].(json.Object); failed {
		message := str(e["message"])
		code, has_code := integer(e["code"])
		if message == "" { message = "an error" }
		return nil, has_code ? fmt.aprintf("%s (%d)", message, code, allocator = allocator) : message, true
	}
	return o["result"], "", true
}

Target :: struct {
	web_socket_url, devtools_frontend_url: string,
}

// What `port` of this machine lists (/json/list): a window has one target, a browser its pages.
targets :: proc(port: int) -> (list: []Target, ok: bool) {
	status, body, got := http_get(port, "/json/list")
	if !got || status != 200 { return }
	Listed :: struct {
		webSocketDebuggerUrl, devtoolsFrontendUrl: string,
	}
	listed: []Listed
	if json.unmarshal(transmute([]byte)body, &listed, allocator = context.temp_allocator) != nil { return }
	out := make([]Target, len(listed), context.temp_allocator)
	for l, i in listed { out[i] = {l.webSocketDebuggerUrl, l.devtoolsFrontendUrl} }
	return out, true
}

// The path of a ws:// address ("ws://127.0.0.1:9222/devtools/page/1" -> "/devtools/page/1"). "": not one.
socket_path :: proc(url: string) -> string {
	if !strings.has_prefix(url, "ws://") { return "" }
	slash := strings.index_byte(url[len("ws://"):], '/')
	return slash < 0 ? "" : url[len("ws://") + slash:]
}

// The first target of `port`: a toolkit window. !ok: nothing answers there yet.
connect :: proc(port: int) -> (c: Client, ok: bool) {
	list, listed := targets(port)
	if !listed || len(list) == 0 { return }
	path := socket_path(list[0].web_socket_url)
	if path == "" { return }
	return open(port, path)
}

// The WebSocket at `path` of this machine's `port` (a browser's own, whose pages are sessions of one connection, or a window's).
open :: proc(port: int, path: string) -> (c: Client, ok: bool) {
	sock, err := net.dial_tcp_from_endpoint(net.Endpoint{address = net.IP4_Loopback, port = port})
	if err != nil { return }
	_ = net.set_option(sock, .Receive_Timeout, READ_LIMIT)
	c.sock, c.port = sock, port
	head := fmt.tprintf("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", path, port, SOCKET_KEY)
	if _, e := net.send_tcp(sock, transmute([]byte)head); e != nil { close(&c); return }
	for {
		end := strings.index(string(c.buf[:]), "\r\n\r\n")
		if end >= 0 {
			if !strings.contains(string(c.buf[:end]), " 101 ") { close(&c); return }
			remove_range(&c.buf, 0, end + 4)
			return c, true
		}
		if !read_more(&c) { close(&c); return }
	}
}

close :: proc(c: ^Client) {
	net.close(c.sock)
	delete(c.buf)
	c.buf = nil
}

// How long a read waits before the call fails (READ_LIMIT unless told).
set_read_limit :: proc(c: ^Client, limit: time.Duration) { _ = net.set_option(c.sock, .Receive_Timeout, limit) }

@(private)
read_more :: proc(c: ^Client) -> bool {
	chunk: [CHUNK]byte
	n, err := net.recv_tcp(c.sock, chunk[:])
	if err != nil || n == 0 { return false }
	append(&c.buf, ..chunk[:n])
	return true
}

@(private)
write_frame :: proc(c: ^Client, opcode: u8, payload: []byte) -> bool {
	_, err := net.send_tcp(c.sock, ws_encode(opcode, payload, MASK, context.temp_allocator))
	return err == nil
}

// The next whole message, in the temporary allocator.
@(private)
next_message :: proc(c: ^Client) -> (message: string, ok: bool) {
	whole := make([dynamic]byte, context.temp_allocator)
	for {
		opcode, fin, payload, used, complete := ws_decode(c.buf[:])
		if !complete {
			if !read_more(c) { return "", false }
			continue
		}
		switch opcode {
		case WS_CLOSE:
			return "", false
		case WS_PING:
			write_frame(c, WS_PONG, payload)
		case WS_PONG:
		case:
			append(&whole, ..payload)
		}
		remove_range(&c.buf, 0, used)
		if fin && opcode != WS_PING && opcode != WS_PONG { return string(whole[:]), true }
	}
}

// A call no one waits for (an acknowledgement): its answer is dropped when it comes.
send :: proc(c: ^Client, method: string, params := "{}") -> bool {
	return write_frame(c, WS_TEXT, transmute([]byte)request(ACK_ID, method, params, c.session))
}

// `params`: a JSON object. The result, in the temporary allocator. A failure is said once, here (unless `quiet`), and kept in
// `failure`.
call :: proc(c: ^Client, method: string, params := "{}") -> (result: json.Value, ok: bool) {
	c.next_id += 1
	c.failure = ""
	if !write_frame(c, WS_TEXT, transmute([]byte)request(c.next_id, method, params, c.session)) { return fail(c, method, "the connection is gone") }
	for {
		message, got := next_message(c)
		if !got { return fail(c, method, "the connection ended") }
		r, failure, mine := answer(message, c.next_id)
		if !mine { event(c, message); continue }
		if failure != "" { return fail(c, method, failure) }
		return r, true
	}
}

@(private)
fail :: proc(c: ^Client, method, why: string) -> (json.Value, bool) {
	c.failure = fmt.tprintf("%s: %s", method, why)
	if !c.quiet { fmt.eprintln(c.failure) }
	return nil, false
}

// An event between two answers.
@(private)
event :: proc(c: ^Client, message: string) {
	if c.screencast != nil && strings.contains(message[:min(len(message), 64)], "Page.screencastFrame") { screencast_frame(c, message) }
}
