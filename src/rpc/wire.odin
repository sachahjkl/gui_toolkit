#+private
package tk_rpc

// JSON-RPC 2.0 on the wire, as pure procedures: an id read and written, the shape of a parsed message, the bytes of a
// message to send, and the depth scan that runs before a parse (rpc.md).

import "core:encoding/json"
import "core:math"
import "core:strings"
import tk_json "../json"

// An id read from a message: a number (a whole float too), a string of ID_TEXT_MAX bytes at most, or null.
id_parse :: proc(v: json.Value) -> (id: Id, ok: bool) {
	#partial switch x in v {
	case json.Null:    return {}, true
	case json.Integer: return id_of_number(x), true
	case json.Float:
		if x >= -9223372036854775808.0 && x < 9223372036854775808.0 && math.trunc(x) == x { return id_of_number(i64(x)), true }
	case json.String:  return id_of_text(x)
	}
	return
}

write_id :: proc(b: ^strings.Builder, id: Id) {
	switch id.kind {
	case .Null:   strings.write_string(b, "null")
	case .Number: strings.write_i64(b, id.number)
	case .Text:   id := id; tk_json.quote_into(b, id_text(&id))
	}
}

// What a parsed value is.
Shape :: enum u8 {
	Invalid,           // no JSON-RPC object, and no id to answer
	Invalid_With_Id,   // no valid message, but an id was given: answered with INVALID_REQUEST (`id` null when its id is invalid)
	Request,
	Notification,
	Answer,            // a result or an error for a request of ours
}

// A parsed message's parts (they point into the value).
Parsed :: struct {
	shape:      Shape,
	method:     string,
	params:     json.Value,
	id:         Id,
	has_result: bool,
	result:     json.Value,
	error:      Error_Object,
}

// The shape and the parts of one JSON-RPC message (not a batch: an array is Invalid here).
read_message :: proc(v: json.Value) -> (p: Parsed) {
	obj, is_object := v.(json.Object)
	if !is_object { return }
	idv, has_id := obj["id"]
	id_ok := false
	if has_id { p.id, id_ok = id_parse(idv) }
	if mv, has_method := obj["method"]; has_method {
		m, is_text := mv.(json.String)
		if !is_text || !id_ok && has_id {
			p.shape = has_id ? .Invalid_With_Id : .Invalid
			if !id_ok { p.id = {} }
			return
		}
		p.method = m
		p.params = obj["params"] or_else nil
		p.shape = has_id ? .Request : .Notification
		return
	}
	result, has_result := obj["result"]
	errv, has_error := obj["error"]
	if has_id && id_ok && (has_result || has_error) {
		p.shape = .Answer
		p.has_result = has_result && !has_error
		p.result = result
		if has_error {
			p.error.code = tk_json.integer(errv, "code", default = INTERNAL_ERROR)
			p.error.message = tk_json.text(errv, "message")
			p.error.data = tk_json.get(errv, "data")
		}
		return
	}
	p.shape = has_id ? .Invalid_With_Id : .Invalid
	if !id_ok { p.id = {} }
	return
}

// Whether a JSON text nests DEPTH_MAX levels at most (the brackets outside strings). Linear, no allocation.
depth_ok :: proc(text: []u8, depth_max := DEPTH_MAX) -> bool {
	depth := 0
	in_string, escaped := false, false
	for c in text {
		if in_string {
			if escaped { escaped = false } else if c == '\\' { escaped = true } else if c == '"' { in_string = false }
			continue
		}
		switch c {
		case '"':      in_string = true
		case '[', '{':
			depth += 1
			if depth > depth_max { return false }
		case ']', '}': depth -= 1
		}
	}
	return true
}

// A request's bytes, framed. `params` is JSON text ("": none). In `allocator`.
encode_request :: proc(framing: Framing, id: i64, method: string, params: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	strings.write_i64(&b, id)
	write_call(&b, method, params)
	return frame_bytes(framing, strings.to_string(b), allocator)
}

encode_notification :: proc(framing: Framing, method: string, params: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0"`)
	write_call(&b, method, params)
	return frame_bytes(framing, strings.to_string(b), allocator)
}

// A result for the request `id` ("": null).
encode_result :: proc(framing: Framing, id: Id, result: string, allocator := context.allocator) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_id(&b, id)
	strings.write_string(&b, `,"result":`)
	strings.write_string(&b, result != "" ? result : "null")
	strings.write_byte(&b, '}')
	return frame_bytes(framing, strings.to_string(b), allocator)
}

// An error for the request `id`; `data` is JSON text ("": none).
encode_error :: proc(framing: Framing, id: Id, code: i64, message: string, data := "", allocator := context.allocator) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"jsonrpc":"2.0","id":`)
	write_id(&b, id)
	strings.write_string(&b, `,"error":{"code":`)
	strings.write_i64(&b, code)
	strings.write_string(&b, `,"message":`)
	tk_json.quote_into(&b, message)
	if data != "" {
		strings.write_string(&b, `,"data":`)
		strings.write_string(&b, data)
	}
	strings.write_string(&b, "}}")
	return frame_bytes(framing, strings.to_string(b), allocator)
}

@(private = "file")
write_call :: proc(b: ^strings.Builder, method, params: string) {
	strings.write_string(b, `,"method":`)
	tk_json.quote_into(b, method)
	if params != "" {
		strings.write_string(b, `,"params":`)
		strings.write_string(b, params)
	}
	strings.write_byte(b, '}')
}

// The body on the wire. Lines: a raw line break of the program's JSON text (whitespace between tokens: a string holds
// none) becomes a space, and '\n' ends the message. Content_Length: the header, then the body.
@(private = "file")
frame_bytes :: proc(framing: Framing, body: string, allocator := context.allocator) -> []u8 {
	switch framing {
	case .Lines:
		out := make([]u8, len(body) + 1, allocator)
		copy(out, body)
		for &c in out[:len(body)] { if c == '\n' || c == '\r' { c = ' ' } }
		out[len(body)] = '\n'
		return out
	case .Content_Length:
		b := strings.builder_make(0, len(body) + 32, allocator)
		strings.write_string(&b, "Content-Length: ")
		strings.write_int(&b, len(body))
		strings.write_string(&b, "\r\n\r\n")
		strings.write_string(&b, body)
		return b.buf[:]
	}
	return nil
}
