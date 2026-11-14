// The path bar (ui.path_bar, docs/path-bar.md) in a window of its own, its folders answered when the test says. What
// breaks first: `wants` said at each frame; an answer for a folder typed before; a ranking at each frame; the dropdown's
// click lost to the focus leaving the field.
//   odin test tests/path_bar -vet -define:ODIN_TEST_THREADS=1 (Linux: -define:FONT_BACKEND=native)
package path_bar_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
App :: struct {
	bar:       ui.Path_Bar,
	path:      string,
	sep:       u8,
	width:     f32,   // the bar's, in pixels (0: the window's)
	gos:       [dynamic]string,
	branch:    bool,  // the last go's
	elsewhere: [dynamic]string,
	wants:     [dynamic]string,
}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	a := runtime.heap_allocator()
	if app.width > 0 { ui.next({width = ui.px(app.width)}) } else { ui.next({width = ui.fill()}) }
	ev := ui.path_bar("###bar", &app.bar, app.path, {separator = app.sep})
	if p, ok := ev.go.?; ok { append(&app.gos, strings.clone(p, a)); app.branch = ev.branch }
	if p, ok := ev.open_elsewhere.?; ok { append(&app.elsewhere, strings.clone(p, a)) }
	if p, ok := ev.wants.?; ok { append(&app.wants, strings.clone(p, a)) }
}

@(private = "file")
app_destroy :: proc(app: ^App) {
	a := runtime.heap_allocator()
	for x in app.gos { delete(x, a) }
	for x in app.elsewhere { delete(x, a) }
	for x in app.wants { delete(x, a) }
	delete(app.gos)
	delete(app.elsewhere)
	delete(app.wants)
	ui.path_bar_destroy(&app.bar)
}

@(private = "file")
start :: proc(t: ^testing.T, app: ^App, path: string, sep: u8 = '/') -> ^session.Session {
	app.path, app.sep = path, sep
	s := session.start(t, {build = build, user = app, no_renderer = true, size = {900, 500}})
	session.frames(s, 3)   // (laid out: the parts measured by the last layout)
	return s
}

@(private = "file")
last_want :: proc(app: ^App) -> string { return len(app.wants) > 0 ? app.wants[len(app.wants) - 1] : "" }

// The children of /home/a, in their order, answered as the children of `folder` (the bar copies them).
@(private = "file")
answer_home_a :: proc(app: ^App, folder: string) {
	children := []ui.Path_Bar_Entry{{name = "build", branch = true}, {name = "docs", branch = true}, {name = "notes.txt"}}
	ui.path_bar_children(&app.bar, folder, children)
}

// The address mode on /home/a/b, the text replaced by "/home/a/", the children of /home/a answered.
@(private = "file")
typed_home_a :: proc(s: ^session.Session, app: ^App) {
	session.click(s, "pb_edit")
	session.type_text(s, "/home/a/")
	answer_home_a(app, "/home/a")
	session.frames(s, 2)
}

// The row of the dropdown that shows `text` (a child's name, a suggestion's path), -1 when none does.
@(private = "file")
row_named :: proc(app: ^App, text: string) -> int {
	for r, i in app.bar.rows {
		#partial switch r.kind {
		case .Child:      if app.bar.children[r.index].name == text { return i }
		case .Suggestion: if app.bar.suggested[r.index].path == text { return i }
		}
	}
	return -1
}

