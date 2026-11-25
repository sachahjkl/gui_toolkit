// Rectangle selection in full list views (Table Details and List): pressing the empty part of a row and dragging past
// the drag threshold starts the band; pressing content (icon, name text, matched text, cell text, control) keeps the
// drag free for item drag; clicks, Ctrl/Shift clicks, double click, right click, touch, keyboard, screen readers,
// in-place rename, edge autoscroll, bottom empty strip, right margin, and single-select tables all behave as specified.
package data_views_test

import "core:fmt"
import "core:testing"
import "gt:draw"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") BL_WIN :: [2]int{620, 400}
@(private = "file") BL_TABLE_W :: f32(560)
@(private = "file") BL_TABLE_H :: f32(320)

@(private = "file")
BL_COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 0},
	{title = "Size", width = 10, number = true},
}

@(private = "file")
BL_App :: struct {
	t:           ui.Table,
	d:           ui.Table_Data,
	rename:      ui.Line_Edit,
	with_button: bool,
	btn_clicks:  int,
	activated:   int,
	menus:       int,
}

@(private = "file")
bl_lead :: proc(t: ^ui.Table, row: int, size: f32) {
	app := (^BL_App)(t.lead_user)
	if app != nil && app.with_button {
		ui.next({width = ui.px(size), height = ui.px(size)})
		if ui.button(fmt.tprintf("B###btn_%d", row)).clicked { app.btn_clicks += 1 }
		return
	}
	ui.icon("F", size)
}

@(private = "file")
bl_edit :: proc(t: ^ui.Table, row: int) {
	app := (^BL_App)(t.lead_user)
	ui.next({width = ui.fill(), height = ui.pct(1)})
	_ = ui.line_edit("###rename", &app.rename)
}

@(private = "file")
bl_init :: proc(app: ^BL_App, n: int, zoom := 0, multi := true, long_names := false, query := "") {
	ui.table_init(&app.t, BL_COLUMNS[:])
	app.t.zoom = zoom
	app.t.vl.multi = multi
	app.t.rubber_band = true
	app.t.lead = bl_lead
	app.t.lead_user = app
	app.t.edit = bl_edit
	ui.table_data_reset(&app.d, len(BL_COLUMNS))
	for i in 0 ..< n {
		name := fmt.tprintf("doc%02d.txt", i)
		if long_names { name = fmt.tprintf("very_long_document_name_%02d_with_many_segments_that_exceeds_column_width_completely.txt", i) }
		ui.table_data_row(&app.d, u64(2000 + i), name)
		ui.table_data_cell(&app.d, name)
		ui.table_data_cell(&app.d, fmt.tprintf("%d B", (i + 1) * 10), f64((i + 1) * 10))
	}
	app.t.sort = ui.TABLE_UNSORTED
	ui.table_apply(&app.t, &app.d, query)
}

@(private = "file")
bl_destroy :: proc(app: ^BL_App) {
	ui.table_destroy(&app.t)
	ui.table_data_destroy(&app.d)
	ui.line_edit_destroy(&app.rename)
}

@(private = "file")
bl_build :: proc(s: ^session.Session) {
	app := (^BL_App)(s.user)
	ui.next({width = ui.px(BL_TABLE_W), height = ui.px(BL_TABLE_H)})
	ev := ui.table_build("###table", &app.t, &app.d, "Empty")
	if ev.activated { app.activated += 1 }
	if ev.menu { app.menus += 1 }
}

@(private = "file")
bl_mod_click :: proc(s: ^session.Session, at: [2]f32, mods: platform.Modifiers) {
	session.move(s, at)
	s.buttons += {.Left}
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = at, mods = mods})
	session.frame(s)
	s.buttons -= {.Left}
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = at, mods = mods})
	session.frames(s, 2)
}

