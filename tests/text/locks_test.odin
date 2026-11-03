// The font package's shared caches from several threads at once (docs/locks.md): the word cache (hits under a
// shard's shared lock, misses and generation changes alone) and the lookups of a whole run in the atlas and the Slug
// store (glyph_images, slug_glyphs: one shared lock per run) give what one thread gets, and a glyph several threads
// ask for at once is made once.
package text_test

import "core:sync"
import "core:testing"
import "core:thread"
import "../unwatched"
import "../../font"

LOCK_THREADS :: 8
LOCK_ROUNDS :: 50
LOCK_SIZE :: 15
// Sizes the threads draw at: the first is the one every thread shares, the others one per thread pair (different glyphs).
LOCK_SIZES :: [?]f32{15, 17, 19, 23}
// A word cache this small turns its generations over all the time (words go to the old one and come back).
LOCK_SMALL_CACHE :: 1
// Lines of text with Latin, Hebrew, Arabic, CJK (system fallback) and ligatures.
LOCK_LINES :: [?]string{
	"The quick brown fox jumps over the lazy dog",
	"office affluent fjord, waffle shuffle",
	"שלום world سلام",
	"中文 and 日本語 text",
	"the the the of of and and to to in in",
}

// Each thread shapes and measures every line (each thread starting at another one, every size), on a word cache whose
// generations turn over: the glyphs, clusters and widths are those of a state without a word cache.
@(test)
words_from_threads_are_those_of_one :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	ref_settings := font.DEFAULT_SETTINGS
	ref_settings.word_cache = 0
	ref := setup(t, ref_settings)
	defer teardown(ref)
	small := font.DEFAULT_SETTINGS
	small.word_cache = LOCK_SMALL_CACHE
	for settings in ([]font.Settings{font.DEFAULT_SETTINGS, small}) {
		s := setup(t, settings)
		defer teardown(s)
		Job :: struct { t: ^testing.T, s, ref: ^font.State, id, ref_id: font.Font_Id, next, bad: int }
		job := Job{t = t, s = s, ref = ref, id = sys(t, s, "Segoe UI"), ref_id = sys(t, ref, "Segoe UI")}
		threads: [LOCK_THREADS]^thread.Thread
		for &th in threads {
			th = thread.create_and_start_with_data(&job, proc(data: rawptr) {
				j := (^Job)(data)
				me := sync.atomic_add(&j.next, 1)
				lines, sizes := LOCK_LINES, LOCK_SIZES
				for round in 0 ..< LOCK_ROUNDS {
					line := lines[(me + round) % len(lines)]
					size := sizes[(me / 2 + round) % len(sizes)]
					got := font.shape(j.s, j.id, size, line, {}, context.temp_allocator)
					want := font.shape(j.ref, j.ref_id, size, line, {}, context.temp_allocator)
					same := shaped_same(got, want, j.id, j.ref_id) && font.measure(j.s, j.id, size, line) == font.measure(j.ref, j.ref_id, size, line)
					if !same { sync.atomic_add(&j.bad, 1) }
					free_all(context.temp_allocator)
				}
			})
		}
		for th in threads { thread.join(th); thread.destroy(th) }
		testing.expectf(t, job.bad == 0, "word cache of %d words: %d shapes differ from one without a cache", settings.word_cache, job.bad)
	}
}) }

// The two states load the same face: the same glyphs, positions and clusters (faces compared as "the first one").
@(private = "file")
shaped_same :: proc(a, b: font.Shaped, a_id, b_id: font.Font_Id) -> bool {
	if len(a.glyphs) != len(b.glyphs) || len(a.clusters) != len(b.clusters) || a.width != b.width { return false }
	for g, i in a.glyphs {
		h := b.glyphs[i]
		if g.id != h.id || g.x != h.x || g.y != h.y || g.advance != h.advance || g.cluster != h.cluster || g.rtl != h.rtl { return false }
		if (g.face == a_id) != (h.face == b_id) { return false }
	}
	for c, i in a.clusters { if c != b.clusters[i] { return false } }
	return true
}

Run_Job :: struct {
	s:      ^font.State,
	glyphs: []font.Glyph_Pos,
	reqs:   []font.Glyph_Request,
	images: [LOCK_THREADS][]font.Glyph_Image,
	slugs:  [LOCK_THREADS][]font.Slug_Glyph,
	next:   int,
	start:  sync.Barrier,
}

// Threads that look up the same run on a new state at once (every glyph missing for all of them): each gets the bitmaps
// and Slug data one thread gets glyph by glyph afterwards (so each was made once), and a request of face 0 gets nothing.
@(test)
runs_from_threads_are_made_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	sh := font.shape(s, ui, LOCK_SIZE, LOCK_LINES[0] + " " + LOCK_LINES[3], {}, context.temp_allocator)
	testing.expect(t, len(sh.glyphs) > 0)
	job := Run_Job{s = s, glyphs = sh.glyphs}
	steps := s.settings.subpixel_steps
	job.reqs = make([]font.Glyph_Request, len(sh.glyphs) + 1, context.temp_allocator)
	for g, i in sh.glyphs { job.reqs[i] = {g.face, g.id, u8(i % steps)} }
	job.reqs[len(sh.glyphs)] = {0, sh.glyphs[0].id, 0}
	for k in 0 ..< LOCK_THREADS {
		job.images[k] = make([]font.Glyph_Image, len(job.reqs), context.temp_allocator)
		job.slugs[k] = make([]font.Slug_Glyph, len(job.glyphs), context.temp_allocator)
	}
	sync.barrier_init(&job.start, LOCK_THREADS)
	threads: [LOCK_THREADS]^thread.Thread
	for &th in threads {
		th = thread.create_and_start_with_data(&job, proc(data: rawptr) {
			j := (^Run_Job)(data)
			me := sync.atomic_add(&j.next, 1)
			sync.barrier_wait(&j.start)
			font.glyph_images(j.s, LOCK_SIZE, j.reqs, j.images[me])
			font.slug_glyphs(j.s, j.glyphs, 0, j.slugs[me])
		})
	}
	for th in threads { thread.join(th); thread.destroy(th) }
	drawn := 0
	for r, i in job.reqs {
		want := font.glyph_image(s, r.face, r.id, LOCK_SIZE, int(r.sub))
		if want.page >= 0 { drawn += 1 }
		for k in 0 ..< LOCK_THREADS { testing.expectf(t, job.images[k][i] == want, "thread %d, glyph %d: %v, one thread: %v", k, i, job.images[k][i], want) }
	}
	testing.expect(t, drawn > 0, "no glyph has a bitmap")
	testing.expect_value(t, job.images[0][len(job.reqs) - 1].page, -1)
	curves := 0
	for g, i in job.glyphs {
		want := font.slug_glyph(s, g.face, g.id)
		if want.kind == .Curves { curves += 1 }
		for k in 0 ..< LOCK_THREADS { testing.expectf(t, job.slugs[k][i] == want, "thread %d, glyph %d: Slug data differs", k, i) }
	}
	testing.expect(t, curves > 0, "no glyph has Slug data")
}) }
