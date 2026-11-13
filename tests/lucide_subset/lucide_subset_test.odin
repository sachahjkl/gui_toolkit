// A subset of the Lucide font (toolbox.font_subset), as the font package reads it: each icon kept is the glyph the whole
// font draws for it, an icon left out is not in the face.
//   odin test tests/lucide_subset -vet
package lucide_subset_test

import "core:slice"
import "core:testing"
import "../../src/font"
import toolbox "../../src/toolbox"

@(private = "file") LUCIDE_TTF :: #load("../../src/lucide/lucide.ttf")
@(private = "file") LUCIDE_ODIN :: #load("../../src/lucide/lucide.odin", string)
@(private = "file") SIZE :: 16
// Fine enough that a difference in a curve shows in its pieces.
@(private = "file") TOLERANCE :: 0.25

// The glyph the face draws for `c` with no other font to fall back to (0: none).
@(private = "file")
glyph_of :: proc(s: ^font.State, face: font.Font_Id, c: rune) -> u16 {
	buf: [4]u8
	n := 0
	switch {
	case c < 0x80: buf[0] = u8(c); n = 1
	case c < 0x800: buf[0], buf[1] = u8(0xc0 | c >> 6), u8(0x80 | c & 0x3f); n = 2
	case c < 0x10000: buf[0], buf[1], buf[2] = u8(0xe0 | c >> 12), u8(0x80 | (c >> 6) & 0x3f), u8(0x80 | c & 0x3f); n = 3
	}
	only := font.cascade(s, {{font = face}}, no_system_fallback = true)
	sh := font.shape(s, only, SIZE, string(buf[:n]), {}, context.temp_allocator)
	if len(sh.glyphs) != 1 || sh.glyphs[0].face != face { return 0 }
	return sh.glyphs[0].id
}

@(test)
the_font_package_reads_a_subset :: proc(t: ^testing.T) {
	kept := toolbox.lucide_codes(LUCIDE_ODIN, {"SEARCH", "X", "CHECK", "TRASH_2", "SLIDERS_HORIZONTAL"})
	dropped := toolbox.lucide_codes(LUCIDE_ODIN, {"ANCHOR", "BELL"})
	sub, why := toolbox.font_subset(LUCIDE_TTF, kept, context.temp_allocator)
	if !testing.expect_value(t, why, "") { return }

	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	whole, wok := font.load_embedded(s, LUCIDE_TTF)
	part, pok := font.load_embedded(s, sub)
	if !testing.expect(t, wok && pok, "both fonts load") { return }
	for c in kept {
		was, now := glyph_of(s, whole, c), glyph_of(s, part, c)
		if !testing.expectf(t, was != 0 && now != 0, "U+%04X: a glyph in both (%d, %d)", c, was, now) { continue }
		a, b: font.Outline
		defer font.outline_destroy(&a)
		defer font.outline_destroy(&b)
		got_a := font.glyph_outline(s, whole, was, TOLERANCE, &a)
		got_b := font.glyph_outline(s, part, now, TOLERANCE, &b)
		testing.expectf(t, got_a && got_b && len(a.quads) > 0, "U+%04X: an outline in both", c)
		testing.expectf(t, slice.equal(a.quads[:], b.quads[:]) && slice.equal(a.ends[:], b.ends[:]), "U+%04X: the same outline", c)
		testing.expect_value(t, font.glyph(s, part, SIZE, c).advance, font.glyph(s, whole, SIZE, c).advance)
	}
	for c in dropped {
		testing.expect(t, glyph_of(s, whole, c) != 0)
		testing.expectf(t, glyph_of(s, part, c) == 0, "U+%04X is not in the subset", c)
	}
}