@(private = "file")
bl_mod_drag :: proc(s: ^session.Session, from, to: [2]f32, mods: platform.Modifiers) {
	session.move(s, from)
	s.buttons += {.Left}
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = from, mods = mods})
	session.frames(s, 2)
	s.pointer = to
	session.event(s, {kind = .Mouse_Move, pos = to, mods = mods})
	session.frames(s, 2)
	s.buttons -= {.Left}
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = to, mods = mods})
	session.frames(s, 2)
}

@(private = "file")
bl_has_ids :: proc(t: ^testing.T, app: ^BL_App, want: []int, msg: string, loc := #caller_location) {
	got := ui.list_selected_ids(&app.t.vl)
	testing.expectf(t, len(got) == len(want), "%s: selected count %d, want %d (%v)", msg, len(got), len(want), got, loc = loc)
	for idx in want {
		id := u64(2000 + idx)
		found := false
		for g in got { if g == id { found = true; break } }
		testing.expectf(t, found, "%s: row %d (id %d) selected (got %v)", msg, idx, id, got, loc = loc)
	}
}

// Details and List views: dragging from the empty part of a row (right of Name text, or left padding of a numeric
// column) starts a visible rubber band and selects touched rows; dragging from content (icon, name text, highlighted
// match text, cell text, clickable button) does NOT start the band.
@(test)
details_and_list_row_empty_part_starts_band_while_content_does_not :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// 1. Details view with software renderer so band visibility is also verified.
	{
		app: BL_App
		bl_init(&app, 40, zoom = 0)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app})
		session.frames(s, 3)

		view := session.get(s, "rows")
		row1 := session.get(s, "lrow_1")
		row4 := session.get(s, "lrow_4")
		c0 := session.get(s, "c0", within = row1)
		c1 := session.get(s, "c1", within = row1)
		y1 := (row1.rect.min.y + row1.rect.max.y) * 0.5
		y4 := (row4.rect.min.y + row4.rect.max.y) * 0.5

		// Empty part right of Name text -> starts band and draws rectangle.
		empty_name := [2]f32{c0.rect.min.x + c0.text_dim.x + 60, y1}
		to := [2]f32{empty_name.x + 40, y4}
		before := session.capture(s)
		session.press(s, empty_name)
		testing.expect(t, !app.t.band.active, "Details: band does not activate before drag threshold")
		session.move(s, to)
		session.frames(s, 1)
		testing.expect(t, app.t.band.active, "Details: drag from empty part right of Name starts band")
		check_band_drawn(t, s, view, {empty_name, to}, before, "Details empty part of row")
		session.release(s, to)
		bl_has_ids(t, &app, {1, 2, 3, 4}, "Details: empty-name drag selected rows 1..4")

		// Empty left padding of right-aligned Size column -> starts band.
		empty_size := [2]f32{c1.rect.min.x + 8, y1}
		session.drag(s, empty_size, {empty_size.x + 12, y4})
		bl_has_ids(t, &app, {1, 2, 3, 4}, "Details: empty padding of Size column starts band")

		// Content: icon (lead) -> drag must NOT start band.
		ico := session.get(s, "ico1", within = row1)
		ico_pt := session.center(ico)
		session.press(s, ico_pt)
		session.move(s, {ico_pt.x + 30, y4})
		testing.expect(t, !app.t.band.active, "Details: drag from icon does not start band")
		session.release(s, {ico_pt.x + 30, y4})

		// Content: Name text -> drag must NOT start band.
		name_pt := [2]f32{c0.rect.min.x + 12, y1}
		session.press(s, name_pt)
		session.move(s, {name_pt.x + 30, y4})
		testing.expect(t, !app.t.band.active, "Details: drag from Name text does not start band")
		session.release(s, {name_pt.x + 30, y4})

		// Content: Size digits (right-aligned) -> drag must NOT start band.
		size_text_pt := [2]f32{c1.rect.max.x - c1.text_pad - 6, y1}
		session.press(s, size_text_pt)
		session.move(s, {size_text_pt.x - 20, y4})
		testing.expect(t, !app.t.band.active, "Details: drag from Size text does not start band")
		session.release(s, {size_text_pt.x - 20, y4})
	}

	// 2. Details view with active search highlight (rich_paragraph in Name cell): text is content, right of text is empty.
	{
		app: BL_App
		bl_init(&app, 40, zoom = 0, query = "doc")
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		row1 := session.get(s, "lrow_1")
		row4 := session.get(s, "lrow_4")
		c0 := session.get(s, "c0", within = row1)
		y1 := (row1.rect.min.y + row1.rect.max.y) * 0.5
		y4 := (row4.rect.min.y + row4.rect.max.y) * 0.5

		// On highlighted text -> no band.
		session.press(s, {c0.rect.min.x + 12, y1})
		session.move(s, {c0.rect.min.x + 40, y4})
		testing.expect(t, !app.t.band.active, "Filtered Details: drag on highlighted Name text does not start band")
		session.release(s, {c0.rect.min.x + 40, y4})

		// Right of highlighted text -> starts band.
		empty_pt := [2]f32{c0.rect.max.x - 30, y1}
		session.drag(s, empty_pt, {empty_pt.x, y4})
		bl_has_ids(t, &app, {1, 2, 3, 4}, "Filtered Details: drag right of highlighted text starts band")
	}

	// 3. Details view with a clickable control inside the row: pressing control clicks it, never starts band.
	{
		app: BL_App
		app.with_button = true
		bl_init(&app, 20, zoom = 0)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		btn := session.get(s, "btn_1")
		row4 := session.get(s, "lrow_4")
		session.press(s, session.center(btn))
		session.move(s, {session.center(btn).x + 20, session.center(row4).y})
		testing.expect(t, !app.t.band.active, "Control in row: drag on button does not start band")
		session.release(s, {session.center(btn).x + 20, session.center(row4).y})
	}

	// 4. List view (zoom = 1): empty part right of Name text starts band, Name text does not.
	{
		app: BL_App
		bl_init(&app, 40, zoom = 1)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		row1 := session.get(s, "lrow_1")
		row4 := session.get(s, "lrow_4")
		c0 := session.get(s, "c0", within = row1)
		y1 := (row1.rect.min.y + row1.rect.max.y) * 0.5
		y4 := (row4.rect.min.y + row4.rect.max.y) * 0.5

		// Name text -> no band.
		session.press(s, {c0.rect.min.x + 12, y1})
		session.move(s, {c0.rect.min.x + 40, y4})
		testing.expect(t, !app.t.band.active, "List: drag from Name text does not start band")
		session.release(s, {c0.rect.min.x + 40, y4})

		// Right of Name text -> starts band and selects rows 1..4.
		empty_pt := [2]f32{c0.rect.min.x + c0.text_dim.x + 80, y1}
		session.drag(s, empty_pt, {empty_pt.x + 20, y4})
		bl_has_ids(t, &app, {1, 2, 3, 4}, "List: drag from empty part right of Name starts band")
	}
}) }

