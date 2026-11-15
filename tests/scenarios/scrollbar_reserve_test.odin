package scenarios_test

// The room of a scroll bar (src/md/features/scroll-bar.md, "The bar's room"): by default kept only while the content
// overflows; with .Scrollbar_Reserve kept while it fits too, so a content that grows past the view does not narrow then;
// none with the overlay option, reserved or not.

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") RESERVE_VIEW :: [2]f32{300, 200}
@(private = "file") RESERVE_ROW_H :: 30
@(private = "file") RESERVE_FEW :: 3
@(private = "file") RESERVE_MANY :: 50

@(private = "file")
Reserve_Run :: struct { rows: int, reserve: bool }

// Rows with a button at their right end: where the content area ends.
@(private = "file")
reserve_build :: proc(s: ^session.Session) {
	r := (^Reserve_Run)(s.user)
	flags := r.reserve ? ui.Box_Flags{.Scrollbar_Reserve} : ui.Box_Flags{}
	ui.next({width = ui.px(RESERVE_VIEW.x), height = ui.px(RESERVE_VIEW.y), flags = flags})
	if ui.scroll_y("###view") {
		for i in 0 ..< r.rows {
			ui.next({width = ui.fill(), height = ui.px(RESERVE_ROW_H), axis = .X})
			if ui.row(id = fmt.tprintf("###row%d", i)) {
				ui.spacer(ui.fill())
				ui.next({width = ui.px(60), height = ui.pct(1)})
				_ = ui.button(fmt.tprintf("Open###open%d", i))
			}
		}
	}
}

// By default: no room while it fits (the button at the view's edge), the room once it overflows.
@(test)
the_room_is_kept_only_while_the_content_overflows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Reserve_Run{rows = RESERVE_FEW}
	s := session.start(t, {build = reserve_build, user = &r, no_renderer = true})
	session.wait_idle(s)
	view := session.get(s, "view")
	testing.expect_value(t, ui.scrollbar_room(view, .X), 0)
	testing.expect_value(t, session.get(s, "open0").rect.max.x, view.rect.max.x)
	r.rows = RESERVE_MANY
	session.wait_idle(s)
	view = session.get(s, "view")
	testing.expect(t, ui.scrollbar_room(view, .X) > 0, "it overflows: the room")
	track, _, ok := ui.scrollbar_rects(view)
	if !testing.expect(t, ok, "a bar") { return }
	testing.expect_value(t, session.get(s, "open0").rect.max.x, track.min.x)
}) }

// Reserved: the room while it fits, no bar in it; the content that grows past the view does not move; the overlay option
// keeps none.
@(test)
a_reserved_room_stays_while_the_content_fits :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Reserve_Run{rows = RESERVE_FEW, reserve = true}
	s := session.start(t, {build = reserve_build, user = &r, no_renderer = true})
	session.wait_idle(s)
	view := session.get(s, "view")
	room := ui.scrollbar_room(view, .X)
	testing.expect(t, room > 0, "the room while it fits")
	testing.expect_value(t, ui.scrollbar_room(view, .Y), 0)   // (it does not scroll sideways: no horizontal room)
	_, _, ok := ui.scrollbar_rects(view)
	testing.expect(t, !ok, "no bar: the content fits")
	edge := session.get(s, "open0").rect.max.x
	testing.expect_value(t, edge, view.rect.max.x - room)
	// it grows past the view: the bar comes in its room, nothing moves
	r.rows = RESERVE_MANY
	session.frames(s, 1)
	view = session.get(s, "view")
	testing.expect_value(t, ui.scrollbar_room(view, .X), room)
	testing.expect_value(t, session.get(s, "open0").rect.max.x, edge)
	_, _, ok = ui.scrollbar_rects(view)
	testing.expect(t, ok, "the bar shows")
	// and back: the room stays, frame after frame
	r.rows = RESERVE_FEW
	for _ in 0 ..< 4 {
		session.frames(s, 1)
		testing.expect_value(t, ui.scrollbar_room(session.get(s, "view"), .X), room)
	}
	// the overlay option: no room, reserved or not
	ui.set_scrollbar_overlay(s.state, true)
	session.frames(s, 2)
	view = session.get(s, "view")
	testing.expect_value(t, ui.scrollbar_room(view, .X), 0)
	testing.expect_value(t, session.get(s, "open0").rect.max.x, view.rect.max.x)
	ui.set_scrollbar_overlay(s.state, false)
}) }

@(private = "file")
Text_Run :: struct { edit: ui.Text_Edit }

// A text area keeps its room too when reserved: its text never runs under where the bar comes.
@(test)
a_reserved_text_area_keeps_its_room :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Text_Run
	defer ui.text_edit_destroy(&r.edit)
	s := session.start(t, {user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Text_Run)(s.user)
		ui.next({width = ui.px(RESERVE_VIEW.x), height = ui.px(RESERVE_VIEW.y), flags = {.Scrollbar_Reserve}})
		_ = ui.text_edit("###area", &r.edit)
	}})
	session.wait_idle(s)
	testing.expect(t, r.edit.bar_room.x > 0, "the vertical bar's room while the text fits")
}) }
