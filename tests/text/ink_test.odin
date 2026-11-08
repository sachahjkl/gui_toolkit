package text_test

import "core:testing"
import "../../src/font"

// A band under the baseline: `p` goes down through it, `x` stops above it.
@(private = "file") BAND_TOP_EM :: 0.1
@(private = "file") BAND_BOTTOM_EM :: 0.15
@(private = "file") SIZE :: 40

@(private = "file")
open_face :: proc(t: ^testing.T, s: ^font.State) -> font.Font_Id {
	font.init(s)
	id, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	testing.expect(t, ok, "the font of the toolkit")
	return id
}

@(test)
ink_is_read_from_the_outlines_along_a_band :: proc(t: ^testing.T) {
	s: font.State
	id := open_face(t, &s)
	defer font.destroy(&s)
	sh := font.shape(&s, id, SIZE, "xp", {}, context.temp_allocator)
	testing.expect_value(t, len(sh.glyphs), 2)
	_, _, in_x := font.glyph_ink_extent(&s, sh.glyphs[0].face, sh.glyphs[0].id, -BAND_BOTTOM_EM, -BAND_TOP_EM)
	testing.expect(t, !in_x, "an x does not go under the baseline")
	a, b, in_p := font.glyph_ink_extent(&s, sh.glyphs[1].face, sh.glyphs[1].id, -BAND_BOTTOM_EM, -BAND_TOP_EM)
	testing.expect(t, in_p && a > 0 && b > a && b < 0.3, "the stem of a p, on its left")
	again_a, again_b, again := font.glyph_ink_extent(&s, sh.glyphs[1].face, sh.glyphs[1].id, -BAND_BOTTOM_EM, -BAND_TOP_EM)
	testing.expect(t, again && again_a == a && again_b == b, "kept")
	tall_a, tall_b, tall := font.glyph_ink_extent(&s, sh.glyphs[1].face, sh.glyphs[1].id, 0.2, 0.3)
	testing.expect(t, tall && tall_a <= a && tall_b > b + 0.1, "through its bowl it is wider")
	// across: a band of its width, the extent of its height: the stem goes from under the baseline to the x height
	c, d, side := font.glyph_ink_extent(&s, sh.glyphs[1].face, sh.glyphs[1].id, a, b, true)
	testing.expect(t, side && c < -BAND_BOTTOM_EM && d > 0.3, "the stem from the side")
}

@(test)
a_run_has_its_ink_in_spans_joined_by_their_gap :: proc(t: ^testing.T) {
	s: font.State
	id := open_face(t, &s)
	defer font.destroy(&s)
	sh := font.shape(&s, id, SIZE, "pxxxp", {}, context.temp_allocator)
	spans := font.run_ink_spans(&s, sh.glyphs, SIZE, BAND_TOP_EM * SIZE, BAND_BOTTOM_EM * SIZE, 1)
	testing.expect_value(t, len(spans), 2)
	wide := font.run_ink_spans(&s, sh.glyphs, SIZE, BAND_TOP_EM * SIZE, BAND_BOTTOM_EM * SIZE, sh.width)
	testing.expect_value(t, len(wide), 1)
	testing.expect(t, spans[0][1] < sh.glyphs[1].x + 2 && spans[1][0] > sh.glyphs[3].x, "where the two p are")
}
