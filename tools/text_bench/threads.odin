package text_bench

// -threads: the cost of the font package's locks on its hot paths, with one thread and with several doing the same
// work at once (a browser lays pages out on several threads, each measuring and shaping text; its paint and the
// interface's draw look glyph bitmaps up). Every path is warmed first: what is timed is the hit, where a lock is
// the main cost; a miss (a new word, shaped) is timed for scale. Prints Markdown: per operation, as each thread sees it
// (flat across thread counts: no contention).

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "../../font"

THREAD_COUNTS :: [?]int{1, 2, 4, 8}
// Operations per thread per path: a few tenths of a second each.
HIT_ROUNDS :: 2000
MISS_WORDS :: 2000
BENCH_SIZE :: 16
BENCH_FAMILY :: "Segoe UI"
// Glyph bitmaps per glyph: the draw layer asks at up to `subpixel_steps` pen positions.
BENCH_SUBPIXELS :: 4
// Words of more bytes than the threads' own width cache keeps (font/shape.odin L1_TEXT) go to the shared cache.
LONG_WORD_MIN :: 31

// Short words, as a page has (the threads' width cache answers them).
SHORT_WORDS :: [?]string{
	"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "and", "of", "to", "in", "is", "that", "for", "it",
	"with", "as", "was", "on", "be", "at", "by", "this", "had", "not", "are", "but", "from", "or", "have", "an",
}
// A line of a page: shape() copies each of its words from the shared cache.
LINE :: "The quick brown fox jumps over the lazy dog, and the five boxing wizards jump quickly over it."

Path :: enum { Measure_Short, Measure_Long, Shape_Line, Glyph_Image, Glyph_Images, Slug_Glyph, Slug_Glyphs, Measure_Miss }

PATH_NAMES := [Path]string{
	.Measure_Short = "measure, short word (hit)",
	.Measure_Long  = "measure, long word (hit)",
	.Shape_Line    = "shape, per word of a line (hit)",
	.Glyph_Image   = "glyph_image, per glyph (hit)",
	.Glyph_Images  = "glyph_images, per glyph of a run (hit)",
	.Slug_Glyph    = "slug_glyph, per glyph (hit)",
	.Slug_Glyphs   = "slug_glyphs, per glyph of a run (hit)",
	.Measure_Miss  = "measure, new word (miss: shaped)",
}

Bench :: struct {
	s:       ^font.State,
	id:      font.Font_Id,
	path:    Path,
	long:    []string,
	glyphs:  []font.Glyph_Pos,
	start:   sync.Barrier,
	ops:     int,              // per thread, set by the threads (all the same)
	serial:  int,              // threads started: tells the miss words of each thread apart
}

threads_bench :: proc() {
	s := make_state(font.DEFAULT_SETTINGS.backend, font.DEFAULT_SETTINGS.word_cache)
	defer { font.destroy(s); free(s) }
	id, ok := font.load_system(s, BENCH_FAMILY)
	if !ok { fmt.eprintln("text_bench: no", BENCH_FAMILY); return }
	b := Bench{s = s, id = id}
	// long words: short ones joined until they are longer than the threads' width cache keeps
	long := make([dynamic]string)
	defer { for w in long { delete(w) }; delete(long) }
	words := SHORT_WORDS
	for i in 0 ..< len(words) {
		sb := strings.builder_make()
		for k := i; strings.builder_len(sb) < LONG_WORD_MIN; k += 1 {
			if strings.builder_len(sb) > 0 { strings.write_byte(&sb, '-') }
			strings.write_string(&sb, words[k % len(words)])
		}
		append(&long, strings.to_string(sb))
	}
	b.long = long[:]
	sh := font.shape(s, id, BENCH_SIZE, LINE)
	defer font.shaped_destroy(&sh)
	b.glyphs = sh.glyphs
	fmt.printf("Threads: %s %d px, backend %v, %d words per long-word list.\n\n", BENCH_FAMILY, BENCH_SIZE, font.backend(s), len(long))
	fmt.print("| path (ns per operation per thread) |")
	for n in THREAD_COUNTS { fmt.printf(" %d thread%s |", n, n > 1 ? "s" : "") }
	fmt.print("\n|---|")
	for _ in THREAD_COUNTS { fmt.print("---|") }
	fmt.println()
	for p in Path {
		b.path = p
		fmt.printf("| %s |", PATH_NAMES[p])
		for n in THREAD_COUNTS { fmt.printf(" %.1f |", run_path(&b, n)) }
		fmt.println()
	}
	fmt.println()
}

