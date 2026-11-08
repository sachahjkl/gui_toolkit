package scenarios_test

// Contrast (ui.contrast, ui.readable): WCAG's ratio, and a colour moved along its OKLCH lightness only as far as it must to read on a
// ground: lighter on a dark one, darker on a light one, its hue kept; at the end, black or white.

import "core:math"
import "core:testing"
import "../../src/draw"
import "../../src/ui"

@(test)
contrast_is_wcags :: proc(t: ^testing.T) {
	testing.expect(t, math.abs(ui.contrast({0, 0, 0, 1}, {1, 1, 1, 1}) - 21) < 0.01, "black on white: 21")
	testing.expect(t, math.abs(ui.contrast({1, 1, 1, 1}, {1, 1, 1, 1}) - 1) < 0.001, "a colour on itself: 1")
	a, b := draw.hex(0x767676ff), draw.hex(0xffffffff)
	testing.expect(t, math.abs(ui.contrast(a, b) - 4.54) < 0.02, "#767676 on white: 4.54, AA's edge")
}

@(test)
readable_moves_a_colour_only_as_far_as_it_must :: proc(t: ^testing.T) {
	dark, light := draw.hex(0x202020ff), draw.hex(0xf4f4f4ff)
	fine := draw.hex(0xe0e0e0ff)
	testing.expect_value(t, ui.readable(fine, dark, 4.5), fine)
	grey := draw.hex(0x5a5a5aff)
	up := ui.readable(grey, dark, 4.5)
	testing.expect(t, ui.contrast(up, dark) >= 4.5 && ui.luminance(up) > ui.luminance(grey), "lighter on a dark ground")
	down := ui.readable(grey, light, 7)
	testing.expect(t, ui.contrast(down, light) >= 7 && ui.luminance(down) < ui.luminance(grey), "darker on a light ground")
	// a colour keeps its hue
	orange := draw.hex(0xc8622aff)
	lit := ui.readable(orange, draw.hex(0x101010ff), 7)
	h0, h1 := ui.to_oklch(orange)[2], ui.to_oklch(lit)[2]
	testing.expectf(t, math.abs(h0 - h1) < 6, "its hue: %.1f, then %.1f", h0, h1)
	// out of reach: white, or black
	testing.expect_value(t, ui.readable(grey, draw.hex(0x808080ff), 21), draw.Color{0, 0, 0, 1})
}

@(test)
oklch_goes_and_comes_back :: proc(t: ^testing.T) {
	for v in ([]u32{0xfab283ff, 0x5c9cf5ff, 0x101010ff, 0xffffffff, 0x7fd88fff}) {
		c := draw.hex(v)
		back := ui.from_oklch(ui.to_oklch(c), c.a)
		testing.expectf(t, math.abs(back.r - c.r) < 0.002 && math.abs(back.g - c.g) < 0.002 && math.abs(back.b - c.b) < 0.002, "%08x back as it was", v)
	}
}
