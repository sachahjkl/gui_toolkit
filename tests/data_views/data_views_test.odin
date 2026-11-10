// The table of texts (ui.Table): sort by a title's click, reverse, filter, the selection kept by identity, a column
// resized by its rule, a cut cell's tooltip; type_to_field (typing anywhere goes to the filter, not when another field
// has the keyboard); a segment's tooltip.
//   odin test tests/data_views -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:fmt"
import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

// The table's room; a cell's text that is longer than its column.
@(private = "file") TABLE_W :: 450
@(private = "file") LONG_TEXT :: "a description much longer than its column can show at this width"
// The rule of column 1, dragged right by this much at 15 px per em: the column 2 ems narrower.
@(private = "file") DRAG_PX :: 30
@(private = "file") TIP_WAIT_MS :: 600

@(private = "file")
COLUMNS := [?]ui.Table_Column{
	{title = "Name", width = 10},
	{title = "Size", width = 6, number = true},
	{title = "Notes", width = 0, weak = true},
	{title = "ID", width = 4, number = true, low_first = true},
}

@(private = "file")
App :: struct {
	t:          ui.Table,
	d:          ui.Table_Data,
	search:     ui.Text_Field,
	other:      ui.Text_Field,
	search_key: ui.Key,
	ev:         ui.Table_Events,
	seg:        int,
}

@(private = "file")
app_init :: proc(app: ^App) {
	ui.table_init(&app.t, COLUMNS[:])
	ui.table_data_reset(&app.d, len(COLUMNS))
	rows := [?]struct { id: u64, name: string, size: f64, notes: string }{
		{1, "delta", 40, "d"}, {2, "Alpha", 10, "a"}, {3, "charlie", 30, LONG_TEXT}, {4, "bravo", 20, "b"}, {5, "echo##x", 50, "e"},
	}
	for r in rows {
		ui.table_data_row(&app.d, r.id, r.name)
		ui.table_data_cell(&app.d, r.name)
		ui.table_data_cell(&app.d, "n", r.size)
		ui.table_data_cell(&app.d, r.notes)
		ui.table_data_cell(&app.d, "i", f64(r.id))
	}
	ui.table_apply(&app.t, &app.d, "")
}

@(private = "file")
app_destroy :: proc(app: ^App) {
	ui.table_destroy(&app.t)
	ui.table_data_destroy(&app.d)
	ui.field_destroy(&app.search)
	ui.field_destroy(&app.other)
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	ui.type_to_field(app.search_key)
	ui.next({width = ui.px(200), height = ui.px(30)})
	app.search_key = ui.line_edit("###search", &app.search).box.key
	if app.t.query != ui.field_string(&app.search) { ui.table_apply(&app.t, &app.d, ui.field_string(&app.search)) }
	ui.next({width = ui.px(200), height = ui.px(30)})
	ui.line_edit("###other", &app.other)
	ui.next({width = ui.px(300), height = ui.px(30)})
	ui.segmented("###mode", {"System", "User"}, &app.seg, {"The system's services", ""})
	ui.next({width = ui.px(TABLE_W), height = ui.px(300)})
	ev := ui.table_build("###table", &app.t, &app.d, "Nothing here")
	if ev.sorted { ui.table_apply(&app.t, &app.d, ui.field_string(&app.search)) }
	if ev.sorted || ev.resized { app.ev = ev }
}

@(private = "file")
first_name :: proc(app: ^App) -> string { return ui.table_data_text(&app.d, app.t.order[0], 0) }

