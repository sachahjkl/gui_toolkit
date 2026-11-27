// The thumbnails' cache (ui.Thumb_Cache, src/md/features/thumbnails.md): only the cards built ask, the newest first, a
// few at a time; an ask whose card is no longer built is dropped; an answer makes the entry Ready, a failure Failed and
// not asked again; over the count, the least used go, never one built now; a clear drops what was made and keeps the
// asks out. The local work (file_thumbnail_make) reduces a real PNG without the system, turns a phone's photo as its EXIF
// orientation says and draws an SVG.
//   odin test tests/data_views -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import exif "gt:exif"
import image "gt:image"
import "gt:png"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Asked :: struct { path: string, ticket: u64, side: int }

@(private = "file")
Thumbs_App :: struct {
	c:           ui.Thumb_Cache,
	first, last: int,               // the cards built
	asked:       [dynamic]Asked,    // what the cache sent, in order (paths owned)
	ready:       int,               // the cards built whose entry is Ready (last build)
	clear:       bool,              // the next build clears the cache after its cards
	px:          f32,               // the cards' picture's side (0: the cache's)
}

@(private = "file")
thumbs_ask :: proc(user: rawptr, path: string, side: int, ticket: u64) {
	app := (^Thumbs_App)(user)
	append(&app.asked, Asked{strings.clone(path), ticket, side})
}

@(private = "file")
thumbs_build :: proc(s: ^session.Session) {
	app := (^Thumbs_App)(s.user)
	app.ready = 0
	for i in app.first ..< app.last {
		path := fmt.tprintf("/pictures/f%d.png", i)
		t := ui.thumb_cache_get(&app.c, ui.thumb_key(path, 100, 7), path, app.px)
		if t.state == .Ready {
			app.ready += 1
			ui.next({width = ui.px(64), height = ui.px(64)})
			ui.thumb_picture(fmt.tprintf("###thumb%d", i), t)
		}
	}
	if app.clear {
		ui.thumb_cache_clear(&app.c)
		app.clear = false
	}
	ui.thumb_cache_frame(&app.c, thumbs_ask, app)
}

@(private = "file")
thumbs_destroy :: proc(app: ^Thumbs_App) {
	ui.thumb_cache_destroy(&app.c)
	for a in app.asked { delete(a.path) }
	delete(app.asked)
}

@(private = "file")
answer_all :: proc(app: ^Thumbs_App, from: int) {
	px := [16]u8{}
	// (bounded: fewer asks than the test expects fail its expects, not a slice)
	for a in app.asked[min(from, len(app.asked)):] { ui.thumb_cache_answer(&app.c, a.ticket, px[:], 2, 2) }
}

// A card's size picks the side asked (the step at or above it); a card that grows asks again at the larger step while the
// smaller pixels stay shown; a larger ask that fails keeps them, and is not made again.
@(test)
a_card_that_grows_asks_a_larger_thumbnail :: proc(t: ^testing.T) {
	app := Thumbs_App{first = 0, last = 1, px = 200}
	ui.thumb_cache_init(&app.c, {asks = 2})
	defer thumbs_destroy(&app)
	testing.expect_value(t, ui.thumb_side_step(100), 128)
	testing.expect_value(t, ui.thumb_side_step(600), 1024)
	testing.expect_value(t, ui.thumb_side_step(5000), 1024)
	s := session.start(t, {build = thumbs_build, user = &app, no_renderer = true})
	session.frame(s)
	if !testing.expect_value(t, len(app.asked), 1) { return }
	testing.expect_value(t, app.asked[0].side, 256)
	small := [4 * 4]u8{}
	ui.thumb_cache_answer(&app.c, app.asked[0].ticket, small[:], 2, 2)
	session.frame(s)
	testing.expect_value(t, app.ready, 1)
	// (the card grows: the larger step is asked, the entry stays Ready meanwhile)
	app.px = 480
	session.frames(s, 2)
	if !testing.expect_value(t, len(app.asked), 2) { return }
	testing.expect_value(t, app.asked[1].side, 512)
	testing.expect_value(t, app.ready, 1)
	big := make([]u8, 8 * 8 * 4)
	defer delete(big)
	ui.thumb_cache_answer(&app.c, app.asked[1].ticket, big, 8, 8)
	path := "/pictures/f0.png"
	got := ui.thumb_cache_get(&app.c, ui.thumb_key(path, 100, 7), path, app.px)
	testing.expect_value(t, got.size, [2]int{8, 8})
	testing.expect_value(t, got.side, 512)
	// (larger still, and that ask fails: the 512 pixels stay, and it is not asked again)
	app.px = 900
	session.frames(s, 2)
	if !testing.expect_value(t, len(app.asked), 3) { return }
	ui.thumb_cache_failed(&app.c, app.asked[2].ticket)
	session.frames(s, 3)
	testing.expect_value(t, len(app.asked), 3)
	testing.expect_value(t, app.ready, 1)
}