// Drag threshold, clicks (plain, Ctrl, Shift, Ctrl+Shift), double click, and right click on the empty part of a row.
@(test)
empty_part_clicks_threshold_double_and_right_click :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BL_App
	bl_init(&app, 30, zoom = 0)
	defer bl_destroy(&app)
	s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
	session.frames(s, 3)

	row_empty :: proc(s: ^session.Session, i: int) -> [2]f32 {
		r := session.get(s, fmt.tprintf("lrow_%d", i))
		c0 := session.get(s, "c0", within = r)
		return {c0.rect.min.x + c0.text_dim.x + 60, (r.rect.min.y + r.rect.max.y) * 0.5}
	}

	// Sub-threshold wiggle (2 px < 4 px drag threshold): band must NOT start; release selects row 2.
	p2 := row_empty(s, 2)
	session.press(s, p2)
	session.move(s, p2 + {2, 1})
	testing.expect(t, !app.t.band.active, "sub-threshold move does not start band")
	session.release(s, p2 + {2, 1})
	bl_has_ids(t, &app, {2}, "sub-threshold release selects row 2")

	// Plain click on empty part of row 4 -> row 4 alone.
	session.click_at(s, row_empty(s, 4))
	bl_has_ids(t, &app, {4}, "plain click on empty part selects row 4")

	// Ctrl+click on empty part of row 1 -> {1, 4} and anchor = 1.
	bl_mod_click(s, row_empty(s, 1), {.Ctrl})
	bl_has_ids(t, &app, {1, 4}, "Ctrl+click on empty part toggles row 1 on")

	// Shift+click on empty part of row 3 -> range 1..3 from Ctrl-clicked anchor.
	bl_mod_click(s, row_empty(s, 3), {.Shift})
	bl_has_ids(t, &app, {1, 2, 3}, "Shift+click after Ctrl+click selects range 1..3")

	// Ctrl+Shift+click on empty part of row 6 -> adds range to base.
	bl_mod_click(s, row_empty(s, 5), {.Ctrl})
	bl_mod_click(s, row_empty(s, 7), {.Ctrl, .Shift})
	bl_has_ids(t, &app, {1, 2, 3, 5, 6, 7}, "Ctrl+Shift+click on empty part adds range")

	// Right-click on empty part of an already-selected row preserves multi-selection and opens menu.
	menus_before := app.menus
	session.click_at(s, row_empty(s, 2), .Right)
	testing.expect(t, app.menus == menus_before + 1, "right-click on empty part emits menu")
	bl_has_ids(t, &app, {1, 2, 3, 5, 6, 7}, "right-click on selected row's empty part keeps selection")

	// Right-click on empty part of an unselected row selects that row alone and opens menu.
	session.click_at(s, row_empty(s, 9), .Right)
	testing.expect(t, app.menus == menus_before + 2, "right-click on unselected row emits menu")
	bl_has_ids(t, &app, {9}, "right-click on unselected row's empty part selects row 9 alone")

	// Double-click on empty part of row 3 activates row 3.
	act_before := app.activated
	session.click_at(s, row_empty(s, 3), count = 2)
	testing.expect(t, app.activated == act_before + 1, "double-click on empty part activates row")
	bl_has_ids(t, &app, {3}, "double-click on empty part selects row 3")

	// Moving >= drag threshold (6 px) from the same empty point starts band.
	p1 := row_empty(s, 1)
	session.press(s, p1)
	session.move(s, p1 + {0, 6})
	testing.expect(t, app.t.band.active, "move past drag threshold starts band")
	session.release(s, p1 + {0, 6})
}) }