@(test)
a_table_sorts_filters_and_keeps_its_selection :: proc(t: ^testing.T) {
	app: App
	app_init(&app)
	defer app_destroy(&app)
	s := session.start(t, {build = build, user = &app, no_renderer = true})
	testing.expect_value(t, first_name(&app), "Alpha")   // A to Z, case ignored
	session.click(s, "hd_1")
	testing.expect(t, app.ev.sorted)
	testing.expect_value(t, first_name(&app), "echo##x")   // a number: largest first at the first click
	session.click(s, "hd_1")
	testing.expect_value(t, first_name(&app), "Alpha")
	// an id: from the lowest at the first click
	session.click(s, "hd_3")
	testing.expect_value(t, first_name(&app), "delta")
	testing.expect(t, !app.t.descending)
	// a row selected stays selected through a sort
	session.click(s, "lrow_2")
	testing.expect_value(t, ui.table_data_text(&app.d, ui.table_selected(&app.t), 0), "charlie")
	session.click(s, "hd_0")
	testing.expect_value(t, ui.table_data_text(&app.d, ui.table_selected(&app.t), 0), "charlie")
	// typing with the list's keyboard: the filter takes it, and its first row is selected
	testing.expect(t, session.focused_name(s) != "search")
	session.type_text(s, "BR")
	testing.expect_value(t, session.focused_name(s), "search")
	testing.expect_value(t, ui.field_string(&app.search), "BR")
	testing.expect_value(t, len(app.t.order), 1)
	testing.expect_value(t, ui.table_data_text(&app.d, ui.table_selected(&app.t), 0), "bravo")
	// a shortcut's letter is not typing: Alt+P gives the text "p" too, the filter does not take it
	session.click(s, "lrow_0")
	session.event(s, {kind = .Key_Press, key = .P, mods = {.Alt}})
	session.event(s, {kind = .Text, text = 'p'})
	session.event(s, {kind = .Key_Release, key = .P, mods = {.Alt}})
	session.frames(s, 2)
	testing.expect(t, session.focused_name(s) != "search", "Alt+P does not go to the filter")
	testing.expect_value(t, ui.field_string(&app.search), "BR")
	// text with no key press after a shortcut (an input method's) is typing again
	session.key(s, .U, {.Ctrl})
	session.type_text(s, "o")
	testing.expect_value(t, session.focused_name(s), "search")
	testing.expect_value(t, ui.field_string(&app.search), "BRo")
	// another field keeps what is typed in it
	session.click(s, "other")
	session.type_text(s, "x")
	testing.expect_value(t, ui.field_string(&app.other), "x")
	testing.expect_value(t, ui.field_string(&app.search), "BRo")
}

@(test)
a_table_column_is_resized_and_a_cut_cell_shows_its_text :: proc(t: ^testing.T) {
	app: App
	app_init(&app)
	defer app_destroy(&app)
	s := session.start(t, {build = build, user = &app, no_renderer = true})
	before := app.t.width[1]
	rule := session.center(session.get(s, "rule"))
	session.drag(s, rule, rule + {DRAG_PX, 0})
	testing.expect(t, app.ev.resized)
	testing.expect(t, abs(app.t.width[1] - (before - DRAG_PX / session.BASE_FONT_SIZE)) < 0.01, "the column narrower")
	// the long note is cut: resting on it shows it whole
	ui.table_select_id(&app.t, 3)
	session.frame(s)
	session.hover(s, "c2")
	cell := session.find_text(s, LONG_TEXT)
	testing.expect(t, cell != nil)
	session.move(s, session.center(cell))
	session.advance(s, TIP_WAIT_MS)
	tip := session.get(s, "tooltip_text")
	testing.expect_value(t, ui.box_text(tip), LONG_TEXT)
}

@(test)
a_segment_has_its_tooltip :: proc(t: ^testing.T) {
	app: App
	app_init(&app)
	defer app_destroy(&app)
	s := session.start(t, {build = build, user = &app, no_renderer = true})
	session.hover(s, "seg0")
	session.advance(s, TIP_WAIT_MS)
	testing.expect_value(t, ui.box_text(session.get(s, "tooltip_text")), "The system's services")
	session.hover(s, "seg1")
	session.advance(s, TIP_WAIT_MS)
	testing.expect(t, session.find(s, "tooltip_text") == nil, "no tooltip for an empty one")
}

// A list of rows the program builds (vlist and list_row), with marks: Ctrl and Shift clicks, Ctrl+A, a filter.
@(private = "file")
Marks_App :: struct {
	vl:   ui.Virtual_List,
	ids:  [dynamic]u64,
}

@(private = "file")
marks_build :: proc(s: ^session.Session) {
	app := (^Marks_App)(s.user)
	app.vl.multi = true
	ui.next({width = ui.px(TABLE_W), height = ui.px(300)})
	if rows, ok := ui.vlist("###rows", &app.vl, app.ids[:]); ok {
		for i in rows.first ..< rows.last {
			ui.next({height = ui.px(24)})
			ui.list_row(&app.vl, i, "")
		}
	}
}

