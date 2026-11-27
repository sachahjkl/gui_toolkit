// gt:pictures: the size classes, a picture decoded on the chores and made a texture at the next build, two places of
// nearly one size on one texture, the budget that drops the least recent and never what is shown, a broken file Failed.
//   odin test tests/pictures -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package pictures_test

import "base:runtime"
import "core:encoding/base64"
import "core:sync"
import "core:testing"
import "core:time"
import image "gt:image"
import pictures "gt:pictures"
import png "gt:png"
import "gt:draw"
import "gt:render"
import "gt:tasks"
import "gt:testkit/session"
import "gt:ui"

// A PNG file of one colour, w x h.
@(private = "file")
png_file :: proc(w, h: int) -> []u8 {
	img := image.create(w, h, image.Color{40, 120, 200, 255}, context.temp_allocator)
	return png.encode(img.pixels, w, h, allocator = context.temp_allocator)
}

@(private = "file")
settled :: proc(s: ^session.Session, p: ^pictures.Picture) -> bool { return p.state != .Pending }

@(private = "file")
wait_settled :: proc(s: ^session.Session, p: ^pictures.Picture, loc := #caller_location) {
	session.wait_until(s, p, settled, "the picture's decode", loc = loc)
}

@(test)
places_ask_in_classes :: proc(t: ^testing.T) {
	testing.expect_value(t, pictures.class_side(1, 2048), 32)
	testing.expect_value(t, pictures.class_side(32, 2048), 32)
	testing.expect_value(t, pictures.class_side(33, 2048), 64)
	testing.expect_value(t, pictures.class_side(200.5, 2048), 256)
	testing.expect_value(t, pictures.class_side(257, 2048), 512)
	testing.expect_value(t, pictures.class_side(700, 2048), 768)
	testing.expect_value(t, pictures.class_side(5000, 2048), 2048)
	testing.expect_value(t, pictures.class_side(0, 2048), 2048)
	testing.expect_value(t, pictures.class_side(100, 64), 64)
}

@(test)
a_picture_asked_becomes_a_texture_at_its_class :: proc(t: ^testing.T) {
	s := session.start(t, {})
	c: pictures.Cache
	pictures.cache_init(&c, s.renderer, s.state)
	defer pictures.cache_destroy(&c)
	p := pictures.get(&c, 1, png_file(600, 300), 100)
	testing.expect(t, p != nil && p.state == .Pending)
	wait_settled(s, p)
	testing.expect_value(t, p.state, pictures.Picture_State.Ready)
	testing.expect(t, p.texture != 0)
	testing.expect_value(t, p.size, [2]int{128, 64})
	testing.expect_value(t, pictures.held_bytes(&c), 128 * 64 * 4)
}

@(test)
places_of_nearly_one_size_share_a_texture :: proc(t: ^testing.T) {
	s := session.start(t, {})
	c: pictures.Cache
	pictures.cache_init(&c, s.renderer, s.state)
	defer pictures.cache_destroy(&c)
	file := png_file(400, 400)
	a := pictures.get(&c, 7, file, 100)
	b := pictures.get(&c, 7, file, 120)
	testing.expect(t, a == b, "100 and 120 pixels are one class")
	wait_settled(s, a)
	testing.expect(t, pictures.get(&c, 7, nil, 110) == a, "known: no bytes needed")
	large := pictures.get(&c, 7, file, 300)
	testing.expect(t, large != a, "300 pixels is another class")
	whole := pictures.get(&c, 7, file, 0)
	testing.expect(t, whole != a && whole != large, "the whole picture is a class of its own")
	pictures.forget(&c, 7)
	testing.expect(t, pictures.get(&c, 7, nil, 100) == nil, "forget drops every class")
}

@(test)
the_budget_drops_the_least_recent_and_never_what_is_shown :: proc(t: ^testing.T) {
	s := session.start(t, {})
	c: pictures.Cache
	// (64 x 64 is 16 KiB: two of them pass the budget)
	pictures.cache_init(&c, s.renderer, s.state, {budget_bytes = 20_000, keep_frames = 2})
	defer pictures.cache_destroy(&c)
	file := png_file(64, 64)
	pictures.frame(&c)
	a := pictures.get(&c, 1, file, 64)
	b := pictures.get(&c, 2, file, 64)
	wait_settled(s, a)
	wait_settled(s, b)
	testing.expect_value(t, pictures.held_bytes(&c), 2 * 64 * 64 * 4)
	// both shown: both stay, over the budget
	pictures.frame(&c)
	testing.expect(t, pictures.get(&c, 1, nil, 64) != nil)
	testing.expect(t, pictures.get(&c, 2, nil, 64) != nil)
	// only b shown from now: a stays for keep_frames frames, then goes
	for _ in 0 ..< 2 {
		pictures.frame(&c)
		testing.expect_value(t, pictures.held_bytes(&c), 2 * 64 * 64 * 4)
		_ = pictures.get(&c, 2, nil, 64)
	}
	pictures.frame(&c)
	testing.expect(t, pictures.get(&c, 1, nil, 64) == nil, "a, the least recent, is dropped")
	testing.expect(t, pictures.get(&c, 2, nil, 64) != nil, "b stays")
	testing.expect_value(t, pictures.held_bytes(&c), 64 * 64 * 4)
}