// A place given in `next` without a size stays: the sides left unset fill the room, the place is not dropped.
@(test)
a_thumbnail_keeps_the_place_next_gives :: proc(t: ^testing.T) {
	Placed :: struct { thumb: ui.Thumb }
	app := Placed{thumb = {state = .Ready, size = {2, 2}, side = 128}}
	s := session.start(t, {size = {400, 300}, no_renderer = true, user = &app, build = proc(s: ^session.Session) {
		app := (^Placed)(s.user)
		ui.next({fixed_x = 30, fixed_y = 40})
		ui.thumb_picture("###placed", &app.thumb)
	}})
	session.frames(s, 2)
	b := session.get(s, "placed")
	testing.expect_value(t, b.rect.min, [2]f32{30, 40})
	testing.expect(t, b.rect.max.x > 30 && b.rect.max.y > 40, "the sides left unset take the room")
}

@(test)
the_cards_built_ask_the_newest_first_a_few_at_a_time :: proc(t: ^testing.T) {
	app := Thumbs_App{first = 0, last = 10}
	ui.thumb_cache_init(&app.c, {asks = 2})
	defer thumbs_destroy(&app)
	s := session.start(t, {build = thumbs_build, user = &app, no_renderer = true})
	session.frame(s)
	testing.expect_value(t, len(app.asked), 2)
	if len(app.asked) < 2 { return }
	// (the last cards built first: a stack)
	testing.expect_value(t, app.asked[0].path, "/pictures/f9.png")
	testing.expect_value(t, app.asked[1].path, "/pictures/f8.png")
	session.frame(s)
	testing.expect_value(t, len(app.asked), 2)   // (two out: no more)
	answer_all(&app, 0)
	session.frames(s, 2)
	testing.expect_value(t, app.ready, 2)
	testing.expect_value(t, len(app.asked), 4)
	// a failure: the card keeps its icon and does not ask again
	ui.thumb_cache_failed(&app.c, app.asked[2].ticket)
	got := ui.thumb_cache_get(&app.c, ui.thumb_key(app.asked[2].path, 100, 7), app.asked[2].path)
	testing.expect_value(t, got.state, ui.Thumb_State.Failed)
	// an answer of a ticket the cache does not know changes nothing
	px := [16]u8{}
	ui.thumb_cache_answer(&app.c, 9999, px[:], 2, 2)
	answer_all(&app, 3)
	session.frames(s, 8)
	answer_all(&app, 4)
	session.frames(s, 8)
	asked_total := len(app.asked)
	for k in 0 ..< asked_total { for m in k + 1 ..< asked_total { testing.expect(t, app.asked[k].path != app.asked[m].path, "each card asked once") } }
}

@(test)
an_ask_whose_card_is_gone_is_dropped :: proc(t: ^testing.T) {
	app := Thumbs_App{first = 0, last = 10}
	ui.thumb_cache_init(&app.c, {asks = 1})
	defer thumbs_destroy(&app)
	s := session.start(t, {build = thumbs_build, user = &app, no_renderer = true})
	session.frame(s)
	testing.expect_value(t, len(app.asked), 1)
	// scrolled: the cards 100 to 102 now; the first ask's answer frees the slot
	app.first, app.last = 100, 103
	session.frames(s, ui.THUMB_STALE_FRAMES + 2)
	answer_all(&app, 0)
	for _ in 0 ..< 6 {
		session.frame(s)
		answer_all(&app, len(app.asked) - 1)
	}
	testing.expect_value(t, len(app.asked), 4)
	for a in app.asked[1:] {
		testing.expectf(t, strings.has_prefix(a.path, "/pictures/f10"), "only the cards built now are asked: %s", a.path)
	}
	testing.expect(t, app.c.skipped > 0, "the cards scrolled past were dropped")
}