// Dragging from the empty part of an already-selected row (single or multi-selected): plain drag starts a fresh band
// and Escape restores the pre-press multi-selection; Ctrl+drag from selected removes; Ctrl+drag from unselected adds.
@(test)
drag_from_already_selected_row_empty_part :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: BL_App
	bl_init(&app, 30, zoom = 0)
	defer bl_destroy(&app)
	s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
	session.frames(s, 3)

	row_empty :: proc(s: ^session.Session, i: int) -> [2]f32 {
		r := session.get(s, fmt.tprintf("lrow_%d", i))
		c0 := session.get(s, "c0", within = r)
		return {c0.rect.min.x + c0.text_dim.x + 60, (r.rect.min.y + r.rect.max.y) * 0.5}
	}

	// Pre-select rows 1, 2, 3.
	session.click_at(s, row_empty(s, 1))
	bl_mod_click(s, row_empty(s, 3), {.Shift})
	bl_has_ids(t, &app, {1, 2, 3}, "pre-selected rows 1..3")

	// Plain drag starting on already-selected row 2's empty part down to row 5 -> fresh band selects 2..5.
	// Escape before release restores exact pre-press multi-selection {1, 2, 3}!
	p2 := row_empty(s, 2)
	p5 := row_empty(s, 5)
	session.press(s, p2)
	session.move(s, p5)
	testing.expect(t, app.t.band.active, "plain drag on already-selected row's empty part starts band")
	bl_has_ids(t, &app, {2, 3, 4, 5}, "fresh band from selected row 2 selects 2..5")
	session.key(s, .Escape)
	session.release(s, p5)
	bl_has_ids(t, &app, {1, 2, 3}, "Escape restores pre-press multi-selection {1, 2, 3}")

	// Repeat without Escape -> commits fresh band {2, 3, 4, 5}.
	session.drag(s, p2, p5)
	bl_has_ids(t, &app, {2, 3, 4, 5}, "committed plain drag from selected row selects 2..5")

	// Ctrl+drag starting on ALREADY-SELECTED row 3's empty part down to row 4 -> removes 3 and 4, keeping 2 and 5.
	bl_mod_drag(s, row_empty(s, 3), row_empty(s, 4), {.Ctrl})
	bl_has_ids(t, &app, {2, 5}, "Ctrl+drag from selected row's empty part removes touched rows")

	// Ctrl+drag starting on UNSELECTED row 6's empty part down to row 7 -> adds 6 and 7.
	bl_mod_drag(s, row_empty(s, 6), row_empty(s, 7), {.Ctrl})
	bl_has_ids(t, &app, {2, 5, 6, 7}, "Ctrl+drag from unselected row's empty part adds touched rows")
}) }

