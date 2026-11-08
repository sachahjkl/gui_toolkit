// The native text backend off Windows: variable faces. Their axes come from 'fvar', and an instance is a face of its own,
// opened at its location: a page's font-weight on a variable web font (Fira Code: wght 300..700, default 300) draws at
// that weight, not at the font's default instance.
#+build !windows
package color_native_test

import "core:testing"
import "../../src/font"

// Inter's variable face, cut to "H" and "m" (data/inter-LICENSE.txt): opsz 14..32, wght 100..900 (default 400).
INTER_HM :: #load("data/inter-variable-hm.ttf")

@(test)
a_variable_face_has_its_axes_and_instances :: proc(t: ^testing.T) {
	s := new(font.State)
	defer free(s)
	font.init(s)
	defer font.destroy(s)
	face, ok := font.load_embedded(s, INTER_HM)
	if !testing.expect(t, ok, "the face loads") { return }

	axes := font.axes(s, face, context.temp_allocator)
	wght := -1
	for a, i in axes { if a.tag == {'w', 'g', 'h', 't'} { wght = i } }
	if !testing.expectf(t, wght >= 0, "a wght axis among %v", axes) { return }
	testing.expect_value(t, axes[wght].min, 100)
	testing.expect_value(t, axes[wght].default, 400)
	testing.expect_value(t, axes[wght].max, 900)

	thin := font.with_variations(s, face, {{{'w', 'g', 'h', 't'}, 100}})
	black := font.with_variations(s, face, {{{'w', 'g', 'h', 't'}, 900}})
	testing.expect(t, thin != face && black != face && thin != black, "each instance is a face of its own")
	testing.expect_value(t, font.with_variations(s, face, {{{'w', 'g', 'h', 't'}, 900}}), black)   // (the same instance again)
	// Inter's advances grow with the weight: the instance is drawn and measured at its location
	w_thin, w_regular, w_black := font.text_width(s, thin, 40, "HmHm"), font.text_width(s, face, 40, "HmHm"), font.text_width(s, black, 40, "HmHm")
	testing.expectf(t, w_thin < w_regular && w_regular < w_black, "widths at wght 100, 400, 900: %v %v %v", w_thin, w_regular, w_black)

	// a static face has no axes, and no instance
	static_face, sok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	if testing.expect(t, sok) {
		testing.expect_value(t, len(font.axes(s, static_face, context.temp_allocator)), 0)
		testing.expect_value(t, font.with_variations(s, static_face, {{{'w', 'g', 'h', 't'}, 700}}), static_face)
	}
}
