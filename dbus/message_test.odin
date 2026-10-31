package dbus

import "core:testing"

@(private = "file")
framed :: proc() -> []u8 {
	w := writer_make(context.temp_allocator)
	w_string(&w, "the body")
	return build_message(7, .Method_Return, 0, "", "", "", ":1.1", "", 3, "s", w.buf[:], context.temp_allocator)
}

// The bytes of a message read back, and a message still arriving is told from one that cannot be.
@(test)
a_message_whole_cut_or_broken :: proc(t: ^testing.T) {
	bytes := framed()
	msg, total, ok := parse_message(bytes, context.temp_allocator)
	testing.expect(t, ok, "whole")
	testing.expect_value(t, total, len(bytes))
	testing.expect_value(t, msg.reply_serial, u32(3))
	testing.expect_value(t, msg.destination, ":1.1")
	r := msg_reader(&msg)
	testing.expect_value(t, r_string(&r), "the body")

	for cut in ([?]int{MIN_MESSAGE_BYTES, len(bytes) - 1}) {
		_, n, got := parse_message(bytes[:cut], context.temp_allocator)
		testing.expectf(t, !got && n == 0, "%d bytes: still arriving (%v, %d)", cut, got, n)
	}

	endian := make([]u8, len(bytes), context.temp_allocator)
	copy(endian, bytes)
	endian[0] = 'x'
	_, n1, got1 := parse_message(endian, context.temp_allocator)
	testing.expect(t, !got1 && n1 < 0, "not a byte order")

	// the first field's string says it runs past all there is
	long := make([]u8, len(bytes), context.temp_allocator)
	copy(long, bytes)
	long[24], long[25], long[26], long[27] = 0xff, 0xff, 0, 0
	_, n2, got2 := parse_message(long, context.temp_allocator)
	testing.expect(t, !got2 && n2 < 0, "a field past the end")

	// (the body's length, in the fixed header)
	huge := make([]u8, len(bytes), context.temp_allocator)
	copy(huge, bytes)
	huge[4], huge[5], huge[6], huge[7] = 0, 0, 0, 0x7f
	_, n3, got3 := parse_message(huge, context.temp_allocator)
	testing.expect(t, !got3 && n3 < 0, "over the spec's limit, which would never arrive")
}

// A reply's copy shares nothing with the message it comes from, whose memory goes back when it is routed.
@(test)
a_reply_outlives_its_message :: proc(t: ^testing.T) {
	bytes := framed()
	msg, _, _ := parse_message(bytes, context.temp_allocator)
	kept := message_clone(msg, context.temp_allocator)
	for &b in msg.body_bytes { b = 0 }
	(transmute([]u8)msg.destination)[0] = 0
	r := msg_reader(&kept)
	testing.expect_value(t, r_string(&r), "the body")
	testing.expect_value(t, kept.destination, ":1.1")
}