// "/home/a/b": the root as itself, a part a button, a faint "/" between two parts but after the root. "C:\x": "C:",
// then a "/".
@(test)
the_parts_of_a_path :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	for name in ([]string{"pb_part_0", "pb_part_1", "pb_part_2", "pb_part_3"}) { testing.expectf(t, session.find(s, name) != nil, "%s", name) }
	testing.expect(t, session.find(s, "pb_part_4") == nil)
	testing.expect(t, session.find(s, "pb_more") == nil, "everything fits")
	testing.expect(t, session.find(s, "pb_sep_1") == nil, "no glyph after the root: it is one")
	testing.expect(t, session.find(s, "pb_sep_2") != nil, "after home")
	testing.expect(t, session.find(s, "pb_sep_3") != nil, "after a")
	testing.expect(t, session.find(s, "pb_sep_4") == nil, "none after the last")
	if b := session.find(s, "pb_sep_2"); b != nil { testing.expect_value(t, ui.box_text(b), "/") }
	testing.expect(t, session.find_text(s, "home") != nil)
	app.path, app.sep = "C:\\x", '\\'
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "C:") != nil, "the root as itself")
	testing.expect(t, session.find(s, "pb_part_1") != nil)
	testing.expect(t, session.find(s, "pb_part_2") == nil)
	if b := session.find(s, "pb_sep_1"); testing.expect(t, b != nil, "a / after C:") { testing.expect_value(t, ui.box_text(b), "/") }
}

// A click on a part goes to its path; a middle click says it, to open elsewhere.
@(test)
a_part_goes_there :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	session.click(s, "pb_part_2")
	if testing.expect_value(t, len(app.gos), 1) { testing.expect_value(t, app.gos[0], "/home/a") }
	testing.expect(t, app.branch, "a part is a folder")
	testing.expect(t, !app.bar.editing)
	session.click(s, "pb_part_1", button = .Middle)
	if testing.expect_value(t, len(app.elsewhere), 1) { testing.expect_value(t, app.elsewhere[0], "/home") }
	testing.expect_value(t, len(app.gos), 1)
}

// A click on the empty part: the field, the whole path selected, with the keyboard.
@(test)
the_empty_part_types :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	session.click(s, "pb_edit")
	testing.expect(t, app.bar.editing)
	testing.expect_value(t, session.focused_name(s), "pb_field")
	testing.expect_value(t, ui.line_edit_string(&app.bar.field), "/home/a/b")
	testing.expect_value(t, app.bar.field.mark, 0)
	testing.expect_value(t, app.bar.field.cursor, len("/home/a/b"))
}

// `wants` is said once per folder, whatever the frames; a folder typed says it again, once.
@(test)
wants_is_said_once :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	session.click(s, "pb_edit")
	session.frames(s, 30)
	if testing.expect_value(t, len(app.wants), 1) { testing.expect_value(t, app.wants[0], "/home/a/b") }
	session.type_text(s, "/home/a/")
	session.frames(s, 30)
	if testing.expect_value(t, len(app.wants), 2) { testing.expect_value(t, app.wants[1], "/home/a") }
	session.type_text(s, "do")   // (the same folder)
	session.frames(s, 30)
	testing.expect_value(t, len(app.wants), 2)
}

// Children answered late are shown; an answer for another folder is dropped. A quiet frame ranks nothing.
@(test)
a_late_answer_and_another_folders :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	session.click(s, "pb_edit")
	session.type_text(s, "/home/a/")
	session.frames(s, 5)
	answer_home_a(&app, "/elsewhere")
	session.frames(s, 2)
	testing.expect_value(t, len(app.bar.children), 0)
	testing.expect(t, session.find_text(s, "docs") == nil, "another folder's answer shows nothing")
	answer_home_a(&app, "/home/a/")   // (its separator at its end: the same folder)
	session.frames(s, 2)
	testing.expect_value(t, len(app.bar.children), 3)
	testing.expect(t, session.find_text(s, "docs") != nil)
	ranked := app.bar.ranked
	session.frames(s, 20)
	testing.expect_value(t, app.bar.ranked, ranked)
}

// The children are ranked against what follows the last separator: "do" finds docs, not build; d and o lit.
@(test)
typing_ranks_the_children :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	typed_home_a(s, &app)
	testing.expect(t, row_named(&app, "build") >= 0, "nothing typed: every child")
	session.type_text(s, "do")
	testing.expect(t, row_named(&app, "build") < 0, "build has no o after its d")
	r := row_named(&app, "docs")
	if !testing.expect_value(t, r, 0) { return }
	ranges := app.bar.rows[r].ranges
	if testing.expect_value(t, len(ranges), 1) { testing.expect_value(t, ranges[0], ui.Fuzzy_Range{0, 2}) }
}