// Nanoseconds per operation as each of `n` threads sees it (wall time / operations of one thread).
run_path :: proc(b: ^Bench, n: int) -> f64 {
	bench_work(b, true)   // warm: words cached, bitmaps made
	sync.barrier_init(&b.start, n + 1)
	ths := make([]^thread.Thread, n, context.temp_allocator)
	for &th in ths { th = thread.create_and_start_with_data(b, proc(data: rawptr) { bench_work((^Bench)(data), false) }) }
	sync.barrier_wait(&b.start)
	t0 := time.tick_now()
	for th in ths { thread.join(th); thread.destroy(th) }
	d := time.tick_since(t0)
	return f64(time.duration_nanoseconds(d)) / f64(max(b.ops, 1))
}

bench_work :: proc(b: ^Bench, warm: bool) {
	if !warm { sync.barrier_wait(&b.start) }
	s, id := b.s, b.id
	rounds := warm ? 1 : HIT_ROUNDS
	ops := 0
	switch b.path {
	case .Measure_Short:
		words := SHORT_WORDS
		for _ in 0 ..< rounds { for w in words { font.measure(s, id, BENCH_SIZE, w) }; ops += len(words) }
	case .Measure_Long:
		for _ in 0 ..< rounds { for w in b.long { font.measure(s, id, BENCH_SIZE, w) }; ops += len(b.long) }
	case .Shape_Line:
		n := strings.count(LINE, " ") * 2 + 1   // words and spaces
		for _ in 0 ..< rounds {
			font.shape(s, id, BENCH_SIZE, LINE, {}, context.temp_allocator)
			free_all(context.temp_allocator)
			ops += n
		}
	case .Glyph_Image:
		for _ in 0 ..< rounds {
			for g in b.glyphs { for sub in 0 ..< BENCH_SUBPIXELS { font.glyph_image(s, g.face, g.id, BENCH_SIZE, sub) } }
			ops += len(b.glyphs) * BENCH_SUBPIXELS
		}
	case .Glyph_Images:
		reqs := make([]font.Glyph_Request, len(b.glyphs) * BENCH_SUBPIXELS, context.temp_allocator)
		out := make([]font.Glyph_Image, len(reqs), context.temp_allocator)
		for g, i in b.glyphs {
			for sub in 0 ..< BENCH_SUBPIXELS { reqs[i * BENCH_SUBPIXELS + sub] = {g.face, g.id, u8(sub)} }
		}
		for _ in 0 ..< rounds {
			font.glyph_images(s, BENCH_SIZE, reqs, out)
			ops += len(reqs)
		}
	case .Slug_Glyph:
		for _ in 0 ..< rounds {
			for g in b.glyphs { font.slug_glyph(s, g.face, g.id) }
			ops += len(b.glyphs)
		}
	case .Slug_Glyphs:
		out := make([]font.Slug_Glyph, len(b.glyphs), context.temp_allocator)
		for _ in 0 ..< rounds {
			font.slug_glyphs(s, b.glyphs, 0, out)
			ops += len(b.glyphs)
		}
	case .Measure_Miss:
		if warm { return }
		me := sync.atomic_add(&b.serial, 1)
		buf: [64]u8
		for i in 0 ..< MISS_WORDS { font.measure(s, id, BENCH_SIZE, fmt.bprintf(buf[:], "w%dq%dz", me, i)) }
		ops = MISS_WORDS
	}
	if !warm { sync.atomic_store(&b.ops, ops) }
}