@(test)
over_the_count_the_least_used_go_never_one_shown :: proc(t: ^testing.T) {
	app := Thumbs_App{first = 0, last = 6}
	ui.thumb_cache_init(&app.c, {asks = 8, most_count = 8})
	defer thumbs_destroy(&app)
	s := session.start(t, {build = thumbs_build, user = &app, no_renderer = true})
	session.frame(s)
	answer_all(&app, 0)
	session.frames(s, 4)
	testing.expect_value(t, app.ready, 6)
	// six more cards: twelve entries, over eight; the six shown now stay
	app.first, app.last = 6, 12
	session.frame(s)
	answer_all(&app, 6)
	session.frames(s, 4)
	testing.expect(t, len(app.c.entries) <= 8, "the count kept")
	testing.expect_value(t, app.ready, 6)
	for i in 6 ..< 12 {
		key := ui.thumb_key(fmt.tprintf("/pictures/f%d.png", i), 100, 7)
		e, ok := app.c.entries[key]
		testing.expectf(t, ok && e.state == .Ready, "card %d shown: kept", i)
	}
}

@(test)
a_clear_drops_what_was_made_and_keeps_the_asks_out :: proc(t: ^testing.T) {
	app := Thumbs_App{first = 0, last = 2}
	ui.thumb_cache_init(&app.c, {asks = 2})
	defer thumbs_destroy(&app)
	s := session.start(t, {build = thumbs_build, user = &app, no_renderer = true})
	session.frame(s)
	testing.expect_value(t, len(app.asked), 2)
	if len(app.asked) < 2 { return }
	// f1 answered, f0 still out
	px := [16]u8{}
	ui.thumb_cache_answer(&app.c, app.asked[0].ticket, px[:], 2, 2)
	session.frame(s)
	testing.expect_value(t, app.ready, 1)
	// a clear between two builds: gone at the next build's first card
	ui.thumb_cache_clear(&app.c)
	session.frame(s)
	testing.expect_value(t, app.ready, 0)
	testing.expect_value(t, app.c.held, 0)
	f0 := ui.thumb_key("/pictures/f0.png", 100, 7)
	e, ok := app.c.entries[f0]
	testing.expect(t, ok && e.state == .Asked, "the ask out kept")
	// (f1 asked again; f0's ask still holds its slot: two out, not three)
	testing.expect_value(t, len(app.asked), 3)
	testing.expect_value(t, len(app.c.by_ticket), 2)
	if len(app.asked) < 3 { return }
	testing.expect_value(t, app.asked[2].path, "/pictures/f1.png")
	// the answer of the ask sent before the clear lands
	ui.thumb_cache_answer(&app.c, app.asked[1].ticket, px[:], 2, 2)
	session.frame(s)
	testing.expect_value(t, app.ready, 1)
	// a clear in a build, after its cards: the entry its draw reads stays for this frame, goes at the next build
	app.clear = true
	session.frame(s)
	e, ok = app.c.entries[f0]
	testing.expect(t, ok && e.state == .Ready, "kept for the draw of the build that cleared")
	session.frame(s)
	testing.expect_value(t, app.ready, 0)
	testing.expect_value(t, len(app.asked), 4)
	if len(app.asked) < 4 { return }
	testing.expect_value(t, app.asked[3].path, "/pictures/f0.png")
}