// Tab: the best row; a branch gets its separator, and the next level is asked.
@(test)
tab_completes_a_branch :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	typed_home_a(s, &app)
	session.type_text(s, "do")
	session.key(s, .Tab)
	testing.expect_value(t, ui.line_edit_string(&app.bar.field), "/home/a/docs/")
	testing.expect_value(t, last_want(&app), "/home/a/docs")
	testing.expect(t, app.bar.editing, "Tab stays in the field")
}

// Down highlights the first row, Enter goes there; nothing highlighted, Enter goes to the text typed.
@(test)
enter_goes_to_the_row_or_the_text :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	typed_home_a(s, &app)
	session.key(s, .Down)
	session.key(s, .Return)
	if testing.expect_value(t, len(app.gos), 1) { testing.expect_value(t, app.gos[0], "/home/a/build") }
	testing.expect(t, app.branch)
	testing.expect(t, !app.bar.editing, "the breadcrumb again")
	session.click(s, "pb_edit")
	session.type_text(s, "/tmp/x")
	session.key(s, .Return)
	if testing.expect_value(t, len(app.gos), 2) { testing.expect_value(t, app.gos[1], "/tmp/x") }
	testing.expect(t, !app.branch, "a text typed")
}

// A click on a row goes there: the press on the dropdown leaves the field its keyboard.
@(test)
a_click_on_a_row :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	typed_home_a(s, &app)
	r := row_named(&app, "docs")
	if !testing.expect(t, r >= 0) { return }
	session.click_text(s, "docs")
	if testing.expect_value(t, len(app.gos), 1) { testing.expect_value(t, app.gos[0], "/home/a/docs") }
}

// Escape closes the dropdown, the second Escape gives the breadcrumb back, going nowhere.
@(test)
escape_twice :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	typed_home_a(s, &app)
	session.key(s, .Escape)
	testing.expect(t, app.bar.editing)
	testing.expect(t, !app.bar.open, "the dropdown closed")
	session.key(s, .Escape)
	testing.expect(t, !app.bar.editing)
	testing.expect_value(t, len(app.gos), 0)
	testing.expect(t, session.find(s, "pb_part_3") != nil, "the breadcrumb")
}

// The program's suggestions under their group's title; at first (the path as it came) nothing filters them.
@(test)
suggestions_under_their_titles :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	s := start(t, &app, "/home/a/b")
	places := []ui.Path_Bar_Entry{{name = "Documents", path = "/home/me/Documents", detail = "Documents", branch = true}}
	groups := []ui.Path_Bar_Group{{title = "Places", entries = places}}
	ui.path_bar_suggestions(&app.bar, groups)
	session.click(s, "pb_edit")
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "Places") != nil, "the group's title")
	testing.expect(t, row_named(&app, "/home/me/Documents") >= 0)
	session.type_text(s, "zzz")
	testing.expect(t, row_named(&app, "/home/me/Documents") < 0, "what does not match goes")
	testing.expect(t, session.find_text(s, "Places") == nil, "and its title")
}

// A narrow bar: the leading parts go into "…", whose menu lists them.
@(test)
a_narrow_bar_collapses :: proc(t: ^testing.T) {
	app: App
	defer app_destroy(&app)
	app.width = 260
	s := start(t, &app, "/home/someone/projects/toolkit/documentation")
	testing.expect(t, session.find(s, "pb_more") != nil, "the …")
	testing.expect(t, session.find(s, "pb_part_5") != nil, "the last part always")
	testing.expect(t, session.find(s, "pb_part_0") == nil, "the root is in the …")
	session.click(s, "pb_more")
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "someone") != nil, "the menu lists the parts above")
	session.click_text(s, "someone")
	if testing.expect_value(t, len(app.gos), 1) { testing.expect_value(t, app.gos[0], "/home/someone") }
}
