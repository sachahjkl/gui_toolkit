package scenarios_test

// Contrast (ui.contrast, ui.readable): WCAG's ratio, and a colour moved along its OKLCH lightness only as far as it must to read on a
// ground: lighter on a dark one, darker on a light one, its hue kept; at the end, black or white.

import "core:math"
import "core:testing"
import "../../src/draw"
import "../../src/ui"
import "../../src/testkit/unwatched"

@(test)
contrast_is_wcags :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	testing.expect(t, math.abs(ui.contrast({0, 0, 0, 1}, {1, 1, 1, 1}) - 21) < 0.01, "black on white: 21")
	testing.expect(t, math.abs(ui.contrast({1, 1, 1, 1}, {1, 1, 1, 1}) - 1) < 0.001, "a colour on itself: 1")
	a, b := draw.hex(0x767676ff), draw.hex(0xffffffff)
	testing.expect(t, math.abs(ui.contrast(a, b) - 4.54) < 0.02, "#767676 on white: 4.54, AA's edge")
}) }

@(test)
readable_moves_a_colour_only_as_far_as_it_must :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
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
}) }

@(test)
oklch_goes_and_comes_back :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for v in ([]u32{0xfab283ff, 0x5c9cf5ff, 0x101010ff, 0xffffffff, 0x7fd88fff}) {
		c := draw.hex(v)
		back := ui.from_oklch(ui.to_oklch(c), c.a)
		testing.expectf(t, math.abs(back.r - c.r) < 0.002 && math.abs(back.g - c.g) < 0.002 && math.abs(back.b - c.b) < 0.002, "%08x back as it was", v)
	}
}) }

// The shades of a colour go from its lightest tint to its deepest, its hue kept; of them, shade_on finds one that reads on
// a ground.
@(test)
shades_go_from_tint_to_deep :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	blue := draw.hex(0x3b82f6ff)
	prev := 2.0
	for s in ui.Shade {
		c := ui.shade(blue, s)
		lch := ui.to_oklch(c)
		testing.expectf(t, lch[0] < prev, "%v is darker than the shade before it", s)
		prev = lch[0]
		if s >= .S300 && s <= .S800 {
			testing.expectf(t, math.abs(lch[2] - ui.to_oklch(blue)[2]) < 8, "%v keeps the hue: %.1f", s, lch[2])
		}
	}
	for ground in ([]u32{0xffffffff, 0x101010ff, 0xdbeafeff, 0x1e3a8aff}) {
		g := draw.hex(ground)
		testing.expectf(t, ui.contrast(ui.shade_on(blue, g, 4.5), g) >= 4.5, "a shade of blue reads on %x", ground)
	}
}) }

// Every theme's intents, dark and light: a soft fill of the intent's hue and words of that hue that read on it (AA).
@(test)
every_soft_pair_reads :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for th in ui.THEMES {
		for light in ([]bool{false, true}) {
			if (light && th.versions == .Dark_Only) || (!light && th.versions == .Light_Only) { continue }
			p := ui.theme_palette(th, light)
			page := draw.hex(p.bg | 0xff)
			for hue in ([]u32{p.accent, p.good, p.warn, p.bad, p.blue != 0 ? p.blue : p.accent}) {
				fill, ink := ui.soft_pair_on(draw.hex(hue | 0xff), page)
				testing.expectf(t, ui.contrast(ink, fill) >= 4.5, "%s (%s): %x's words read on its soft fill (%.2f)", th.name, light ? "light" : "dark", hue, ui.contrast(ink, fill))
			}
		}
	}
}) }