// Full Details and List views with very long truncated filenames still provide:
// 1) a bottom empty strip (~half a row) when scrolled to the bottom,
// 2) a narrow empty margin at the right edge of every row.
@(test)
full_list_keeps_bottom_strip_and_right_margin :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for zoom in ([2]int{0, 1}) {
		label := zoom == 0 ? "Details" : "List"
		app: BL_App
		bl_init(&app, 40, zoom = zoom, long_names = true)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		// 1. Narrow right margin on a row whose filename is completely truncated.
		row1 := session.get(s, "lrow_1")
		row3 := session.get(s, "lrow_3")
		right_margin_x := row1.rect.max.x - 4
		y1 := (row1.rect.min.y + row1.rect.max.y) * 0.5
		y3 := (row3.rect.min.y + row3.rect.max.y) * 0.5
		session.drag(s, {right_margin_x, y1}, {right_margin_x, y3})
		bl_has_ids(t, &app, {1, 2, 3}, fmt.tprintf("%s: drag in right margin starts band", label))

		// 2. Scroll to the very bottom: ~half a row of empty strip stays below the last row.
		view := session.get(s, "rows")
		row_h := row1.rect.max.y - row1.rect.min.y
		view.view_off.y, view.view_target.y = 100_000, 100_000
		session.frames(s, 4)
		view = session.get(s, "rows")
		last := session.get(s, "lrow_39")
		content_bottom := view.rect.max.y - ui.scrollbar_room(view, .Y)
		strip := content_bottom - last.rect.max.y
		testing.expectf(t, strip >= row_h * 0.4, "%s: bottom empty strip %.1f >= 0.4 * row_h (%.1f)", label, strip, row_h * 0.4)

		// Dragging from the bottom empty strip upward selects the last 3 rows.
		from := [2]f32{view.rect.min.x + 80, last.rect.max.y + strip * 0.5}
		row37 := session.get(s, "lrow_37")
		to := [2]f32{from.x + 20, (row37.rect.min.y + row37.rect.max.y) * 0.5}
		session.drag(s, from, to)
		bl_has_ids(t, &app, {37, 38, 39}, fmt.tprintf("%s: drag from bottom strip selects last 3 rows", label))
	}
}) }