// A click on row `i` with modifiers held.
@(private = "file")
row_click :: proc(s: ^session.Session, i: int, mods: platform.Modifiers = {}) {
	at := session.center(session.get(s, fmt.tprintf("lrow_%d", i)))
	session.move(s, at)
	s.buttons += {.Left}
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = at, mods = mods})
	session.frame(s)
	s.buttons -= {.Left}
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = at, mods = mods})
	session.frames(s, 3)
}

@(test)
rows_are_marked_by_ctrl_and_shift_clicks :: proc(t: ^testing.T) {
	app: Marks_App
	defer { ui.vlist_destroy(&app.vl); delete(app.ids) }
	for id in ([]u64{10, 11, 12, 13, 14, 15}) { append(&app.ids, id) }
	s := session.start(t, {build = marks_build, user = &app, no_renderer = true})
	row_click(s, 1)
	testing.expect(t, app.vl.sel == 1 && ui.list_mark_count(&app.vl) == 0, "a click alone: the active row, no mark")
	row_click(s, 3, {.Ctrl})
	testing.expect(t, ui.list_is_marked(&app.vl, 1) && ui.list_is_marked(&app.vl, 3) && ui.list_mark_count(&app.vl) == 2, "Ctrl: the active row and this one")
	row_click(s, 1, {.Ctrl})
	testing.expect(t, !ui.list_is_marked(&app.vl, 1) && ui.list_mark_count(&app.vl) == 1, "Ctrl again: unmarked")
	row_click(s, 5, {.Shift})
	// (the last row clicked is row 1, Ctrl's: rows 1 to 5)
	testing.expect(t, ui.list_mark_count(&app.vl) == 5 && ui.list_is_marked(&app.vl, 1) && ui.list_is_marked(&app.vl, 5) && !ui.list_is_marked(&app.vl, 0), "Shift: from the last row clicked")
	// the marks follow the rows' identities: row 13 moved to the end is still marked; a row gone is not
	ordered_remove(&app.ids, 3)
	append(&app.ids, 13)
	ordered_remove(&app.ids, 3)   // (14: gone)
	session.frames(s, 2)
	testing.expect(t, ui.list_mark_count(&app.vl) == 4 && ui.list_is_marked(&app.vl, len(app.ids) - 1), "by identity")
	row_click(s, 0)
	testing.expect_value(t, ui.list_mark_count(&app.vl), 0)
	session.key(s, .A, {.Ctrl})
	testing.expect_value(t, ui.list_mark_count(&app.vl), len(app.ids))
	session.key(s, .Down)
	testing.expect_value(t, ui.list_mark_count(&app.vl), 0)
}

@(test)
a_layout_as_text_and_back :: proc(t: ^testing.T) {
	keys := []string{"name", "size", "notes", "id"}
	l: ui.Table_Layout
	ui.table_layout_init(&l, COLUMNS[:])
	defer ui.table_layout_destroy(&l)
	testing.expect_value(t, ui.table_widths_text(&l, keys), "")
	l.width[1] = 9
	l.sort, l.descending = 3, true
	widths, sort := ui.table_widths_text(&l, keys), ui.table_sort_text(&l, keys)
	testing.expect_value(t, widths, "size=9.0")
	testing.expect_value(t, sort, "-id")
	m: ui.Table_Layout
	ui.table_layout_init(&m, COLUMNS[:])
	defer ui.table_layout_destroy(&m)
	ui.table_widths_apply(&m, keys, "size=9.0,notes=12,nothing=4,id=x,name=1000")
	testing.expect(t, m.width[1] == 9 && m.width[2] == 0 && m.width[3] == COLUMNS[3].width, "a width read; the room-left column and the bad ones skipped")
	testing.expect_value(t, m.width[0], ui.TABLE_COLUMN_MAX_EM)
	ui.table_sort_apply(&m, keys, sort)
	testing.expect(t, m.sort == 3 && m.descending, "the sort read")
	ui.table_sort_apply(&m, keys, "unknown")
	testing.expect_value(t, m.sort, 3)
}

@(private = "file") HEAT_BG :: ui.Color{0.8, 0.1, 0.1, 1}
@(private = "file") HEAT_FG :: ui.Color{1, 1, 1, 1}

@(private = "file")
Heat_App :: struct { l: ui.Table_Layout }

