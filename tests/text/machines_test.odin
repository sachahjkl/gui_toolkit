package text_test

import "core:testing"
import "../../src/testkit/unwatched"
import "../../src/draw"
import "../../src/font"
import "../../src/render"

// What lasts in the font package says what state it is in: a slot, a page, a sequence of the fallback.

@(private = "file") SMALL_PAGE :: 256
@(private = "file") SMALL_FRAME :: [2]int{64, 64}
@(private = "file") FRAMES :: 30
// Text big enough that a frame or two fill a page of SMALL_PAGE.
@(private = "file") BIG_GLYPH_PX :: 60
// Pages a context that draws can need when nothing else holds them: the limit, and what one frame may add to it.
@(private = "file") PAGES_OF_A_BUSY_CONTEXT :: 4

// The id of a font just unloaded reaches nothing: what is asked with it before the next font takes the slot leaves that
// font nothing.
@(test)
an_unloaded_id_leaves_nothing_in_its_slot :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	a, ok := font.load_embedded(s, font.FALLBACK_UI_DATA)
	testing.expect(t, ok)
	gid := font.shape(s, a, 20, "H", {}, context.temp_allocator).glyphs[0].id
	font.unload(s, a)
	testing.expect(t, font.glyph_image(s, a, gid, 20, 0).page < 0)
	reqs := []font.Glyph_Request{{face = a, id = gid}}
	out: [1]font.Glyph_Image
	font.glyph_images(s, 20, reqs, out[:])
	testing.expect(t, out[0].page < 0)
	font.unload(s, a)   // (twice: the slot is not given away twice)
	b, ok_b := font.load_embedded(s, font.FALLBACK_UI_DATA)
	c, ok_c := font.load_embedded(s, font.FALLBACK_MONO_DATA)
	testing.expect(t, ok_b && ok_c && b != a && c != a && b != c)
	testing.expect(t, font.glyph_image(s, b, gid, 20, 0).page >= 0, "the slot's next font has its glyph")
}) }

// The id of a cascade is no face: asking a glyph of it leaves nothing for the face that takes its slot.
@(test)
a_cascade_id_leaves_nothing_in_its_slot :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	base, ok := font.load_embedded(s, font.FALLBACK_MONO_DATA)
	testing.expect(t, ok)
	id := font.cascade(s, {{font = base}}, nil, true)
	gid := font.shape(s, base, 20, "H", {}, context.temp_allocator).glyphs[0].id
	testing.expect(t, font.glyph_image(s, id, gid, 20, 0).page < 0)
	font.unload(s, id)
	b, ok_b := font.load_embedded(s, font.FALLBACK_UI_DATA)
	testing.expect(t, ok_b)
	testing.expect(t, font.glyph_image(s, b, gid, 20, 0).page >= 0, "the slot's next font has its glyph")
}) }

// A context that stopped drawing holds no page: the pages of the one that goes on drawing are reused, not added to.
@(test)
an_idle_context_holds_no_atlas_page :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := new(render.Renderer)
	defer free(r)
	if !render.init_offscreen(r, SMALL_FRAME, warp = true) { testing.fail_now(t, "no offscreen renderer") }
	defer render.destroy(r)
	st := font.DEFAULT_SETTINGS
	st.page_size = SMALL_PAGE
	st.max_gray_pages = 2
	s := setup(t, st)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	idle, busy: draw.Context
	draw.init(&idle, r, s)
	defer draw.destroy(&idle)
	draw.init(&busy, r, s)
	defer draw.destroy(&busy)
	size := [2]f32{f32(SMALL_FRAME.x), f32(SMALL_FRAME.y)}
	draw.begin_frame(&idle, size)
	render.frame_begin(r, {1, 1, 1, 1})
	draw.end_frame(&idle)
	render.frame_end(r)
	for i in 0 ..< FRAMES {
		draw.begin_frame(&busy, size)
		render.frame_begin(r, {1, 1, 1, 1})
		draw.text(&busy, ui, f32(BIG_GLYPH_PX + i), {0, 40}, {0, 0, 0, 1}, "The quick brown fox")
		draw.end_frame(&busy)
		render.frame_end(r)
		free_all(context.temp_allocator)
	}
	testing.expect(t, font.atlas_evictions(s) > 0, "no page was reused")
	testing.expectf(t, font.atlas_page_count(s) <= PAGES_OF_A_BUSY_CONTEXT, "%d pages", font.atlas_page_count(s))
}) }

