// The ends of a rectangle's gesture, and what must not change: the empty part of a row in a table with no rubber band, a
// press that loses its window, its row or its view, the rectangle under a scroll that moves and at another dpi, and the
// cost of a long list.
package data_views_test

import "core:fmt"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
BG_COLUMNS := [?]ui.Table_Column{{title = "Name", width = 0}, {title = "Size", width = 10, number = true}}

@(private = "file")
BG_App :: struct {
	t:      ui.Table,
	d:      ui.Table_Data,
	hidden: bool,
}

@(private = "file")
bg_fill :: proc(app: ^BG_App, ids: []u64) {
	ui.table_data_reset(&app.d, len(BG_COLUMNS))
	for id in ids {
		name := fmt.tprintf("doc%d", id)
		ui.table_data_row(&app.d, id, name)
		ui.table_data_cell(&app.d, name)
		ui.table_data_cell(&app.d, fmt.tprintf("%d B", id), f64(id))
	}
	ui.table_apply(&app.t, &app.d, app.t.query)
}

@(private = "file")
bg_start :: proc(t: ^testing.T, app: ^BG_App, n: int, zoom := 0, band := true, filter := "") -> ^session.Session {
	ui.table_init(&app.t, BG_COLUMNS[:])
	app.t.sort = ui.TABLE_UNSORTED
	app.t.zoom, app.t.vl.multi, app.t.rubber_band = zoom, true, band
	ids := make([]u64, n, context.temp_allocator)
	for &id, i in ids { id = u64(i + 1) }
	bg_fill(app, ids)
	s := session.start(t, {size = {620, 400}, user = app, no_renderer = true, build = proc(s: ^session.Session) {
		app := (^BG_App)(s.user)
		ui.next({width = ui.px(100), height = ui.px(30)})
		_ = ui.build_box({.Clickable}, "###other")
		if app.hidden { return }
		ui.next({width = ui.fill(), height = ui.fill()})
		_ = ui.table_build("###table", &app.t, &app.d, "Empty")
	}})
	session.frames(s, 3)
	if filter != "" {
		ui.use(s.state)
		ui.table_apply(&app.t, &app.d, filter)
		session.frames(s, 3)
	}
	return s
}

@(private = "file")
bg_destroy :: proc(app: ^BG_App) {
	ui.table_destroy(&app.t)
	ui.table_data_destroy(&app.d)
}

// The empty part of row `i`: after its name's text, in the first column.
@(private = "file")
bg_empty :: proc(s: ^session.Session, i: int) -> [2]f32 {
	r := session.get(s, fmt.tprintf("lrow_%d", i)).rect
	c := session.get(s, "c0", within = session.get(s, fmt.tprintf("lrow_%d", i)))
	return {c.rect.max.x - 20, (r.min.y + r.max.y) * 0.5}
}

// No rubber band: the press itself selects, on the empty part as on the text, and the list has no room after its rows.
@(test)
a_multi_table_without_a_band_selects_on_the_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for zoom in 0 ..= 1 {
		app: BG_App
		defer bg_destroy(&app)
		s := bg_start(t, &app, 60, zoom, band = false)
		at := bg_empty(s, 2)
		session.press(s, at)
		testing.expect_value(t, app.t.vl.sel, 2)
		testing.expect_value(t, len(ui.list_selected_ids(&app.t.vl)), 1)
		session.move(s, bg_empty(s, 5))
		testing.expect(t, !app.t.band.active && !app.t.band.pending, "no band")
		testing.expect_value(t, len(ui.list_selected_ids(&app.t.vl)), 1)
		session.release(s, bg_empty(s, 5))
		testing.expect_value(t, app.t.vl.end_space, 0)
		list := session.get(s, "rows")
		testing.expect(t, abs(list.view_bounds.y - ui.vlist_total(&app.t.vl)) <= 1, "the content ends at the last row")
	}
}) }

// A program's list (not a table) with several selected: a press anywhere on a row selects, as before.
@(test)
a_plain_list_selects_on_the_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	App :: struct { l: ui.List_State }
	app := App{l = {sel = -1, multi = true}}
	defer ui.list_state_destroy(&app.l)
	s := session.start(t, {size = {300, 300}, user = &app, no_renderer = true, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.list("###list", &app.l) {
			for i in 0 ..< 5 {
				r := ui.list_row(&app.l, i, "row")
				if ui.parent(r.box) { ui.label(fmt.tprintf("r%d", i)) }
			}
		}
	}})
	session.frames(s, 3)
	r := session.get(s, "lrow_3").rect
	session.press(s, {r.max.x - 20, (r.min.y + r.max.y) * 0.5})
	testing.expect_value(t, app.l.sel, 3)
	session.release(s, {r.max.x - 20, (r.min.y + r.max.y) * 0.5})
}) }

// The rows change under a press on an empty part: the click selects the item pressed, where it is now; an item that went
// is not replaced by the one in its place.
@(test)
a_pending_press_follows_its_item :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BG_App
	defer bg_destroy(&app)
	s := bg_start(t, &app, 6)
	at := bg_empty(s, 2)   // (item 3)
	session.press(s, at)
	testing.expect(t, app.t.band.pending, "pending")
	bg_fill(&app, {9, 1, 2, 3, 4, 5})
	session.frames(s, 2)
	session.release(s, at)
	ids := ui.list_selected_ids(&app.t.vl)
	testing.expectf(t, len(ids) == 1 && ids[0] == 3, "item 3: %v", ids)
	session.advance(s, session.SEPARATE_CLICK_MS)
	session.press(s, at)   // (item 2)
	bg_fill(&app, {9, 1, 5, 4, 3})
	session.frames(s, 2)
	session.release(s, at)
	ids = ui.list_selected_ids(&app.t.vl)
	testing.expectf(t, len(ids) == 1 && ids[0] == 3, "item 2 went: the selection stays %v", ids)
}) }

