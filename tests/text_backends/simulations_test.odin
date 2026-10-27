package text_backends_test

import "core:testing"
import "../unwatched"
import "../../font"

_ :: testing   // the test needs the native backend
_ :: unwatched

when font.NATIVE_TEXT {

// Simulated bold and oblique (a web font family without its bold or italic face): the native backend draws and measures
// them as DirectWrite does (font/simulate.odin): the same widths, the same outline boxes for Slug.
@(test)
native_simulations_match_dwrite :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	dw := make_state(.Dwrite)
	nt := make_state(.Native)
	defer { free_state(dw); free_state(nt) }
	a, _ := font.load_embedded(dw, font.FALLBACK_UI_DATA)
	b, _ := font.load_embedded(nt, font.FALLBACK_UI_DATA)
	for sims in ([][2]bool{{true, false}, {false, true}, {true, true}}) {
		sa := font.with_simulations(dw, a, sims[0], sims[1])
		sb := font.with_simulations(nt, b, sims[0], sims[1])
		testing.expect(t, sa != a && sb != b)
		for txt in ([]string{"Hamburgefonstiv", "iiii WWW", "office"}) {
			wa, wb := font.text_width(dw, sa, 40, txt), font.text_width(nt, sb, 40, txt)
			testing.expectf(t, abs(wa - wb) < 0.01, "%v %q: width dwrite %v native %v", sims, txt, wa, wb)
		}
		for ch in ([]string{"H", "o", "g", "W", "e"}) {
			sh := font.shape(nt, sb, 16, ch, {}, context.temp_allocator)
			gid := sh.glyphs[0].id
			oa, ob: font.Outline
			font.dwrite_outline_provider(dw, sa, gid, 1.0 / 4096, &oa)
			font.native_outline_provider(nt, sb, gid, 1.0 / 4096, &ob)
			// equal for right angles and curves; at the acute corners of a W DirectWrite's miter is a little shorter
			// (0.0027 em: a tenth of a pixel at 40 px)
			for k in 0 ..< 4 { testing.expectf(t, abs(oa.bbox[k] - ob.bbox[k]) < 3e-3, "%v %q: bbox dwrite %v native %v", sims, ch, oa.bbox, ob.bbox) }
			testing.expect_value(t, len(ob.ends), len(oa.ends))
			font.outline_destroy(&oa); font.outline_destroy(&ob)
		}
	}
}) }

}
