// The rubber band over a program's own items (ui.Item_Band, src/md/features/view-modes.md): it leaves the rows that
// cannot be selected as they are and never puts the cursor on one; `changed` is told exactly the rows it changes, at the
// press, during the drag and at Escape.
//   odin test tests/data_views -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

// (one column of 10 items, 100 wide, 20 high: item r spans y in [20r, 20r + 20) of the box's content)
@(private = "file") BAND_ITEMS :: 30
@(private = "file") BAND_PER :: 10
@(private = "file") BAND_ROW_H :: 20

@(private = "file")
Band_Change :: struct {
	row: int,
	on:  bool,
}

@(private = "file")
Band_App :: struct {
	t:          ^testing.T,
	band:       ui.Item_Band,
	sel:        ui.Item_Selection,
	selectable: [BAND_ITEMS]bool,
	cancel:     bool,                   // the next build sends Escape to the band
	changes:    [dynamic]Band_Change,
}

@(private = "file")
band_rows :: proc(app: ^Band_App) -> ui.Item_Rows { return {count = BAND_ITEMS, selectable = app.selectable[:]} }

@(private = "file")
band_changed :: proc(user: rawptr, row: int, now_selected: bool) {
	app := (^Band_App)(user)
	// (told after the change: the selection already says it)
	testing.expectf(app.t, ui.item_selection_has(&app.sel, band_rows(app), row) == now_selected, "row %d told as it is", row)
	append(&app.changes, Band_Change{row, now_selected})
}

@(private = "file")
band_build :: proc(s: ^session.Session) {
	app := (^Band_App)(s.user)
	rows := band_rows(app)
	if app.cancel {
		_ = ui.item_band_cancel(&app.band, &app.sel, rows)
		app.cancel = false
	}
	ui.next({width = ui.px(400), height = ui.px(300)})
	b := ui.build_box({.Clickable}, "###band_area")
	layout := ui.Item_Band_Layout{kind = .Columns, count = BAND_PER, item_w = 100, step = 100, row_h = BAND_ROW_H}
	_ = ui.item_band_update(&app.band, &app.sel, rows, b, layout, false)
}

@(private = "file")
band_start :: proc(t: ^testing.T, app: ^Band_App) -> ^session.Session {
	app.t = t
	app.sel = {sel = -1, multi = true}
	for &on in app.selectable { on = true }
	s := session.start(t, {build = band_build, user = app, no_renderer = true})
	session.frames(s, 2)
	return s
}

@(private = "file")
band_destroy :: proc(app: ^Band_App) {
	ui.item_band_destroy(&app.band)
	ui.item_selection_destroy(&app.sel)
	delete(app.changes)
}

// A point of the band's box at (x, y) of its content.
@(private = "file")
band_at :: proc(s: ^session.Session, x, y: f32) -> [2]f32 { return session.get(s, "band_area").rect.min + {x, y} }

@(test)
the_band_leaves_the_rows_that_cannot_be_selected :: proc(t: ^testing.T) {
	app: Band_App
	defer band_destroy(&app)
	s := band_start(t, &app)
	app.selectable[2], app.selectable[5] = false, false
	// from the top of item 0 to item 5: the rows 0 to 5 touched, the last one not selectable
	session.drag(s, band_at(s, 50, 5), band_at(s, 50, 5 * BAND_ROW_H + 10))
	rows := band_rows(&app)
	for r in 0 ..< BAND_ITEMS {
		want := r <= 4 && r != 2
		testing.expectf(t, ui.item_selection_has(&app.sel, rows, r) == want, "row %d selected: %v", r, want)
	}
	testing.expect_value(t, app.sel.sel, 4)   // (the cursor on the last row it took, not on row 5)
}

@(test)
the_band_tells_exactly_the_rows_it_changes :: proc(t: ^testing.T) {
	app: Band_App
	defer band_destroy(&app)
	s := band_start(t, &app)
	app.band.changed, app.band.user = band_changed, &app
	app.selectable[2] = false
	rows := band_rows(&app)
	ui.item_selection_set(&app.sel, rows, 7)
	ui.item_selection_set(&app.sel, rows, 8)
	// a press without Ctrl: the selection there was goes, row by row; then down to row 4, back up to row 1
	session.press(s, band_at(s, 50, 5))
	session.move(s, band_at(s, 50, 4 * BAND_ROW_H + 10))
	session.move(s, band_at(s, 50, BAND_ROW_H + 10))
	want := [?]Band_Change{{7, false}, {8, false}, {0, true}, {1, true}, {3, true}, {4, true}, {3, false}, {4, false}}
	testing.expect_value(t, len(app.changes), len(want))
	for c, i in want {
		if i >= len(app.changes) { break }
		testing.expectf(t, app.changes[i] == c, "change %d: %v, not %v", i, app.changes[i], c)
	}
	// Escape: the selection there was back, each row told
	clear(&app.changes)
	app.cancel = true
	session.frame(s)
	session.release(s, band_at(s, 50, BAND_ROW_H + 10))
	back := [?]Band_Change{{0, false}, {1, false}, {7, true}, {8, true}}
	testing.expect_value(t, len(app.changes), len(back))
	for c, i in back {
		if i >= len(app.changes) { break }
		testing.expectf(t, app.changes[i] == c, "Escape, change %d: %v, not %v", i, app.changes[i], c)
	}
	testing.expect_value(t, ui.item_selection_count(&app.sel, rows), 2)
}
