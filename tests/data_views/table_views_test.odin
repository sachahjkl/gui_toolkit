// A table's views (src/md/features/view-modes.md): the grid lays its cards in rows and the arrows move by card and by
// row; the columns view lays the names column by column and Left and Right move by column; the rubber band selects the
// cards it covers, Escape gives the selection back; the zoom keys and Ctrl+wheel step the zoom and say so.
//   odin test tests/data_views -collection:gt=src -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") VIEWS_W :: 620
@(private = "file") VIEWS_H :: 500

@(private = "file")
VIEW_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 0},
	{title = "Size", width = 6, number = true},
}

@(private = "file")
Views_App :: struct {
	t:      ui.Table,
	d:      ui.Table_Data,
	zoomed: int,   // the builds whose events said the zoom changed
}

@(private = "file")
views_init :: proc(app: ^Views_App, n: int, zoom: int) {
	ui.table_init(&app.t, VIEW_COLUMNS[:])
	app.t.zoom = zoom
	app.t.vl.multi = true
	app.t.rubber_band = true
	app.t.card_line = 1
	ui.table_data_reset(&app.d, len(VIEW_COLUMNS))
	for i in 0 ..< n {
		name := fmt.tprintf("file %02d.txt", i)
		ui.table_data_row(&app.d, u64(100 + i), name)
		ui.table_data_cell(&app.d, name)
		ui.table_data_cell(&app.d, fmt.tprintf("%d B", i), f64(i))
	}
	// (unsorted: the items in the data's order, item i is "file i")
	app.t.sort = ui.TABLE_UNSORTED
	ui.table_apply(&app.t, &app.d, "")
}

@(private = "file")
views_destroy :: proc(app: ^Views_App) {
	ui.table_destroy(&app.t)
	ui.table_data_destroy(&app.d)
}

@(private = "file")
views_build :: proc(s: ^session.Session) {
	app := (^Views_App)(s.user)
	ui.next({width = ui.px(VIEWS_W), height = ui.px(VIEWS_H)})
	ev := ui.table_build("###table", &app.t, &app.d, "Nothing here")
	if ev.zoomed { app.zoomed += 1 }
}

@(private = "file")
item :: proc(s: ^session.Session, i: int, loc := #caller_location) -> ^ui.Box {
	return session.get(s, fmt.tprintf("item%d", i), loc = loc)
}

@(private = "file")
selected :: proc(app: ^Views_App) -> []u64 { return ui.list_selected_ids(&app.t.vl) }

@(test)
a_grid_lays_its_cards_in_rows_and_the_arrows_move_by_card_and_row :: proc(t: ^testing.T) {
	app: Views_App
	views_init(&app, 20, 3)
	defer views_destroy(&app)
	s := session.start(t, {build = views_build, user = &app, no_renderer = true})
	session.frames(s, 2)   // (the cards in a row come from the last layout's width)
	testing.expect_value(t, ui.table_view(&app.t), ui.Table_View.Grid)
	per := app.t.line_items
	testing.expect(t, per >= 2, "several cards in a row")
	// a row's cards side by side, the next card under the first
	for c in 1 ..< per {
		testing.expect(t, item(s, c).rect.min.y == item(s, 0).rect.min.y, "a row's cards on one line")
		testing.expect(t, item(s, c).rect.min.x > item(s, c - 1).rect.max.x, "a row's cards left to right")
	}
	testing.expect(t, item(s, per).rect.min.y > item(s, 0).rect.max.y, "the next row under")
	testing.expect(t, item(s, per).rect.min.x == item(s, 0).rect.min.x, "the next row from the left")
	// the arrows: by a card, by a row
	session.click(s, "item0")
	testing.expect_value(t, app.t.vl.sel, 0)
	session.key(s, .Right)
	testing.expect_value(t, app.t.vl.sel, 1)
	session.key(s, .Down)
	testing.expect_value(t, app.t.vl.sel, 1 + per)
	session.key(s, .Left)
	testing.expect_value(t, app.t.vl.sel, per)
	session.key(s, .Up)
	testing.expect_value(t, app.t.vl.sel, 0)
	// Shift: the range, by the same moves
	session.key(s, .Down, {.Shift})
	testing.expect_value(t, len(selected(&app)), per + 1)
	session.key(s, .End)
	testing.expect_value(t, app.t.vl.sel, 19)
	testing.expect_value(t, ui.table_selected(&app.t), 19)
	testing.expect_value(t, len(selected(&app)), 1)
}

