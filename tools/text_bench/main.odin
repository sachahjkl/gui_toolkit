// Compares the native text backend with DirectWrite on the corpus of tools/text_corpus: the same glyphs, clusters,
// advances, metrics, bidi levels and line breaks (equivalence), and, with -perf, the cost of shaping a word and a run
// with and without the word cache. Needs the native library:
//   powershell -File tools\build_text.ps1
//   odin run tools/text_bench -vet -define:FONT_BACKEND=native -o:speed -out:build/text_bench.exe -- [-perf] [-v]
// Prints Markdown. Times are never checked by a test (machine dependent): they are printed for a person to read.
package text_bench

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "../../font"
import corpus "../text_corpus"

ADV_TOLERANCE :: 0.01   // px: two advances closer than this are the same

verbose: bool

main :: proc() {
	perf := false
	for a in os.args[1:] {
		switch a {
		case "-perf": perf = true
		case "-v": verbose = true
		}
	}
	when !font.NATIVE_TEXT {
		fmt.eprintln("text_bench: build with -define:FONT_BACKEND=native (and tools/build_text.ps1 first)")
		os.exit(2)
	} else {
		dw := make_state(.Dwrite, 32768)
		nt := make_state(.Native, 32768)
		defer { font.destroy(dw); free(dw); font.destroy(nt); free(nt) }
		if !dw.ok || !nt.ok || font.backend(nt) != .Native { fmt.eprintln("text_bench: a backend did not start"); os.exit(1) }
		equivalence(dw, nt)
		if perf { costs() }
	}
}

make_state :: proc(b: font.Backend, cache: int) -> ^font.State {
	st := font.DEFAULT_SETTINGS
	st.backend = b
	st.word_cache = cache
	s := new(font.State)
	font.init(s, st)
	return s
}

Diff :: struct {
	glyphs, glyph_ids, cluster_sets, adv_over: int,
	max_adv, width_dw, width_nt:                f32,
	bidi_same, breaks_same:                     bool,
	metrics:                                    string,
}

equivalence :: proc(dw, nt: ^font.State) {
	fmt.println("| sample | glyphs dw / native | different ids | same clusters | advances off (> 0.01 px) | max advance gap (px) | width dw / native (px) | bidi | line breaks |")
	fmt.println("|---|---|---|---|---|---|---|---|---|")
	metrics_rows := make([dynamic]string, context.temp_allocator)
	for sm in corpus.SAMPLES {
		a, oka := corpus.sample_font(dw, sm)
		b, okb := corpus.sample_font(nt, sm)
		if !oka || !okb { fmt.printf("| %s | no font %q | | | | | | | |\n", sm.name, sm.family); continue }
		size := f32(20)
		sa := font.shape(dw, a, size, sm.text, {direction = sm.dir}, context.temp_allocator)
		sb := font.shape(nt, b, size, sm.text, {direction = sm.dir}, context.temp_allocator)
		d: Diff
		d.width_dw, d.width_nt = sa.width, sb.width
		n := min(len(sa.glyphs), len(sb.glyphs))
		for i in 0 ..< n {
			ga, gb := sa.glyphs[i], sb.glyphs[i]
			if ga.id != gb.id { d.glyph_ids += 1 }
			gap := abs(ga.advance - gb.advance)
			if gap > ADV_TOLERANCE { d.adv_over += 1 }
			d.max_adv = max(d.max_adv, gap)
		}
		d.glyph_ids += abs(len(sa.glyphs) - len(sb.glyphs))
		same_clusters := len(sa.clusters) == len(sb.clusters)
		if same_clusters {
			for c, i in sa.clusters {
				if c.start != sb.clusters[i].start || c.end != sb.clusters[i].end { same_clusters = false; break }
			}
		}
		la := font.bidi_levels(dw, sm.text, sm.dir, context.temp_allocator)
		lb := font.bidi_levels(nt, sm.text, sm.dir, context.temp_allocator)
		d.bidi_same = slices_equal(la, lb)
		ba := font.line_breaks(dw, sm.text, context.temp_allocator)
		bb := font.line_breaks(nt, sm.text, context.temp_allocator)
		d.breaks_same = len(ba) == len(bb)
		if d.breaks_same { for x, i in ba { if x != bb[i] { d.breaks_same = false; break } } }
		fmt.printf("| %s | %d / %d | %d | %v | %d | %.3f | %.2f / %.2f | %s | %s |\n", sm.name, len(sa.glyphs), len(sb.glyphs), d.glyph_ids,
			same_clusters ? "yes" : "**no**", d.adv_over, d.max_adv, d.width_dw, d.width_nt, d.bidi_same ? "same" : "**differs**", d.breaks_same ? "same" : breaks_text(ba, bb))
		if verbose && (d.glyph_ids > 0 || !same_clusters || d.adv_over > 0) { detail(sm.name, sa, sb) }
		ma, mb := font.face_metrics(dw, a), font.face_metrics(nt, b)
		if ma != mb { append(&metrics_rows, fmt.tprintf("| %s | %v | %v |", sm.name, ma, mb)) }
	}
	fmt.println()
	if len(metrics_rows) == 0 {
		fmt.println("Design metrics (ascent, descent, line gap, x / cap height, underline, strike): identical for every face of the corpus.")
	} else {
		fmt.println("| face metrics that differ | dwrite | native |")
		fmt.println("|---|---|---|")
		for r in metrics_rows { fmt.println(r) }
	}
	fmt.println()
}