// Touch/pen, keyboard, screen reader, in-place rename, edge autoscroll, and single-select tables keep working.
@(test)
touch_keyboard_a11y_rename_autoscroll_and_single_select :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	// 1. Touch/pen, keyboard, screen reader, rename, and autoscroll on multi-select Details table.
	{
		app: BL_App
		bl_init(&app, 80, zoom = 0)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		row_empty :: proc(s: ^session.Session, i: int) -> [2]f32 {
			r := session.get(s, fmt.tprintf("lrow_%d", i))
			c0 := session.get(s, "c0", within = r)
			return {c0.rect.min.x + c0.text_dim.x + 60, (r.rect.min.y + r.rect.max.y) * 0.5}
		}

		// Pen tap on empty part -> selects row 2.
		p2 := row_empty(s, 2)
		session.pen_press(s, p2, 0.5)
		session.pen_release(s, p2)
		bl_has_ids(t, &app, {2}, "pen tap on empty part selects row 2")

		// Pen drag on empty part (separate gesture after double-click window) -> starts band and selects 2..4.
		session.advance(s, session.SEPARATE_CLICK_MS)
		session.pen_drag(s, p2, row_empty(s, 4))
		bl_has_ids(t, &app, {2, 3, 4}, "pen drag on empty part starts band")

		// Lost release (touch cancel / focus loss) on empty part -> cancels pending without selecting.
		p6 := row_empty(s, 6)
		session.press(s, p6)
		s.buttons -= {.Left}
		session.event(s, {kind = .Mouse_Release, button = .Left, pos = p6, lost = true})
		session.frames(s, 2)
		bl_has_ids(t, &app, {2, 3, 4}, "lost release cancels pending without changing selection")

		// Keyboard navigation works cleanly after empty-part band.
		session.key(s, .Down)
		bl_has_ids(t, &app, {5}, "Down arrow moves selection after band")
		session.key(s, .Down, {.Shift})
		bl_has_ids(t, &app, {5, 6}, "Shift+Down extends selection after band")

		// Screen reader click selects row 1 immediately.
		row1 := session.get(s, "lrow_1")
		ui.a11y_inject(s.state, {target = u64(row1.key), action = .Click})
		session.frames(s, 2)
		bl_has_ids(t, &app, {1}, "screen reader click selects row 1")

		// In-place rename: dragging inside line_edit never starts band.
		app.t.editing = true
		app.t.edit_id = 2001
		ui.line_edit_set(&app.rename, "doc01.txt")
		session.frames(s, 2)
		ed := session.get(s, "rename")
		session.press(s, {ed.rect.min.x + 10, session.center(ed).y})
		session.move(s, {ed.rect.min.x + 80, session.center(ed).y})
		testing.expect(t, !app.t.band.active, "rename: dragging inside line_edit does not start band")
		session.release(s, {ed.rect.min.x + 80, session.center(ed).y})
		app.t.editing = false
		session.frames(s, 2)

		// Edge autoscroll: drag from empty part of row 1 to bottom edge scrolls past row 1 and keeps band alive.
		view := session.get(s, "rows")
		p1 := row_empty(s, 1)
		edge := [2]f32{p1.x + 20, view.rect.max.y - 4}
		session.press(s, p1)
		session.move(s, edge)
		testing.expect(t, app.t.band.active, "autoscroll: band active from empty part of row 1")
		for _ in 0 ..< 120 {
			session.frame(s)
			if app.t.vl.first > 5 { break }
		}
		testing.expectf(t, app.t.vl.first > 5, "autoscroll scrolled past row 1 (first=%d)", app.t.vl.first)
		testing.expect(t, app.t.band.active, "autoscroll: band survives row 1 leaving virtual range")
		session.release(s, edge)
		testing.expect(t, len(ui.list_selected_ids(&app.t.vl)) > 10, "autoscroll band selected scrolled rows")
	}

	// 2. Single-select table (multi = false) is unchanged: selects immediately on press, no band, no extra bottom strip.
	{
		app: BL_App
		bl_init(&app, 40, zoom = 0, multi = false)
		defer bl_destroy(&app)
		s := session.start(t, {size = BL_WIN, build = bl_build, user = &app, no_renderer = true})
		session.frames(s, 3)

		row1 := session.get(s, "lrow_1")
		row4 := session.get(s, "lrow_4")
		c0 := session.get(s, "c0", within = row1)
		p1 := [2]f32{c0.rect.min.x + c0.text_dim.x + 60, (row1.rect.min.y + row1.rect.max.y) * 0.5}
		session.press(s, p1)
		testing.expect_value(t, app.t.vl.sel, 1)
		session.move(s, {p1.x, (row4.rect.min.y + row4.rect.max.y) * 0.5})
		testing.expect(t, !app.t.band.active, "single-select: dragging empty part starts no band")
		session.release(s, {p1.x, (row4.rect.min.y + row4.rect.max.y) * 0.5})
		testing.expect_value(t, app.t.vl.sel, 1)

		// No extra bottom strip on single-select table.
		view := session.get(s, "rows")
		view.view_off.y, view.view_target.y = 100_000, 100_000
		session.frames(s, 4)
		view = session.get(s, "rows")
		last := session.get(s, "lrow_39")
		content_bottom := view.rect.max.y - ui.scrollbar_room(view, .Y)
		testing.expectf(t, content_bottom - last.rect.max.y <= 2, "single-select: no extra bottom strip (gap=%.1f)", content_bottom - last.rect.max.y)
	}
}) }

