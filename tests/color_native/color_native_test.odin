// Color glyphs off Windows, with the native text backend: COLR through the interpreter, CBDT from its PNG images.
#+build !windows
package color_native_test

import "core:testing"
import "../../font"

COLR :: #load("../color_glyphs/data/test_glyphs-glyf_colr_1.ttf")
CBDT :: #load("../color_glyphs/data/chromacheck-cbdt.ttf")

@(private = "file") GIDS_TRIED :: 256

// The first color glyph of a face, drawn: it must have pixels of a color, in the size asked for.
@(private = "file")
check_face :: proc(t: ^testing.T, data: []byte, what: string) {
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	face, ok := font.load_embedded(s, data)
	if !testing.expectf(t, ok, "%s loads", what) { return }
	gid := -1
	for g in 0 ..< GIDS_TRIED { if font.glyph_is_color(s, face, u16(g), 32) { gid = g; break } }
	if !testing.expectf(t, gid >= 0, "%s has color glyphs", what) { return }
	img, drawn := font.color_glyph_rgba(s, face, u16(gid), 32, {0, 0, 0}, context.allocator)
	if !testing.expectf(t, drawn, "%s: glyph %d is drawn", what, gid) { return }
	defer delete(img.px)
	testing.expectf(t, img.w > 0 && img.h > 0 && img.w <= 256 && img.h <= 256, "%s: a sensible size, %d x %d", what, img.w, img.h)
	colored := 0
	for i := 0; i + 4 <= len(img.px); i += 4 {
		p := img.px[i:][:4]
		if p[3] > 128 && (max(p[0], p[1], p[2]) - min(p[0], p[1], p[2])) > 30 { colored += 1 }
	}
	testing.expectf(t, colored > 0, "%s: pixels of a color (%d)", what, colored)
	// and through the atlas, as text is drawn
	atlas := font.glyph_image(s, face, u16(gid), 32, 0, {0, 0, 0})
	testing.expectf(t, atlas.color && atlas.page >= 0, "%s: a color page (%v)", what, atlas)
}

@(test) colr_glyphs_are_drawn :: proc(t: ^testing.T) { check_face(t, COLR, "COLR") }
@(test) cbdt_glyphs_are_drawn :: proc(t: ^testing.T) { check_face(t, CBDT, "CBDT") }

// A face without color tables stays what it was.
@(test)
a_plain_face_has_no_color_glyphs :: proc(t: ^testing.T) {
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	face, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	for g in 0 ..< GIDS_TRIED { testing.expect(t, !font.glyph_is_color(s, face, u16(g), 32)) }
}
