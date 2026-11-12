// pointer_from_buffer: a point of an output's buffer, turned and scaled, as a point on the desktop. No desktop needed.
//   odin test tests/capture -vet
package capture_test

import "core:testing"
import "../../src/capture"

// At scale 1, for each of the eight turns, the point lands where frame_from_buffer puts that pixel of the buffer:
// the two read a turned buffer the same way.
@(test)
pointer_follows_the_picture_turned :: proc(t: ^testing.T) {
	width, height := i32(5), i32(3)
	pos := [2]i32{3, 1}
	src := make([]u8, int(width * height * 4), context.temp_allocator)
	for &b in src[int((pos.y * width + pos.x) * 4):][:4] { b = 255 }
	for turn in capture.Turn {
		f := capture.frame_from_buffer(src, width, height, width * 4, .BGRA, turn, false, false, context.temp_allocator)
		marked := [2]i32{-1, -1}
		for y in 0 ..< f.height {
			for x in 0 ..< f.width {
				if f.pixels[int(y * f.stride + x * 4) + 3] == 255 { marked = {x, y} }
			}
		}
		place := capture.Rect{100, 200, f.width, f.height}
		got := capture.pointer_from_buffer(pos, {width, height}, turn, place)
		testing.expectf(t, got == marked + [2]i32{100, 200}, "%v: %v, the picture has it at %v", turn, got, marked)
	}
}

// The buffer covers the output's logical rect: at scale 2 two pixels are one logical, and the output's place is added.
@(test)
pointer_is_scaled_and_placed :: proc(t: ^testing.T) {
	place := capture.Rect{1920, -100, 1920, 1080}
	testing.expect_value(t, capture.pointer_from_buffer({101, 51}, {3840, 2160}, .Normal, place), [2]i32{1970, -75})
	// A quarter turn: the buffer is the mode on its side (2160 x 3840 shown as 3840 x 2160).
	// Its point (0, 0) is upright at the top right.
	testing.expect_value(t, capture.pointer_from_buffer({0, 0}, {2160, 3840}, .Rot90, place), [2]i32{1920 + 1919, -100})
	// A fractional scale (1.5): 2880 pixels over 1920 logical ones.
	testing.expect_value(t, capture.pointer_from_buffer({1500, 900}, {2880, 1620}, .Normal, {0, 0, 1920, 1080}), [2]i32{1000, 600})
}

// A point outside the buffer (the protocol allows it) is outside the output, on the side it is.
@(test)
pointer_outside_the_buffer :: proc(t: ^testing.T) {
	place := capture.Rect{0, 0, 1000, 500}
	testing.expect_value(t, capture.pointer_from_buffer({-3, 10}, {1000, 500}, .Normal, place), [2]i32{-3, 10})
}