// The window is left during a press: pending selects nothing, a running band ends; neither follows the pointer after.
@(test)
a_band_ends_with_its_window :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for running in ([2]bool{false, true}) {
		app: BG_App
		defer bg_destroy(&app)
		s := bg_start(t, &app, 20)
		session.press(s, bg_empty(s, 2))
		if running { session.move(s, bg_empty(s, 4)) }
		testing.expect(t, app.t.band.active == running && app.t.band.pending == !running, "the gesture")
		before := len(ui.list_selected_ids(&app.t.vl))
		session.activate(s, false)
		session.frames(s, 2)
		testing.expect(t, !app.t.band.active && !app.t.band.pending, "over")
		session.activate(s, true)
		session.move(s, bg_empty(s, 8))
		session.release(s, bg_empty(s, 8))
		testing.expect_value(t, len(ui.list_selected_ids(&app.t.vl)), before)
	}
}) }

// The view is hidden during a band, its press let go meanwhile; the view comes back under a press of another box.
@(test)
a_hidden_band_does_not_follow_a_later_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BG_App
	defer bg_destroy(&app)
	s := bg_start(t, &app, 20)
	to := bg_empty(s, 4)
	session.press(s, bg_empty(s, 2))
	session.move(s, to)
	testing.expect(t, app.t.band.active, "running")
	app.hidden = true
	session.frames(s, 2)
	session.release(s, to)
	session.press(s, session.center(session.get(s, "other")))
	app.hidden = false
	session.frames(s, 3)
	testing.expect(t, !app.t.band.active, "the press is another box's: the band is over")
	session.release(s, session.center(session.get(s, "other")))
}) }

// Escape on a pending press: nothing selected, and no rectangle from the rest of the press.
@(test)
escape_ends_a_pending_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BG_App
	defer bg_destroy(&app)
	s := bg_start(t, &app, 20)
	at := bg_empty(s, 2)
	session.press(s, at)
	session.key(s, .Escape)
	testing.expect(t, !app.t.band.pending, "over")
	session.move(s, bg_empty(s, 6))
	testing.expect(t, !app.t.band.active, "no rectangle from it")
	session.release(s, at)
	testing.expect_value(t, len(ui.list_selected_ids(&app.t.vl)), 0)
}) }

// The rectangle's moving corner stays under the pointer at every frame of a scroll that eases to its target, its other
// corner stays on the content; at a dpi of 1.5 too.
@(test)
the_band_stays_under_the_pointer_while_the_view_scrolls :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for dpi in ([2]f32{1, 1.5}) {
		app: BG_App
		defer bg_destroy(&app)
		s := bg_start(t, &app, 200)
		session.set_dpi(s, dpi)
		s.state.smooth_scroll = .On
		session.frames(s, 4)
		list := session.get(s, "rows")
		from := bg_empty(s, 1)
		at := (list.rect.min + list.rect.max) * 0.5
		session.press(s, from)
		session.move(s, at)
		list = session.get(s, "rows")
		list.view_target.y = 400
		seen := 0
		for _ in 0 ..< 60 {
			off := list.view_off.y   // (what the next build and its layout use)
			session.frame(s)
			r := session.get(s, "item_band").rect
			testing.expectf(t, abs(max(r.max.y, r.min.y) - at.y) <= 1 || abs(r.min.y - at.y) <= 1, "dpi %v: a corner at the pointer: %v, %v", dpi, r, at)
			top := max(from.y - off, list.rect.min.y)
			testing.expectf(t, abs(r.min.y - min(top, at.y)) <= 1, "dpi %v, scrolled %v: the start stays on the content: %v", dpi, off, r)
			if off > 0 && off < 399 { seen += 1 }
		}
		testing.expect(t, seen > 1, "frames in the middle of the scroll")
		session.release(s, at)
	}
}) }

// A filtered cell's text (a rich paragraph) is content before it was ever drawn (no renderer), and its width is the
// layout's.
@(test)
a_matched_name_is_content :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BG_App
	defer bg_destroy(&app)
	s := bg_start(t, &app, 20, filter = "doc")
	c := session.get(s, "c0", within = session.get(s, "lrow_2"))
	lit := session.get(s, "lit", within = c)
	testing.expect(t, lit.rich_width > 10, "its width")
	ui.use(s.state)
	row := session.get(s, "lrow_2")
	y := (row.rect.min.y + row.rect.max.y) * 0.5
	testing.expect(t, ui.row_content_at(row, {lit.rect.min.x + lit.text_pad + 3, y}), "the text")
	testing.expect(t, !ui.row_content_at(row, {lit.rect.min.x + lit.text_pad + lit.rich_width + 6, y}), "after it")
}) }

// A hundred thousand rows: a press, a drag and its frames build what is in view.
@(test)
a_band_in_a_long_list_builds_what_shows :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BG_App
	defer bg_destroy(&app)
	s := bg_start(t, &app, 100_000)
	still := s.state.boxes_built
	session.press(s, bg_empty(s, 2))
	session.move(s, bg_empty(s, 6))
	testing.expect(t, app.t.band.active, "running")
	testing.expectf(t, s.state.boxes_built <= still + 4, "%d boxes, %d at rest", s.state.boxes_built, still)
	testing.expect_value(t, app.t.band.hi - app.t.band.lo, 5)
	session.release(s, bg_empty(s, 6))
	testing.expect_value(t, len(ui.list_selected_ids(&app.t.vl)), 5)
}) }
