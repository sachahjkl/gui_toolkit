// The table of texts (ui.Table): sort by a title's click, reverse, filter, the selection kept by identity, a column
// resized by its rule, a cut cell's tooltip; type_to_field (typing anywhere goes to the filter, not when another field
// has the keyboard); a segment's tooltip.
//   odin test tests/data_views -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package data_views_test

import "core:testing"
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
	// another field keeps what is typed in it
	session.click(s, "other")
	session.type_text(s, "x")
	testing.expect_value(t, ui.field_string(&app.other), "x")
	testing.expect_value(t, ui.field_string(&app.search), "BR")
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
