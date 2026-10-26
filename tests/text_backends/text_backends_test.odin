// The text backends against each other (no times: tools/text_bench measures them).
//   odin test tests/text_backends -vet                              the dwrite backend alone (what any build has)
//   odin test tests/text_backends -vet -define:FONT_BACKEND=native   native against DirectWrite on the corpus
// (the native library first: powershell -File tools\build_text.ps1)
package text_backends_test

import "core:testing"
import "../../font"
import corpus "../../tools/text_corpus"

_ :: corpus   // used by the native tests only

make_state :: proc(b: font.Backend) -> ^font.State {
	st := font.DEFAULT_SETTINGS
	st.backend = b
	s := new(font.State)
	font.init(s, st)
	return s
}

free_state :: proc(s: ^font.State) { font.destroy(s); free(s) }

@(test)
backend_selection :: proc(t: ^testing.T) {
	s := make_state(.Dwrite)
	defer free_state(s)
	testing.expect(t, s.ok)
	testing.expect_value(t, font.backend(s), font.Backend.Dwrite)
	testing.expect(t, font.backend_available(.Dwrite))
	testing.expect_value(t, font.backend_available(.Native), font.NATIVE_TEXT)
	// a backend the build lacks gives the build's own
	n := make_state(.Native)
	defer free_state(n)
	testing.expect(t, n.ok)
	testing.expect_value(t, font.backend(n), font.NATIVE_TEXT ? font.Backend.Native : font.Backend.Dwrite)
	fams := font.system_families(s, context.temp_allocator)
	testing.expect(t, len(fams) > 10, "the system lists its families")
	found := false
	for f in fams { if f == "Segoe UI" { found = true } }
	testing.expect(t, found, "Segoe UI is listed")
}

when font.NATIVE_TEXT {

// What the two backends must agree on exactly, sample by sample: the line break opportunities, the bidi levels, and
// the glyphs of the scripts both shape the same way. EXACT lists the samples whose glyph ids and clusters are identical
// (the others: a precomposed letter with its marks in latin-marks, one cluster for an emoji with its skin tone in emoji).
EXACT :: []string{"latin", "latin-liga", "latin-kern", "cyrillic-greek", "arabic", "arabic-mixed", "hebrew", "devanagari",
	"thai", "lao", "khmer", "myanmar", "cjk-zh", "cjk-ja", "korean", "variable", "fallback"}

@(test)
native_matches_dwrite :: proc(t: ^testing.T) {
	dw := make_state(.Dwrite)
	nt := make_state(.Native)
	defer { free_state(dw); free_state(nt) }
	testing.expect_value(t, font.backend(nt), font.Backend.Native)
	for sm in corpus.SAMPLES {
		a, oka := corpus.sample_font(dw, sm)
		b, okb := corpus.sample_font(nt, sm)
		if !oka || !okb { continue }   // a font this Windows lacks
		la := font.bidi_levels(dw, sm.text, sm.dir, context.temp_allocator)
		lb := font.bidi_levels(nt, sm.text, sm.dir, context.temp_allocator)
		testing.expectf(t, string(la) == string(lb), "%s: bidi levels %v / %v", sm.name, la, lb)
		ba := font.line_breaks(dw, sm.text, context.temp_allocator)
		bb := font.line_breaks(nt, sm.text, context.temp_allocator)
		switch sm.name {
		case "thai", "lao", "khmer", "myanmar":
			// dictionaries differ (ICU4X's / Windows'; Windows finds none in Lao, Khmer and Myanmar): words are found
			testing.expectf(t, len(bb) >= 2, "%s: native line breaks %v", sm.name, bb)
		case:
			same := len(ba) == len(bb)
			if same { for x, i in ba { if x != bb[i] { same = false } } }
			testing.expectf(t, same, "%s: line breaks %v / %v", sm.name, ba, bb)
		}
		sa := font.shape(dw, a, 20, sm.text, {direction = sm.dir}, context.temp_allocator)
		sb := font.shape(nt, b, 20, sm.text, {direction = sm.dir}, context.temp_allocator)
		// every sample: the same line width
		testing.expectf(t, abs(sa.width - sb.width) < 0.05, "%s: width %v / %v", sm.name, sa.width, sb.width)
		exact := false
		for e in EXACT { if e == sm.name { exact = true } }
		if !exact { continue }
		testing.expectf(t, len(sa.glyphs) == len(sb.glyphs), "%s: %d / %d glyphs", sm.name, len(sa.glyphs), len(sb.glyphs))
		if len(sa.glyphs) != len(sb.glyphs) { continue }
		for g, i in sa.glyphs {
			h := sb.glyphs[i]
			// x too, but in right-to-left runs: DirectWrite drops the XPlacement of a kerning pair there (Segoe UI's
			// Hebrew: 20 and 50 font units), HarfBuzz applies it (docs/font-backend.md)
			testing.expectf(t, g.id == h.id && g.cluster == h.cluster && abs(g.advance - h.advance) < 0.01 && (g.rtl || abs(g.x - h.x) < 0.05),
				"%s glyph %d: dwrite %v / native %v", sm.name, i, g, h)
		}
		testing.expectf(t, font.face_metrics(dw, a) == font.face_metrics(nt, b), "%s: metrics %v / %v", sm.name, font.face_metrics(dw, a), font.face_metrics(nt, b))
	}
}

// A memory face (a web font) and the Slug outlines of both backends.
@(test)
native_memory_face_and_outlines :: proc(t: ^testing.T) {
	dw := make_state(.Dwrite)
	nt := make_state(.Native)
	defer { free_state(dw); free_state(nt) }
	a, oka := font.load_embedded(dw, font.FALLBACK_UI_DATA)
	b, okb := font.load_embedded(nt, font.FALLBACK_UI_DATA)
	testing.expect(t, oka && okb)
	testing.expect_value(t, font.text_width(nt, b, 16, "Roboto"), font.text_width(dw, a, 16, "Roboto"))
	sh := font.shape(nt, b, 16, "g", {}, context.temp_allocator)
	testing.expect(t, len(sh.glyphs) == 1)
	if len(sh.glyphs) != 1 { return }
	gid := sh.glyphs[0].id
	oa, ob: font.Outline
	defer { font.outline_destroy(&oa); font.outline_destroy(&ob) }
	testing.expect(t, font.dwrite_outline_provider(dw, a, gid, 1.0 / 4096, &oa))
	testing.expect(t, font.native_outline_provider(nt, b, gid, 1.0 / 4096, &ob))
	testing.expectf(t, len(oa.ends) == len(ob.ends) && len(oa.ends) > 0, "contours %d / %d", len(oa.ends), len(ob.ends))
	for k in 0 ..< 4 { testing.expectf(t, abs(oa.bbox[k] - ob.bbox[k]) < 1e-3, "bbox %v / %v", oa.bbox, ob.bbox) }
	// a font the library cannot read is refused, not a crash
	_, bad := font.load_from_memory(nt, nil)
	testing.expect(t, !bad)
}

}
