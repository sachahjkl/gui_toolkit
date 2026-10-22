package colr_test

import "core:fmt"
import "core:testing"
import "../../font"

COLRV1 :: #load("../color_glyphs/data/test_glyphs-glyf_colr_1.ttf")

@(test)
debug_one :: proc(t: ^testing.T) {
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	st := s.settings
	st.color_engine = .Builtin
	font.set_settings(&s, st)
	id, ok := font.load_embedded(&s, COLRV1)
	testing.expect(t, ok)
	cas := font.cascade(&s, {{font = id}}, nil, true)
	sh := font.shape(&s, cas, 64, "\U000F0100", {}, context.temp_allocator)
	fmt.println("glyphs", len(sh.glyphs), sh.glyphs[0].id)
	img := font.glyph_image(&s, id, sh.glyphs[0].id, 64, 0)
	fmt.println(img)
}