breaks_text :: proc(a, b: []font.Break_Opportunity) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "**dw")
	for x in a { fmt.sbprintf(&sb, " %d%s", x.at, x.mandatory ? "!" : "") }
	strings.write_string(&sb, " / native")
	for x in b { fmt.sbprintf(&sb, " %d%s", x.at, x.mandatory ? "!" : "") }
	strings.write_string(&sb, "**")
	return strings.to_string(sb)
}

detail :: proc(name: string, a, b: font.Shaped) {
	fmt.printf("\n<details><summary>%s</summary>\n\n```\n", name)
	for i in 0 ..< max(len(a.glyphs), len(b.glyphs)) {
		ga, gb: font.Glyph_Pos
		if i < len(a.glyphs) { ga = a.glyphs[i] }
		if i < len(b.glyphs) { gb = b.glyphs[i] }
		fmt.printf("%3d dw id %5d cl %3d x %8.3f adv %7.3f | nt id %5d cl %3d x %8.3f adv %7.3f%s\n", i, ga.id, ga.cluster, ga.x, ga.advance,
			gb.id, gb.cluster, gb.x, gb.advance, ga.id != gb.id || abs(ga.advance - gb.advance) > ADV_TOLERANCE ? "  <" : "")
	}
	fmt.printf("clusters dw:")
	for c in a.clusters { fmt.printf(" [%d,%d)", c.start, c.end) }
	fmt.printf("\nclusters nt:")
	for c in b.clusters { fmt.printf(" [%d,%d)", c.start, c.end) }
	fmt.printf("\n```\n</details>\n\n")
}

slices_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a { if x != b[i] { return false } }
	return true
}

// Microseconds per call: shaping each word of the corpus (no cache: every word shaped; cache: the second pass), and
// each whole sample (a run of several words) without the cache.
costs :: proc() {
	fmt.println("| backend | per word, no cache (µs) | per word, cached (µs) | per run, no cache (µs) | bidi + breaks per sample (µs) |")
	fmt.println("|---|---|---|---|---|")
	for b in ([]font.Backend{.Dwrite, .Native}) {
		cold := make_state(b, 0)
		warm := make_state(b, 32768)
		words, runs := 0, 0
		t_cold, t_warm, t_run, t_an: time.Duration
		ROUNDS :: 20
		for sm in corpus.SAMPLES {
			ic, ok1 := corpus.sample_font(cold, sm)
			iw, ok2 := corpus.sample_font(warm, sm)
			if !ok1 || !ok2 { continue }
			ws := strings.split(sm.text, " ")
			defer delete(ws)
			// warm up both (faces opened, plans built), then measure
			for w in ws { font.measure(cold, ic, 20, w); font.measure(warm, iw, 20, w) }
			for _ in 0 ..< ROUNDS {
				t0 := time.tick_now()
				for w in ws { font.measure(cold, ic, 20, w) }
				t_cold += time.tick_since(t0)
				t0 = time.tick_now()
				for w in ws { font.measure(warm, iw, 20, w) }
				t_warm += time.tick_since(t0)
				t0 = time.tick_now()
				font.shape(cold, ic, 20, sm.text, {direction = sm.dir}, context.temp_allocator)
				t_run += time.tick_since(t0)
				t0 = time.tick_now()
				font.bidi_levels(cold, sm.text, sm.dir, context.temp_allocator)
				font.line_breaks(cold, sm.text, context.temp_allocator)
				t_an += time.tick_since(t0)
				words += len(ws)
				runs += 1
				free_all(context.temp_allocator)
			}
		}
		us :: proc(d: time.Duration, n: int) -> f64 { return n > 0 ? time.duration_microseconds(d) / f64(n) : 0 }
		fmt.printf("| %v | %.2f | %.3f | %.2f | %.2f |\n", b, us(t_cold, words), us(t_warm, words), us(t_run, runs), us(t_an, runs))
		font.destroy(cold); free(cold)
		font.destroy(warm); free(warm)
	}
	fmt.println()
}
