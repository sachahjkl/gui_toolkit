package tk_rpc

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
parsed :: proc(text: string) -> Parsed {
	v, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if err != .None { return {} }
	return read_message(v)
}

@(test)
each_shape_of_message :: proc(t: ^testing.T) {
	r := parsed(`{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"a":1}}`)
	testing.expect_value(t, r.shape, Shape.Request)
	testing.expect_value(t, r.method, "session/prompt")
	testing.expect(t, r.id.kind == .Number && r.id.number == 3)
	r = parsed(`{"jsonrpc":"2.0","id":"abc","method":"fs/read_text_file"}`)
	testing.expect_value(t, r.shape, Shape.Request)
	testing.expect_value(t, id_text(&r.id), "abc")
	r = parsed(`{"jsonrpc":"2.0","id":null,"method":"x"}`)
	testing.expect(t, r.shape == .Request && r.id.kind == .Null)
	r = parsed(`{"jsonrpc":"2.0","method":"session/update","params":[]}`)
	testing.expect_value(t, r.shape, Shape.Notification)
	r = parsed(`{"jsonrpc":"2.0","id":7,"result":{"ok":true}}`)
	testing.expect(t, r.shape == .Answer && r.has_result && r.id.number == 7)
	r = parsed(`{"jsonrpc":"2.0","id":7,"result":null}`)
	testing.expect(t, r.shape == .Answer && r.has_result, "a null result is a result")
	r = parsed(`{"jsonrpc":"2.0","id":8,"error":{"code":-32800,"message":"cancelled","data":{"x":1}}}`)
	testing.expect(t, r.shape == .Answer && !r.has_result)
	testing.expect_value(t, r.error.code, i64(-32800))
	testing.expect_value(t, r.error.message, "cancelled")
	r = parsed(`{"jsonrpc":"2.0","id":9.0,"result":1}`)
	testing.expect(t, r.shape == .Answer && r.id.number == 9, "a whole float is an id")
	// what is no message
	testing.expect_value(t, parsed(`[1]`).shape, Shape.Invalid)
	testing.expect_value(t, parsed(`"x"`).shape, Shape.Invalid)
	testing.expect_value(t, parsed(`{"jsonrpc":"2.0"}`).shape, Shape.Invalid)
	testing.expect_value(t, parsed(`{"id":4}`).shape, Shape.Invalid_With_Id)
	r = parsed(`{"id":4,"method":5}`)
	testing.expect(t, r.shape == .Invalid_With_Id && r.id.number == 4)
	r = parsed(`{"id":{"x":1},"method":"m"}`)
	testing.expect(t, r.shape == .Invalid_With_Id && r.id.kind == .Null, "an invalid id is answered with null")
	long := strings.concatenate({`{"id":"`, strings.repeat("i", ID_TEXT_MAX + 1, context.temp_allocator), `","method":"m"}`}, context.temp_allocator)
	r = parsed(long)
	testing.expect(t, r.shape == .Invalid_With_Id && r.id.kind == .Null, "a string id beyond ID_TEXT_MAX")
}

@(test)
messages_on_the_wire :: proc(t: ^testing.T) {
	req := encode_request(.Lines, 5, "session/new", "{\n  \"cwd\": \"/a\"\n}", context.temp_allocator)
	testing.expect_value(t, string(req), "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"session/new\",\"params\":{   \"cwd\": \"/a\" }}\n")
	n := encode_notification(.Lines, "session/cancel", "", context.temp_allocator)
	testing.expect_value(t, string(n), "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\"}\n")
	id, _ := id_of_text("q\"1")
	res := encode_result(.Lines, id, "", context.temp_allocator)
	testing.expect_value(t, string(res), "{\"jsonrpc\":\"2.0\",\"id\":\"q\\\"1\",\"result\":null}\n")
	e := encode_error(.Content_Length, {}, METHOD_NOT_FOUND, "no such method", `{"m":"x"}`, context.temp_allocator)
	body := `{"jsonrpc":"2.0","id":null,"error":{"code":-32601,"message":"no such method","data":{"m":"x"}}}`
	testing.expect_value(t, string(e), strings.concatenate({"Content-Length: 95\r\n\r\n", body}, context.temp_allocator))
	testing.expect_value(t, len(body), 95)
	// (what the peer writes, it reads back)
	for text in ([]string{string(req), string(n), string(res)}) {
		v, err := json.parse_string(strings.trim_right(text, "\n"), .JSON, true, context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		testing.expect(t, read_message(v).shape != .Invalid)
	}
}

@(test)
the_depth_is_bounded_before_the_parse :: proc(t: ^testing.T) {
	deep := strings.concatenate({strings.repeat("[", DEPTH_MAX + 1, context.temp_allocator), strings.repeat("]", DEPTH_MAX + 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, !depth_ok(transmute([]u8)deep))
	ok := strings.concatenate({strings.repeat("{\"a\":", DEPTH_MAX - 1, context.temp_allocator), "[]", strings.repeat("}", DEPTH_MAX - 1, context.temp_allocator)}, context.temp_allocator)
	testing.expect(t, depth_ok(transmute([]u8)ok))
	// (brackets inside strings, an escaped quote, do not count)
	in_string := strings.concatenate({`{"a":"\"`, strings.repeat("[", 500, context.temp_allocator), `"}`}, context.temp_allocator)
	testing.expect(t, depth_ok(transmute([]u8)in_string))
}

@(test)
the_tail_keeps_the_last_bytes :: proc(t: ^testing.T) {
	tail := tail_make(8, context.temp_allocator)
	tail_write(&tail, transmute([]u8)string("abc"))
	testing.expect_value(t, tail_text(&tail, context.temp_allocator), "abc")
	tail_write(&tail, transmute([]u8)string("defgh"))
	testing.expect_value(t, tail_text(&tail, context.temp_allocator), "abcdefgh")
	tail_write(&tail, transmute([]u8)string("ij"))
	testing.expect_value(t, tail_text(&tail, context.temp_allocator), "cdefghij")
	tail_write(&tail, transmute([]u8)string("0123456789xyz"))
	testing.expect_value(t, tail_text(&tail, context.temp_allocator), "56789xyz")
	for _ in 0 ..< 100 { tail_write(&tail, transmute([]u8)string("k")) }
	testing.expect_value(t, tail_text(&tail, context.temp_allocator), "kkkkkkkk")
}
