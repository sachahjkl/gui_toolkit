package capture_test

// A buffer read as a frame in the order asked (the fast path of an upright opaque screen, and the general one), and a
// frame's channels put in another order.

import "core:testing"
import "../../src/capture"

// Two pixels a row, two rows, with four bytes of padding after each row; B, G, R, A.
@(private = "file")
BUFFER := [?]u8{
	1, 2, 3, 0, 4, 5, 6, 0, 9, 9, 9, 9,
	7, 8, 9, 0, 10, 11, 12, 0, 9, 9, 9, 9,
}

@(test)
an_opaque_screen_is_read_in_the_order_asked :: proc(t: ^testing.T) {
	src := BUFFER
	f := capture.frame_from_buffer(src[:], 2, 2, 12, .BGRA, .Normal, false, true, context.temp_allocator, .RGBA)
	testing.expect_value(t, f.order, capture.Pixel_Order.RGBA)
	want := [?]u8{3, 2, 1, 255, 6, 5, 4, 255, 9, 8, 7, 255, 12, 11, 10, 255}
	testing.expect(t, string(f.pixels) == string(want[:]))

	same := capture.frame_from_buffer(src[:], 2, 2, 12, .BGRA, .Normal, true, true, context.temp_allocator)
	want_bgra := [?]u8{7, 8, 9, 255, 10, 11, 12, 255, 1, 2, 3, 255, 4, 5, 6, 255}   // (y_invert: the rows swapped)
	testing.expect(t, string(same.pixels) == string(want_bgra[:]))
}

// The general path (a turned buffer) gives the order asked too.
@(test)
a_turned_buffer_is_read_in_the_order_asked :: proc(t: ^testing.T) {
	src := BUFFER
	f := capture.frame_from_buffer(src[:], 2, 2, 12, .BGRA, .Rot180, false, true, context.temp_allocator, .RGBA)
	want := [?]u8{12, 11, 10, 255, 9, 8, 7, 255, 6, 5, 4, 255, 3, 2, 1, 255}
	testing.expect(t, string(f.pixels) == string(want[:]))
}

@(test)
a_frame_changes_order_in_place :: proc(t: ^testing.T) {
	px := [?]u8{1, 2, 3, 40, 4, 5, 6, 50}
	f := capture.Frame{pixels = px[:], width = 2, height = 1, stride = 8, scale = 1}
	capture.frame_order_set(&f, .RGBA)
	testing.expect_value(t, f.order, capture.Pixel_Order.RGBA)
	want := [?]u8{3, 2, 1, 40, 6, 5, 4, 50}
	testing.expect(t, string(px[:]) == string(want[:]))
	capture.frame_order_set(&f, .RGBA)   // (already: nothing moves)
	testing.expect(t, string(px[:]) == string(want[:]))
}