@(private = "file")
build_heat :: proc(s: ^session.Session) {
	app := (^Heat_App)(s.user)
	ui.next({width = ui.px(TABLE_W), height = ui.px(30), axis = .X})
	if ui.row(id = "###heat_row") {
		ui.table_cell(&app.l, 0, "busy", HEAT_BG, HEAT_FG)
		ui.table_cell(&app.l, 1, "plain")
	}
}

@(test)
a_cell_has_its_background_and_its_text_colour :: proc(t: ^testing.T) {
	app: Heat_App
	ui.table_layout_init(&app.l, COLUMNS[:2])
	defer ui.table_layout_destroy(&app.l)
	s := session.start(t, {build = build_heat, user = &app, no_renderer = true})
	session.advance(s, 1000)   // (colours approach their targets)
	busy := session.find_text(s, "busy")
	testing.expect(t, busy != nil)
	if busy == nil { return }
	testing.expect_value(t, busy.bg, HEAT_BG)
	testing.expect_value(t, busy.text_color, HEAT_FG)
	plain := session.find_text(s, "plain")
	testing.expect(t, plain != nil && plain.text_color != HEAT_FG, "a cell with no colour keeps the theme's")
}

@(private = "file") CELL_BORDER :: ui.Color{0.5, 0.05, 0.05, 1}

@(private = "file")
build_striped :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	app.t.vl.zebra, app.t.vl.rules = true, true
	ui.next({width = ui.px(TABLE_W), height = ui.px(300)})
	ui.table_build("###table", &app.t, &app.d, "")
	ui.next({width = ui.px(TABLE_W), height = ui.px(30), axis = .X})
	if ui.row(id = "###bordered") { ui.table_cell(&app.t.layout, 1, "outlined", HEAT_BG, HEAT_FG, CELL_BORDER) }
}

@(test)
rows_in_stripes_with_a_rule_under_each :: proc(t: ^testing.T) {
	app: App
	app_init(&app)
	defer app_destroy(&app)
	app.t.vl.sel = -1
	s := session.start(t, {build = build_striped, user = &app, no_renderer = true})
	session.advance(s, 1000)
	even, odd := session.find(s, "lrow_2"), session.find(s, "lrow_3")
	testing.expect(t, even != nil && odd != nil)
	if even == nil || odd == nil { return }
	testing.expect(t, .Draw_Background not_in even.flags && .Draw_Background in odd.flags && odd.bg.a > 0, "every second row is shaded")
	testing.expect(t, .Draw_Side_Bottom in even.flags && .Draw_Side_Bottom in odd.flags && even.border.a > 0, "a rule under each row")
	cell := session.find_text(s, "outlined")
	testing.expect(t, cell != nil && .Draw_Border in cell.flags && cell.border == CELL_BORDER, "a cell's outline")
}

@(private = "file") ROW_TINT :: ui.Color{0.2, 0.7, 0.3, 0.5}

@(private = "file")
Tint_App :: struct { vl: ui.Virtual_List, ids: [4]u64, animations: bool }

@(private = "file")
build_tinted :: proc(s: ^session.Session) {
	app := (^Tint_App)(s.user)
	app.vl.zebra = true
	app.animations = ui.animations_on()
	ui.next({width = ui.px(TABLE_W), height = ui.px(200)})
	if rows, ok := ui.vlist("###tinted", &app.vl, app.ids[:]); ok {
		for i in rows.first ..< rows.last {
			ui.next({height = ui.px(20)})
			ui.list_row(&app.vl, i, "row", tint = i == 1 ? ROW_TINT : nil)
		}
	}
}

@(test)
a_row_tinted_in_place_of_its_stripe :: proc(t: ^testing.T) {
	app := Tint_App{ids = {11, 12, 13, 14}}
	app.vl.sel = -1
	defer ui.vlist_destroy(&app.vl)
	s := session.start(t, {build = build_tinted, user = &app, no_renderer = true})
	session.advance(s, 1000)
	row := session.find(s, "lrow_1")
	testing.expect(t, row != nil && .Draw_Background in row.flags && row.bg == ROW_TINT, "the tint is the row's background")
	// (a session's window animates nothing: values jump, as when the desktop asks for less motion)
	testing.expect(t, !app.animations, "animations_on says so")
}