@(test)
a_broken_file_is_failed_with_why :: proc(t: ^testing.T) {
	s := session.start(t, {})
	c: pictures.Cache
	pictures.cache_init(&c, s.renderer, s.state)
	defer pictures.cache_destroy(&c)
	text := pictures.get(&c, 1, transmute([]u8)string("no picture here"), 64)
	file := png_file(64, 64)
	cut := pictures.get(&c, 2, file[:len(file) / 2], 64)
	wait_settled(s, text)
	wait_settled(s, cut)
	testing.expect_value(t, text.state, pictures.Picture_State.Failed)
	testing.expect_value(t, text.why, pictures.Failure.Unknown_Format)
	testing.expect_value(t, cut.state, pictures.Picture_State.Failed)
	testing.expect_value(t, cut.why, pictures.Failure.Damaged)
	testing.expect(t, pictures.failure_words(cut.why) != "")
	testing.expect_value(t, pictures.held_bytes(&c), 0)
}

// The thread `prepare` ran on (0: not run).
@(private = "file")
prepared_on: int

@(private = "file")
from_base64 :: proc(data: []u8, allocator: runtime.Allocator) -> ([]u8, bool) {
	sync.atomic_store(&prepared_on, sync.current_thread_id())
	file, err := base64.decode(string(data), allocator = allocator)
	return file, err == nil && len(file) > 0
}

@(private = "file")
refuse :: proc(data: []u8, allocator: runtime.Allocator) -> ([]u8, bool) { return nil, false }

// A picture held as text: prepare makes its file on the chores, never on the interface's thread; a refusal fails it.
@(test)
prepare_makes_the_file_on_the_chores :: proc(t: ^testing.T) {
	s := session.start(t, {})
	c: pictures.Cache
	pictures.cache_init(&c, s.renderer, s.state)
	defer pictures.cache_destroy(&c)
	text, _ := base64.encode(png_file(64, 32), allocator = context.temp_allocator)
	p := pictures.get(&c, 1, transmute([]u8)text, 64, from_base64)
	no := pictures.get(&c, 2, transmute([]u8)text, 64, refuse)
	wait_settled(s, p)
	wait_settled(s, no)
	testing.expect_value(t, p.state, pictures.Picture_State.Ready)
	testing.expect_value(t, p.size, [2]int{64, 32})
	on := sync.atomic_load(&prepared_on)
	testing.expect(t, on != 0 && on != sync.current_thread_id(), "prepared on a thread of the chores")
	testing.expect_value(t, no.state, pictures.Picture_State.Failed)
	testing.expect_value(t, no.why, pictures.Failure.Unknown_Format)
}

