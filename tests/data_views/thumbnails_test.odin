// The thumbnails' cache (ui.Thumb_Cache, src/md/features/thumbnails.md): only the cards built ask, the newest first, a
// few at a time; an ask whose card is no longer built is dropped; an answer makes the entry Ready, a failure Failed and
// not asked again; over the count, the least used go, never one built now.
//   odin test tests/data_views -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Asked :: struct { path: string, ticket: u64 }

@(private = "file")
Thumbs_App :: struct {
	c:           ui.Thumb_Cache,
	first, last: int,               // the cards built
	asked:       [dynamic]Asked,    // what the cache sent, in order (paths owned)
	ready:       int,               // the cards built whose entry is Ready (last build)
}

@(private = "file")
thumbs_ask :: proc(user: rawptr, path: string, side: int, ticket: u64) {
	app := (^Thumbs_App)(user)
	append(&app.asked, Asked{strings.clone(path), ticket})
}

@(private = "file")
thumbs_build :: proc(s: ^session.Session) {
	app := (^Thumbs_App)(s.user)
	app.ready = 0
	for i in app.first ..< app.last {
		path := fmt.tprintf("/pictures/f%d.png", i)
		t := ui.thumb_cache_get(&app.c, ui.thumb_key(path, 100, 7), path)
		if t.state == .Ready {
			app.ready += 1
			ui.next({width = ui.px(64), height = ui.px(64)})
			ui.thumb_picture(fmt.tprintf("###thumb%d", i), t)
		}
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
