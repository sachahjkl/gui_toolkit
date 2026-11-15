package tk_http

// A server's event stream (Server-Sent Events): `events` reads one until it ends, a pure parser turns its bytes into events.
// src/md/features/streams.md says why it is a callback, why silence is its time limit and why no reconnection here.

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// The longest silence of a stream when its Request says none: any byte, a server's heartbeat included, restarts it.
STREAM_SILENCE :: 2 * time.Minute

// One event of a stream. Its strings point into the parser: valid during the callback only.
Event :: struct {
	type:  string,   // the `event:` field; "message" when the stream names none
	data:  string,   // the `data:` lines, joined by "\n"
	id:    string,   // the stream's last event id: the last `id:` seen, in this event or an earlier one ("": none)
	retry: int,      // the stream's reconnection time in milliseconds: the last `retry:` seen (0: none)
}

// What a callback asks of the stream.
Keep_Going :: enum {
	Continue,
	Stop,   // the stream ends at once: events returns .None
}

Event_Proc :: #type proc(user: rawptr, e: Event) -> Keep_Going

// A stop another thread asks for. The zero value: none asked.
Stop :: struct {
	asked: bool,
}

// Any thread. The stream ends within about a second, with .Stopped.
stop_ask :: proc(s: ^Stop) { sync.atomic_store(&s.asked, true) }

@(private)
stop_asked :: proc(s: ^Stop) -> bool { return s != nil && sync.atomic_load(&s.asked) }

// Reads the event stream of `url` (GET), calling `on_event` for each event, until the stream ends, `on_event` returns
// .Stop or `stop` is asked. `req.timeout` is the longest silence (0: STREAM_SILENCE); `req.max_bytes` bounds a line and
// an event's data (0: MAX_BYTES). An Accept header is added when req has none. status: the answer's (after the
// redirects); a status that is not 2xx gives no event and no Error. A stream the server ends is no Error either: call
// again to reconnect, with a Last-Event-ID header from the last Event.id.
events :: proc(url: string, req: Request, on_event: Event_Proc, user: rawptr, stop: ^Stop = nil) -> (status: int, err: Error) {
	if err = request_check("GET", url, req); err != .None { return }
	r := req
	if r.max_bytes <= 0 { r.max_bytes = MAX_BYTES }
	if r.timeout <= 0 { r.timeout = STREAM_SILENCE }
	if _, has_accept := header_value(r.headers, "Accept"); !has_accept {
		headers := make([dynamic]Header, 0, len(r.headers) + 2, context.temp_allocator)
		append(&headers, ..r.headers)
		append(&headers, Header{"Accept", "text/event-stream"}, Header{"Cache-Control", "no-cache"})
		r.headers = headers[:]
	}
	parser: Event_Parser
	event_parser_init(&parser, r.max_bytes)
	defer event_parser_destroy(&parser)
	return events_system(url, r, &parser, on_event, user, stop)
}

// The state of one stream's parse: the line in progress and the fields of the event in progress.
Event_Parser :: struct {
	line:       [dynamic]u8,
	data:       [dynamic]u8,   // each data line followed by "\n"
	type:       [dynamic]u8,
	id:         [dynamic]u8,
	retry:      int,
	max_bytes:  int,
	after_cr:   bool,   // the last byte was a CR: a LF right after it ends no second line
	later_line: bool,   // a line was read (a BOM is dropped from the first one only)
	too_large:  bool,   // a line or an event's data grew past max_bytes: the parse stopped
}

event_parser_init :: proc(p: ^Event_Parser, max_bytes := MAX_BYTES, allocator := context.allocator) {
	p^ = {max_bytes = max_bytes}
	p.line = make([dynamic]u8, allocator)
	p.data = make([dynamic]u8, allocator)
	p.type = make([dynamic]u8, allocator)
	p.id = make([dynamic]u8, allocator)
}

event_parser_destroy :: proc(p: ^Event_Parser) {
	delete(p.line)
	delete(p.data)
	delete(p.type)
	delete(p.id)
	p^ = {}
}

// The next bytes of a stream, cut anywhere. .Stop: `on_event` asked it, or the parse is too large (p.too_large); the
// parser takes nothing more then.
event_parser_feed :: proc(p: ^Event_Parser, bytes: []u8, on_event: Event_Proc, user: rawptr) -> Keep_Going {
	if p.too_large { return .Stop }
	rest := bytes
	for len(rest) > 0 {
		if p.after_cr {
			p.after_cr = false
			if rest[0] == '\n' { rest = rest[1:]; continue }
		}
		end := strings.index_any(string(rest), "\r\n")
		run := end < 0 ? rest : rest[:end]
		if len(p.line) + len(run) > p.max_bytes { p.too_large = true; return .Stop }
		append(&p.line, ..run)
		if end < 0 { break }
		p.after_cr = rest[end] == '\r'
		rest = rest[end + 1:]
		if line_end(p, on_event, user) == .Stop { return .Stop }
	}
	return .Continue
}

@(private = "file")
line_end :: proc(p: ^Event_Parser, on_event: Event_Proc, user: rawptr) -> Keep_Going {
	defer clear(&p.line)
	line := string(p.line[:])
	if !p.later_line {
		p.later_line = true
		line = strings.trim_prefix(line, "\uFEFF")
	}
	if line == "" { return dispatch(p, on_event, user) }
	if line[0] == ':' { return .Continue }   // a comment (a server's heartbeat)
	field, value := line, ""
	if colon := strings.index_byte(line, ':'); colon >= 0 {
		field, value = line[:colon], line[colon + 1:]
		if strings.has_prefix(value, " ") { value = value[1:] }
	}
	switch field {
	case "event":
		clear(&p.type)
		append(&p.type, value)
	case "data":
		if len(p.data) + len(value) + 1 > p.max_bytes { p.too_large = true; return .Stop }
		append(&p.data, value)
		append(&p.data, '\n')
	case "id":
		if strings.index_byte(value, 0) < 0 {
			clear(&p.id)
			append(&p.id, value)
		}
	case "retry":
		digits := value != ""
		for c in transmute([]u8)value { if c < '0' || c > '9' { digits = false } }
		if digits {
			if n, ok := strconv.parse_int(value, 10); ok { p.retry = n }
		}
	}
	return .Continue
}

// A blank line: the event in progress goes out, unless it has no data line.
@(private = "file")
dispatch :: proc(p: ^Event_Parser, on_event: Event_Proc, user: rawptr) -> Keep_Going {
	defer { clear(&p.data); clear(&p.type) }
	if len(p.data) == 0 { return .Continue }
	e := Event{
		type  = len(p.type) == 0 ? "message" : string(p.type[:]),
		data  = string(p.data[:len(p.data) - 1]),   // (the last line's "\n" is no part of it)
		id    = string(p.id[:]),
		retry = p.retry,
	}
	return on_event(user, e)
}

// The checks of request, shared with events and ws_connect: an http or https URL, a method and header names that are
// tokens, header values with no line break.
@(private)
request_check :: proc(method, url: string, req: Request) -> Error {
	if _, ok := url_parse(url); !ok { return .Bad_Url }
	if !is_token(method) { return .Bad_Request }
	for h in req.headers {
		// (a line break in a header would let a value write headers of its own, or end them early)
		if !is_token(h.name) || strings.contains_any(h.value, "\r\n\x00") { return .Bad_Request }
	}
	return .None
}
