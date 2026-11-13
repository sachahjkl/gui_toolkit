// A region cut from desktop_parts' frames (crop_parts, part_holding): one output at a fractional scale beside one at
// scale 1, the case where the composed desktop enlarges the second. Made-up frames: they run on every system.
//   odin test tests/capture -vet
package capture_test

import "core:testing"
import "../../src/capture"

// Each pixel says where it is in its own frame: x in R and G, y in B, the part's mark in A.
@(private = "file")
part_make :: proc(w, h: i32, scale: f32, origin: [2]i32, mark: u8) -> capture.Frame {
	f := capture.Frame{width = w, height = h, stride = w * 4, scale = scale, origin = origin, order = .RGBA, allocator = context.temp_allocator}
	f.pixels = make([]u8, int(w * h * 4), context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := f.pixels[int(y * f.stride + x * 4):][:4]
			p[0], p[1], p[2], p[3] = u8(x), u8(x >> 8), u8(y), mark
		}
	}
	return f
}

// A 300 x 150 logical output at 4/3 (400 x 200 pixels), and to its right one of 300 x 150 at 1.
@(private = "file")
two_outputs :: proc() -> []capture.Frame {
	parts := make([]capture.Frame, 2, context.temp_allocator)
	parts[0] = part_make(400, 200, 400.0 / 300.0, {0, 0}, 1)
	parts[1] = part_make(300, 150, 1, {300, 0}, 2)
	return parts
}

@(test)
the_part_that_holds_a_rect :: proc(t: ^testing.T) {
	parts := two_outputs()
	testing.expect_value(t, capture.part_holding(parts, {10, 10, 50, 50}), 0)
	testing.expect_value(t, capture.part_holding(parts, {300, 0, 300, 150}), 1)   // the whole of the second
	testing.expect_value(t, capture.part_holding(parts, {290, 10, 20, 20}), -1)   // across both
	testing.expect_value(t, capture.part_holding(parts, {700, 10, 5, 5}), -1)     // off both
}

// The regression: a region on the output at scale 1 keeps its pixels one for one. Cut from the composed desktop (at 4/3)
// it was enlarged by the nearest pixel, one column in four a copy of the one before.
@(test)
a_region_on_the_lower_scale_keeps_its_pixels :: proc(t: ^testing.T) {
	parts := two_outputs()
	r := capture.Rect{330, 20, 90, 60}
	cut, ok := capture.crop_parts(parts, r, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, cut.width, i32(90))
	testing.expect_value(t, cut.height, i32(60))
	testing.expect_value(t, cut.scale, f32(1))
	for y in 0 ..< cut.height {
		for x in 0 ..< cut.width {
			p := cut.pixels[int(y * cut.stride + x * 4):][:4]
			want_x, want_y := x + (r.x - 300), y + r.y
			if p[3] != 2 || i32(p[0]) | i32(p[1]) << 8 != want_x || i32(p[2]) != want_y {
				testing.expectf(t, false, "pixel %d,%d: %v, want x %d y %d of the second", x, y, p, want_x, want_y)
				return
			}
		}
	}

	// (the composed desktop's cut, for contrast: 4/3 as wide, and some columns repeated)
	whole, composed := capture.compose(parts, context.temp_allocator)
	testing.expect(t, composed)
	old, _ := capture.crop(whole, r, context.temp_allocator)
	testing.expect_value(t, old.width, i32(120))
}

// A region on the output at the higher scale is that output's own pixels, as the composed desktop gave them.
@(test)
a_region_on_the_higher_scale_is_as_before :: proc(t: ^testing.T) {
	parts := two_outputs()
	r := capture.Rect{30, 15, 150, 75}
	cut, ok := capture.crop_parts(parts, r, context.temp_allocator)
	testing.expect(t, ok)
	whole, _ := capture.compose(parts, context.temp_allocator)
	old, _ := capture.crop(whole, r, context.temp_allocator)
	testing.expect_value(t, cut.width, old.width)
	testing.expect_value(t, cut.height, old.height)
	testing.expect(t, string(cut.pixels) == string(old.pixels))
	testing.expect_value(t, cut.pixels[3], u8(1))
}

// Across both outputs: composed at the higher scale, then cut, as the composed desktop gave it. Off both: nothing.
@(test)
a_region_across_outputs_is_composed :: proc(t: ^testing.T) {
	parts := two_outputs()
	r := capture.Rect{250, 30, 100, 60}
	cut, ok := capture.crop_parts(parts, r, context.temp_allocator)
	testing.expect(t, ok)
	whole, _ := capture.compose(parts, context.temp_allocator)
	old, _ := capture.crop(whole, r, context.temp_allocator)
	testing.expect_value(t, cut.width, old.width)
	testing.expect_value(t, cut.height, old.height)
	testing.expect(t, string(cut.pixels) == string(old.pixels))

	_, ok = capture.crop_parts(parts, {900, 0, 10, 10}, context.temp_allocator)
	testing.expect(t, !ok)
	_, ok = capture.crop_parts(parts, {10, 10, 0, 10}, context.temp_allocator)
	testing.expect(t, !ok)
}
