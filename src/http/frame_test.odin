package tk_http

import "core:testing"

@(test)
a_frame_comes_back_as_it_left :: proc(t: ^testing.T) {
	for size in ([]int{0, 5, 125, 126, 65535, 65536}) {
		payload := make([]u8, size, context.temp_allocator)
		for i in 0 ..< size { payload[i] = u8(i) }
		mask := [4]u8{1, 2, 3, 4}
		sent := ws_encode(WS_TEXT, payload, mask, context.temp_allocator)
		// (a server's frame is this one without the mask: strip it, and undo it)
		at := size < 126 ? 2 : (size < 65536 ? 4 : 10)
		plain := make([dynamic]u8, context.temp_allocator)
		append(&plain, sent[0], sent[1] & 0x7f)
		append(&plain, ..sent[2:at])
		for b, i in sent[at + 4:] { append(&plain, b ~ mask[i % 4]) }
		opcode, fin, got, used, complete := ws_decode(plain[:])
		testing.expect(t, complete && fin)
		testing.expect_value(t, opcode, u8(WS_TEXT))
		testing.expect_value(t, used, len(plain))
		testing.expect_value(t, string(got), string(payload))
	}
}

@(test)
half_a_frame_waits_for_the_rest :: proc(t: ^testing.T) {
	_, _, _, used, complete := ws_decode({0x81, 5, 'h', 'e'})
	testing.expect(t, !complete)
	testing.expect_value(t, used, 7)   // (the head is known: the frame's size)
	_, _, _, used, complete = ws_decode({0x81})
	testing.expect(t, !complete)
	testing.expect_value(t, used, 0)
	_, _, _, used, complete = ws_decode({0x81, 126, 0})
	testing.expect(t, !complete, "half a length")
	testing.expect_value(t, used, 0)
	// A 64-bit length past any limit: its size says so, and nothing overflows.
	_, _, _, used, complete = ws_decode({0x82, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff})
	testing.expect(t, !complete)
	testing.expect(t, used > MAX_BYTES, "a size past any limit")
}

@(test)
a_frame_not_final_says_so :: proc(t: ^testing.T) {
	opcode, fin, payload, _, complete := ws_decode({0x01, 2, 'a', 'b', 0x80, 1, 'c'})
	testing.expect(t, complete && !fin)
	testing.expect_value(t, opcode, u8(WS_TEXT))
	testing.expect_value(t, string(payload), "ab")
	opcode, fin, payload, _, complete = ws_decode({0x80, 1, 'c'})
	testing.expect(t, complete && fin)
	testing.expect_value(t, opcode, u8(WS_CONTINUATION))
	testing.expect_value(t, string(payload), "c")
}