@(private = "file")
Upload_Seen :: struct { rows: [8]int }

// A page reused comes up whole for a context that had it: what was there before is gone from its texture too, between the
// new bitmaps as well (a stretched glyph samples the texels around it).
@(test)
a_reused_page_uploads_whole :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	st := font.DEFAULT_SETTINGS
	st.page_size = SMALL_PAGE
	st.max_gray_pages = 1
	s := setup(t, st)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	gid := font.shape(s, ui, 20, "W", {}, context.temp_allocator).glyphs[0].id
	user := rawptr(uintptr(1))
	size := f32(BIG_GLYPH_PX)
	font.atlas_begin_frame(s, user)
	for font.atlas_page_count(s) < 2 {
		_ = font.glyph_image(s, ui, gid, size, 0)
		size += 1
	}
	note :: proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		seen := (^Upload_Seen)(user)
		seen.rows[page] = max(seen.rows[page], h)
	}
	seen: Upload_Seen
	versions: [2]u64
	for i in 0 ..< 2 { versions[i] = font.atlas_sync_page(s, i, 0, &seen, note) }
	font.atlas_begin_frame(s, user)
	for font.atlas_evictions(s) == 0 {
		_ = font.glyph_image(s, ui, gid, size, 0)
		size += 1
	}
	seen = {}
	for i in 0 ..< 2 { _ = font.atlas_sync_page(s, i, versions[i], &seen, note) }
	testing.expectf(t, max(seen.rows[0], seen.rows[1]) == SMALL_PAGE, "rows uploaded: %v", seen.rows[:2])
}) }

// A fallback that takes a sequence character by character (as fontconfig does) does not cut it: the joiner stays with the emoji
// around it. What is asked for is the font of each character that has one, nothing for the joiner.
@(test)
a_sequence_of_the_fallback_stays_in_one_face :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	emoji := sys(t, s, "Segoe UI Emoji")
	per_char := font.System_Fonts{name = "per character", fallback = proc(s: ^font.State, first: font.Font_Id, w: []u16, a, b: int, faces: []font.Font_Id) {
		id, _ := font.load_system(s, "Segoe UI Emoji")
		for i in a ..< b { if w[i] >= 0xD800 && w[i] < 0xE000 { faces[i] = id } }
	}}
	system := s.system_fonts
	s.system_fonts = &per_char
	defer s.system_fonts = system
	sh := font.shape(s, ui, 20, "\U0001F469‍\U0001F4BB", {}, context.temp_allocator)
	testing.expect(t, len(sh.glyphs) > 0)
	for g in sh.glyphs { testing.expect_value(t, g.face, emoji) }
}) }

// A state never started answers: no outline, no hinted size.
@(test)
a_state_never_started_has_no_outlines :: proc(t: ^testing.T) {
	s := new(font.State)
	defer free(s)
	o: font.Outline
	testing.expect(t, !font.glyph_outline(s, 1, 1, 1.0 / 4096, &o))
	out: [1]font.Slug_Glyph
	font.slug_glyphs(s, {{face = 0}}, 12, out[:])
	testing.expect_value(t, out[0].kind, font.Slug_Kind.Atlas)
}

// The emoji font unloaded by whoever held its id comes back on the next emoji.
@(test)
the_emoji_font_comes_back_when_unloaded :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	font.set_emoji_source(s, data = font.FALLBACK_UI_DATA)
	id := font.emoji_face(s)
	testing.expect(t, id != 0)
	font.unload(s, id)
	again := font.emoji_face(s)
	testing.expect(t, again != id && font.valid(s, again))
}) }

// The cache cleared while a word is being shaped: what comes out of the old settings is not kept.
@(test)
a_word_shaped_across_a_clear_is_shaped_again :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s := setup(t)
	defer teardown(s)
	ui := sys(t, s, "Segoe UI")
	@(static) calls: int
	calls = 0
	clearing := font.System_Fonts{name = "clears the words", fallback = proc(s: ^font.State, first: font.Font_Id, w: []u16, a, b: int, faces: []font.Font_Id) {
		calls += 1
		if calls == 1 { font.clear_word_cache(s) }
	}}
	system := s.system_fonts
	s.system_fonts = &clearing
	defer s.system_fonts = system
	_ = font.text_width(s, ui, 20, "\U00010FFF")
	testing.expect_value(t, calls, 2)
	_ = font.text_width(s, ui, 20, "\U00010FFF")
	testing.expect_value(t, calls, 2)
}) }