// A program that builds its own full-width rows (own Item_Selection, custom row draw, icon, custom bar inside a numeric
// cell, item-drag detector, and running selection total via Item_Band.changed) gets Explorer/Nautilus band behavior in
// a few lines using List_State.pressed_empty, item_band_row_press, item_band_update, and Virtual_List.end_space.
@(test)
custom_full_width_rows_api_supports_band_and_item_drag :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	N :: 30
	Custom_App :: struct {
		vl:          ui.Virtual_List,
		layout:      ui.Table_Layout,
		sel:         ui.Item_Selection,
		band:        ui.Item_Band,
		ids:         [N]u64,
		weights:     [N]int,
		sel_weight:  int,
		item_drags:  int,
		drag_fired:  bool,
	}
	app := Custom_App{sel = {sel = -1, multi = true}}
	cols := [?]ui.Table_Column{{title = "Name", width = 0}, {title = "Size", width = 10, number = true}}
	ui.table_layout_init(&app.layout, cols[:])
	for i in 0 ..< N {
		app.ids[i] = u64(5000 + i)
		app.weights[i] = (i + 1) * 10
	}
	defer {
		ui.vlist_destroy(&app.vl)
		ui.table_layout_destroy(&app.layout)
		ui.item_selection_destroy(&app.sel)
		ui.item_band_destroy(&app.band)
	}

	app.band.user = &app
	app.band.changed = proc(user: rawptr, row: int, now_selected: bool) {
		a := (^Custom_App)(user)
		a.sel_weight += now_selected ? a.weights[row] : -a.weights[row]
	}

	build_custom :: proc(s: ^session.Session) {
		a := (^Custom_App)(s.user)
		em := ui.font_size()
		row_h := ui.dense(em * 1.9)
		a.vl.end_space = row_h * 0.5
		ui.next({width = ui.px(560), height = ui.px(280)})
		rows_info := ui.Item_Rows{count = N, ids = a.ids[:]}
		if rows, ok := ui.vlist("###custom_list", &a.vl, a.ids[:]); ok {
			pressed_row := false
			row_press: ui.Item_Band_Press
			for i in rows.first ..< rows.last {
				selected := ui.item_selection_has(&a.sel, rows_info, i)
				ui.next({width = ui.fill(), height = ui.px(row_h), radius = 0, bg = ui.Color{}})
				sig := ui.list_row(&a.vl, i, fmt.tprintf("entry%02d", i))
				empty_press := a.vl.pressed_empty
				// Custom row painter on the row box must not make the whole row count as content.
				sig.box.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {}
				if ui.parent(sig.box) {
					ui.next({width = ui.table_width(&a.layout, 0), height = ui.pct(1), axis = .X, cross = .Center})
					if ui.row(.Center, {}, "###name_col") {
						ui.spacer(ui.px(8))
						ui.icon("F", 20)
						ui.spacer(ui.px(6))
						ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
						ui.label(fmt.tprintf("entry%02d.txt###name", i))
					}
					_ = ui.table_cell(&a.layout, 1, fmt.tprintf("%d KB", a.weights[i]))
					// Custom decorative bar on the Size cell must not block empty padding hits.
					if cell := ui.parent_box().last; cell != nil {
						cell.custom = proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {}
					}
					ui.table_row_end()
				}
				if empty_press && sig.pointer_pressed && !sig.double_clicked {
					row_press = ui.item_band_row_press(i, sig, selected, true)
					pressed_row = true
				} else if sig.pressed {
					pressed_row = true
					a.drag_fired = false
					// Update running weight to match manual click.
					was := make([]bool, N, context.temp_allocator)
					for k in 0 ..< N { was[k] = ui.item_selection_has(&a.sel, rows_info, k) }
					ui.item_selection_click(&a.sel, rows_info, i, sig.pointer_pressed ? sig.mods : {})
					for k in 0 ..< N {
						now := ui.item_selection_has(&a.sel, rows_info, k)
						if now != was[k] { a.sel_weight += now ? a.weights[k] : -a.weights[k] }
					}
				}
				// Item drag detector (as in a file manager): guarded by band.active || band.pending.
				if sig.dragging && !a.drag_fired && !a.band.active && !a.band.pending {
					th := platform.drag_threshold(s.win)
					if abs(sig.drag_delta.x) >= th.x || abs(sig.drag_delta.y) >= th.y {
						a.drag_fired = true
						a.item_drags += 1
					}
				}
			}
			_ = ui.item_band_update(&a.band, &a.sel, rows_info, ui.parent_box(), {kind = .Rows, vl = &a.vl}, pressed_row, row_press = row_press)
		}
	}
	s := session.start(t, {size = BL_WIN, build = build_custom, user = &app, no_renderer = true})
	session.frames(s, 3)

	row1 := session.get(s, "lrow_1")
	row4 := session.get(s, "lrow_4")
	name1 := session.get(s, "name", within = row1)
	c1 := session.get(s, "c1", within = row1)
	y1 := (row1.rect.min.y + row1.rect.max.y) * 0.5
	y4 := (row4.rect.min.y + row4.rect.max.y) * 0.5

	// 1. Click on empty part of row 2 without dragging -> selects row 2 and updates sel_weight via band.changed.
	row2 := session.get(s, "lrow_2")
	y2 := (row2.rect.min.y + row2.rect.max.y) * 0.5
	session.click_at(s, {name1.rect.min.x + name1.text_dim.x + 80, y2})
	testing.expect_value(t, app.sel.sel, 2)
	testing.expect_value(t, app.sel_weight, 30)
	testing.expect_value(t, app.item_drags, 0)

	// 2. Drag from empty part of row 1 (right of Name) to row 4 -> band selects 1..4, zero item drags, weight matches.
	session.drag(s, {name1.rect.min.x + name1.text_dim.x + 80, y1}, {name1.rect.min.x + name1.text_dim.x + 100, y4})
	testing.expect_value(t, app.item_drags, 0)
	testing.expect_value(t, len(app.sel.selected), 4)
	testing.expect_value(t, app.sel_weight, 20 + 30 + 40 + 50)

	// 3. Drag from empty padding of Size cell (even with custom size-bar draw attached!) -> band selects, no item drag.
	session.drag(s, {c1.rect.min.x + 6, y2}, {c1.rect.min.x + 12, y4})
	testing.expect_value(t, app.item_drags, 0)
	testing.expect_value(t, len(app.sel.selected), 3)
	testing.expect_value(t, app.sel_weight, 30 + 40 + 50)

	// 4. Drag from icon or Name text -> triggers item drag, NOT band!
	session.drag(s, {name1.rect.min.x + 10, y1}, {name1.rect.min.x + 40, y4})
	testing.expect_value(t, app.item_drags, 1)
	testing.expect(t, !app.band.active, "content drag did not start band")
}) }