@(test)
the_band_selects_the_cards_it_covers_and_escape_gives_the_selection_back :: proc(t: ^testing.T) {
	app: Views_App
	views_init(&app, 6, 3)
	defer views_destroy(&app)
	s := session.start(t, {build = views_build, user = &app, no_renderer = true})
	session.frames(s, 2)
	per := app.t.line_items
	testing.expect(t, per >= 3 && per < 6, "two rows of cards")
	last := item(s, 5)
	// from under the last row, below the second card, to the middle of the first card
	from := [2]f32{session.center(item(s, 1)).x, last.rect.max.y + 30}
	to := session.center(item(s, 0))
	session.drag(s, from, to)
	got := selected(&app)
	want := [?]u64{100, 101, 100 + u64(per), 101 + u64(per)}
	testing.expect_value(t, len(got), len(want))
	for id in want {
		found := false
		for g in got { if g == id { found = true } }
		testing.expectf(t, found, "item %d selected", id - 100)
	}
	// a rectangle, then Escape: the selection there was
	session.click(s, "item2")
	session.press(s, from)
	session.move(s, to)
	session.frames(s, 2)
	testing.expect(t, app.t.band.active, "the band runs")
	testing.expect(t, len(selected(&app)) > 1, "the band selects")
	session.key(s, .Escape)
	session.release(s, to)
	got = selected(&app)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 { testing.expect_value(t, got[0], 102) }
}

@(test)
the_columns_view_lays_the_names_column_by_column :: proc(t: ^testing.T) {
	app: Views_App
	views_init(&app, 40, 2)
	defer views_destroy(&app)
	s := session.start(t, {build = views_build, user = &app, no_renderer = true})
	session.frames(s, 2)
	testing.expect_value(t, ui.table_view(&app.t), ui.Table_View.Columns)
	per := app.t.line_items
	testing.expect(t, per >= 2 && per < 40, "a column holds some names")
	for r in 1 ..< per {
		testing.expect(t, item(s, r).rect.min.x == item(s, 0).rect.min.x, "a column's names one under the other")
		testing.expect(t, item(s, r).rect.min.y >= item(s, r - 1).rect.max.y, "down the column")
	}
	testing.expect(t, item(s, per).rect.min.y == item(s, 0).rect.min.y, "the next column from the top")
	testing.expect(t, item(s, per).rect.min.x > item(s, 0).rect.max.x, "the next column to the right")
	session.click(s, "item0")
	session.key(s, .Down)
	testing.expect_value(t, app.t.vl.sel, 1)
	session.key(s, .Right)
	testing.expect_value(t, app.t.vl.sel, 1 + per)
	session.key(s, .Left)
	testing.expect_value(t, app.t.vl.sel, 1)
}

@(test)
the_zoom_keys_and_ctrl_wheel_step_the_zoom :: proc(t: ^testing.T) {
	app: Views_App
	views_init(&app, 10, 0)
	defer views_destroy(&app)
	app.t.zoom_keys = true
	s := session.start(t, {build = views_build, user = &app, no_renderer = true})
	testing.expect_value(t, ui.table_view(&app.t), ui.Table_View.Details)
	session.click(s, "lrow_0")
	session.key(s, .Equal, {.Ctrl})
	testing.expect_value(t, app.t.zoom, 1)
	testing.expect_value(t, app.zoomed, 1)
	testing.expect_value(t, session.focused(s).key, app.t.vl.key)   // (the keyboard followed the view's new box)
	session.key(s, .Equal, {.Ctrl})
	testing.expect_value(t, ui.table_view(&app.t), ui.Table_View.Columns)
	session.key(s, .Minus, {.Ctrl})
	testing.expect_value(t, app.t.zoom, 1)
	// the wheel up with Ctrl over the table: a step in each notch
	session.wheel(s, session.center(session.get(s, "table")), {0, -2}, {.Ctrl})
	testing.expect_value(t, app.t.zoom, 3)
	testing.expect_value(t, ui.table_view(&app.t), ui.Table_View.Grid)
	// Ctrl+0: the first step
	session.click(s, "item0")
	session.key(s, .N0, {.Ctrl})
	testing.expect_value(t, app.t.zoom, 0)
	testing.expect_value(t, ui.table_selected(&app.t), 0)   // (the selection is the same in every view)
	testing.expect_value(t, app.zoomed, 5)
}

@(private = "file")
Name_App :: struct {
	cut, short: [128]u8,
	cut_n, short_n: int,
}

// (in a build: the style's font measures the names)
@(private = "file")
name_build :: proc(s: ^session.Session) {
	app := (^Name_App)(s.user)
	app.cut_n = copy(app.cut[:], ui.table_card_name("a very long name of a photograph taken on holiday.jpeg", 120, 1))
	app.short_n = copy(app.short[:], ui.table_card_name("a.txt", 120, 1))
}

@(test)
a_card_name_is_cut_in_its_middle_keeping_its_extension :: proc(t: ^testing.T) {
	app: Name_App
	s := session.start(t, {build = name_build, user = &app, no_renderer = true})
	session.frame(s)
	cut := string(app.cut[:app.cut_n])
	testing.expectf(t, strings.contains(cut, "…"), "cut: %s", cut)
	testing.expectf(t, strings.has_suffix(cut, "holiday.jpeg") || strings.has_suffix(cut, "day.jpeg"), "the end kept: %s", cut)
	testing.expectf(t, strings.has_prefix(cut, "a very"), "the start kept: %s", cut)
	testing.expect_value(t, string(app.short[:app.short_n]), "a.txt")
}