@(test)
a_png_makes_its_thumbnail_without_the_system :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "thumbnail")   // (freed by its cleanup)
	w, h := 40, 20
	pixels := make([]u8, w * h * 4)
	defer delete(pixels)
	for i in 0 ..< w * h { pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3] = 200, 10, 10, 255 }
	data := png.encode(pixels, w, h)
	defer delete(data)
	path := fmt.tprintf("%s/red.png", dir)
	testing.expect(t, os.write_entire_file(path, data) == nil)
	// larger than the side: reduced, its ratio kept, its colour kept (a box filter of one colour)
	small, ok := ui.file_thumbnail_make(path, 10, system = false)
	defer delete(small.rgba)
	testing.expect(t, ok, "a PNG is made without the system")
	testing.expect_value(t, small.width, 10)
	testing.expect_value(t, small.height, 5)
	testing.expect_value(t, small.picture, [2]int{w, h})   // (the picture's own size: an inspector shows it)
	testing.expect_value(t, len(small.rgba), 10 * 5 * 4)
	if len(small.rgba) >= 4 { testing.expectf(t, small.rgba[0] >= 198 && small.rgba[0] <= 202 && small.rgba[3] == 255, "the colour kept: %v", small.rgba[:4]) }
	// smaller than the side: as it is
	full, full_ok := ui.file_thumbnail_make(path, 256, system = false)
	defer delete(full.rgba)
	testing.expect(t, full_ok && full.width == w && full.height == h && full.picture == {w, h}, "a small picture as it is")
	// a file gt:image cannot read, the system not asked: none
	text := fmt.tprintf("%s/notes.txt", dir)
	testing.expect(t, os.write_entire_file(text, transmute([]u8)string("words")) == nil)
	_, text_ok := ui.file_thumbnail_make(text, 64, system = false)
	testing.expect(t, !text_ok, "another type without the system: none")
	testing.expect(t, ui.file_thumbnail_decodes("a.PNG") == ui.file_thumbnail_decodes("a.png"), "by the extension, its case aside")
	testing.expect(t, ui.file_thumbnail_decodes("photo.jpg") && !ui.file_thumbnail_decodes("notes.txt"))
}

// A phone's photo stored lying, its metadata saying to turn it a quarter: its thumbnail stands (classeur showed it
// sideways), and the picture's size is said turned. An SVG drawing gets a thumbnail drawn at the side asked.
@(test)
a_turned_photo_and_a_drawing_make_their_thumbnails :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "thumbnail_turned")
	// 64 x 32, its left half red and its right half blue, stored lying: shown, 32 wide and 64 tall, red on top
	stored := image.create(64, 32, {220, 0, 0, 255})
	defer image.destroy(&stored)
	image.fill_rect(stored, {32, 0, 32, 32}, {0, 0, 220, 255})
	jpeg := image.jpeg_encode(stored, 95)
	defer delete(jpeg)
	turned, result := exif.set_orientation(jpeg, 6)
	defer delete(turned)
	testing.expect_value(t, result, exif.Write_Result.Inserted)
	path := fmt.tprintf("%s/phone.jpg", dir)
	testing.expect(t, os.write_entire_file(path, turned) == nil)
	th, ok := ui.file_thumbnail_make(path, 16, system = false)
	defer delete(th.rgba)
	if testing.expect(t, ok, "a turned JPEG is made") {
		testing.expect_value(t, [2]int{th.width, th.height}, [2]int{8, 16})
		testing.expect_value(t, th.picture, [2]int{32, 64})
		top := th.rgba[(1 * th.width + 4) * 4:][:4]
		bottom := th.rgba[(14 * th.width + 4) * 4:][:4]
		testing.expectf(t, top[0] > 150 && top[2] < 100, "red on top: %v", top)
		testing.expectf(t, bottom[2] > 150 && bottom[0] < 100, "blue below: %v", bottom)
	}

	drawing := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"><rect width="20" height="20" fill="#00ff00"/></svg>`
	svg_path := fmt.tprintf("%s/logo.svg", dir)
	testing.expect(t, os.write_entire_file(svg_path, transmute([]u8)drawing) == nil)
	testing.expect(t, ui.file_thumbnail_decodes("logo.SVG"))
	d, d_ok := ui.file_thumbnail_make(svg_path, 64, system = false)
	defer delete(d.rgba)
	if testing.expect(t, d_ok, "an SVG is drawn") {
		testing.expect_value(t, [2]int{d.width, d.height}, [2]int{64, 32})
		testing.expect_value(t, d.picture, [2]int{40, 20})
		left := d.rgba[(16 * 64 + 16) * 4:][:4]
		right := d.rgba[(16 * 64 + 48) * 4:][:4]
		testing.expect_value(t, [4]u8{left[0], left[1], left[2], left[3]}, [4]u8{0, 255, 0, 255})
		testing.expect_value(t, right[3], 0)
	}
}