// A large picture (whole, 1600 x 1200: 7.3 MiB, its mips a third more) is uploaded over several frames when the cache's
// threshold is under it: Pending through them, then Ready and drawn whole, every band in its place.
@(test)
a_large_picture_is_uploaded_over_several_frames :: proc(t: ^testing.T) {
	Staged :: struct { c: pictures.Cache, ready: bool, p: ^pictures.Picture, frames: int, file: []u8 }
	st := new(Staged)
	defer free(st)
	w, h := 1600, 1200
	img := image.create(w, h, image.Color{200, 30, 30, 255}, context.temp_allocator)
	image.fill_rect(img, {0, h / 2, w, h / 2}, image.Color{30, 30, 200, 255})   // (its lower half blue: the last bands)
	st.file = png.encode(img.pixels, w, h, allocator = context.temp_allocator)
	build :: proc(s: ^session.Session) {
		st := (^Staged)(s.user)
		if !st.ready { return }   // (the session's first frames come before the cache, which needs its renderer)
		pictures.frame(&st.c)
		st.p = pictures.get(&st.c, 9, st.file, 0)
		if st.p != nil && st.p.state == .Pending && st.p.texture != 0 { st.frames += 1 }
		ui.next({width = ui.px(160), height = ui.px(120)})
		ui.custom("###picture", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			p := (^Staged)(user).p
			if p != nil && p.state == .Ready { draw.image(dc, p.texture, b.rect) }
		}, st)
	}
	s := session.start(t, {build = build, user = st, size = {320, 240}})
	// (a band a step: 1600 * 4 bytes a row, 163 rows a band, 8 bands; a budget of nothing writes one a frame)
	pictures.cache_init(&st.c, s.renderer, s.state, {staged_from_bytes = 1 << 20, upload_budget = 1})
	defer pictures.cache_destroy(&st.c)
	st.ready = true
	session.frame(s)
	session.wait_until(s, st, proc(s: ^session.Session, st: ^Staged) -> bool { return st.p != nil && st.p.state != .Pending }, "the staged upload")
	testing.expectf(t, st.p.state == .Ready, "ready: %v %v", st.p.state, st.p.why)
	// (8 bands, one a frame: the first written when the decode answers, the last at the build that makes it Ready)
	testing.expectf(t, st.frames >= 4, "uploaded over %d frames", st.frames)
	testing.expect_value(t, st.p.size, [2]int{w, h})
	testing.expect_value(t, pictures.held_bytes(&st.c), w * h * 4 + w * h * 4 / 3)
	session.frame(s)
	shot := session.capture(s)
	b := session.get(s, "picture")
	top := session.pixel(shot, int(b.rect.min.x) + 80, int(b.rect.min.y) + 20)
	bottom := session.pixel(shot, int(b.rect.min.x) + 80, int(b.rect.min.y) + 100)
	testing.expectf(t, session.near(top, {200, 30, 30, 255}, 6), "red on top: %v", top)
	testing.expectf(t, session.near(bottom, {30, 30, 200, 255}, 6), "blue below: %v", bottom)
}

// Two large pictures whose decodes answer at the same build share that frame's budget: a budget of nothing writes one
// band in all, not one per answer and one more. A device recovered while they upload (its textures back empty) starts
// the bands written again from the top; both end Ready.
@(test)
large_answers_of_one_build_share_its_upload_budget :: proc(t: ^testing.T) {
	Two :: struct { c: pictures.Cache, ready: bool, p: [2]^pictures.Picture, file: []u8 }
	st := new(Two)
	defer free(st)
	w, h := 1600, 1200
	img := image.create(w, h, image.Color{200, 30, 30, 255}, context.temp_allocator)
	st.file = png.encode(img.pixels, w, h, allocator = context.temp_allocator)
	build :: proc(s: ^session.Session) {
		st := (^Two)(s.user)
		if !st.ready { return }   // (the session's first frames come before the cache, which needs its renderer)
		pictures.frame(&st.c)
		st.p[0] = pictures.get(&st.c, 1, st.file, 0)
		st.p[1] = pictures.get(&st.c, 2, st.file, 0)
	}
	s := session.start(t, {build = build, user = st, size = {320, 240}})
	pictures.cache_init(&st.c, s.renderer, s.state, {staged_from_bytes = 1 << 20, upload_budget = 1})
	defer pictures.cache_destroy(&st.c)
	st.ready = true
	session.frame(s)   // (both asked)
	// (both decodes answer before the next build: the chores at rest, their answers posted)
	testing.expect(t, tasks.wait_rest(ui.chores(), 10 * time.Second), "the decodes end")
	session.frame(s)
	band := render.UPLOAD_BAND_BYTES / (w * 4)
	testing.expect(t, st.p[0].state == .Pending && st.p[1].state == .Pending, "both upload in steps")
	rows := st.p[0].upload.row + st.p[1].upload.row
	testing.expectf(t, rows == band, "one band at that build for both: %d rows (a band %d)", rows, band)

	// (the decodes answer in either order: the one that answered first uploads first)
	lead := st.p[0].upload.row > 0 ? st.p[0] : st.p[1]
	session.frame(s)
	testing.expect_value(t, lead.upload.row, 2 * band)
	s.renderer.device_generation += 1   // (as a recovered device: its textures came back empty)
	session.frame(s)
	testing.expectf(t, lead.upload.row == band, "again from the top: %d rows", lead.upload.row)

	session.wait_until(s, st, proc(s: ^session.Session, st: ^Two) -> bool { return st.p[0].state != .Pending && st.p[1].state != .Pending }, "both uploads")
	testing.expect(t, st.p[0].state == .Ready && st.p[1].state == .Ready)
	testing.expect_value(t, pictures.held_bytes(&st.c), 2 * (w * h * 4 + w * h * 4 / 3))
}
