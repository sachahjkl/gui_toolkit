// A client of the Chrome DevTools Protocol for tools: a toolkit window's devtools server (src/devtools, TOOLKIT_DEVTOOLS=<port>) or a
// browser's own. One WebSocket for a whole run, calls answered in order, the events that come between them handled on the way
// (a screencast's frames: screencast.odin). docs/cdp.md says what each part does.
package tk_cdp

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import http "../http"

// (above what any wait asks of a window: it answers at its own timeout)
READ_LIMIT :: 75 * time.Second
@(private) ACK_ID :: -1   // a call no one waits for: its answer is dropped
// The handshake's limit: the servers are on this machine.
@(private) CONNECT_LIMIT :: 10 * time.Second

// The WebSocket is tk_http's (libcurl, WinHTTP): the frames are not this package's.
Client :: struct {
	socket:     ^http.Socket,
	port:       int,
	next_id:    int,
	read_limit: time.Duration,   // how long a read waits before the call fails (READ_LIMIT unless told)
	session:    string,   // a browser: the page the calls go to ("": the connection's own target)
	screencast: ^Screencast,   // a screencast in progress: where its frames go
	failure:    string,   // what the last call that failed said
	quiet:      bool,     // a failure is not printed (the caller says it)
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
	s, err := http.ws_connect(fmt.tprintf("ws://127.0.0.1:%d%s", port, path), {timeout = CONNECT_LIMIT})
	if err != .None { return }
	c.socket, c.port, c.read_limit = s, port, READ_LIMIT
	return c, true
}

close :: proc(c: ^Client) {
	http.ws_close(c.socket)
	c.socket = nil
}

// How long a read waits before the call fails (READ_LIMIT unless told).
set_read_limit :: proc(c: ^Client, limit: time.Duration) { c.read_limit = limit }

@(private)
write_text :: proc(c: ^Client, text: string) -> bool {
	return c.socket != nil && http.ws_send(c.socket, transmute([]byte)text, .Text) == .None
}

// The next whole message within `wait`, in the temporary allocator. timed_out: nothing came, the connection stays.
@(private)
next_message :: proc(c: ^Client, wait: time.Duration) -> (message: string, ok: bool, timed_out: bool) {
	if c.socket == nil { return }
	m, err := http.ws_recv(c.socket, wait)
	if err == .Timed_Out { return "", false, true }
	if err != .None || m.kind == .Close { return }
	return strings.clone(string(m.data), context.temp_allocator), true, false
}

// A call no one waits for (an acknowledgement): its answer is dropped when it comes.
send :: proc(c: ^Client, method: string, params := "{}") -> bool {
	return write_text(c, request(ACK_ID, method, params, c.session))
}

// `params`: a JSON object. The result, in the temporary allocator. A failure is said once, here (unless `quiet`), and kept in
// `failure`.
call :: proc(c: ^Client, method: string, params := "{}") -> (result: json.Value, ok: bool) {
	c.next_id += 1
	c.failure = ""
	if !write_text(c, request(c.next_id, method, params, c.session)) { return fail(c, method, "the connection is gone") }
	for {
		message, got, timed_out := next_message(c, c.read_limit)
		if timed_out { return fail(c, method, "no answer in time") }
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
