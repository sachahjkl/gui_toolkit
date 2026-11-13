package scenarios_test

// Editing text: a line edit and a text area, by the keyboard and the mouse, the undo steps by the session's clock, the caret by its pixels.

import "core:strings"
import "core:testing"
import "../../src/font"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

// A stretch of the clock longer than what merges typing into one undo step (ui.Feel.undo_merge_ms).
@(private = "file") PAUSE_OVER_MERGE_MS :: 2000
// The frames a caret takes to blink off, at most, once it is solid no longer (1200 ms).
@(private = "file") CARET_FRAMES :: 72
@(private = "file") FIELD_WIDTH :: 400
@(private = "file") AREA_SIZE :: [2]f32{300, 200}
@(private = "file") AREA_NARROW :: 200
@(private = "file") LONG_LINES :: 40

@(private = "file")
Editors :: struct {
	field:  ui.Text_Field,
	secret: ui.Text_Field,
	shown:  ui.Text_Field,   // a secret that can be revealed
	search: ui.Text_Field,   // a clearable one
	reveal: bool,
	area:   ui.Text_Area,
	grow:   ui.Text_Area,
	result: ui.Edit_Result,
}

@(private = "file")
editors_build :: proc(s: ^session.Session) {
	e := (^Editors)(s.user)
	ui.next({width = ui.px(FIELD_WIDTH)})
	e.result = ui.line_edit("###field", &e.field)
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###secret", &e.secret, secret = true)
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###shown", &e.shown, secret = true, reveal = &e.reveal)
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###search", &e.search, clearable = true)
	ui.next({width = ui.px(AREA_SIZE.x), height = ui.px(AREA_SIZE.y)})
	ui.text_edit("###area", &e.area, tab_indents = true)
	ui.next({width = ui.px(AREA_NARROW)})
	ui.text_edit("###grow", &e.grow, wrap = true, auto_height = true, min_lines = 1, max_lines = 4)
}

@(private = "file")
editors_start :: proc(t: ^testing.T, no_renderer := true, loc := #caller_location) -> (^session.Session, ^Editors) {
	e := new(Editors)   // (a cleanup runs after the test's procedure has returned)
	testing.cleanup(t, proc(p: rawptr) {
		e := (^Editors)(p)
		ui.field_destroy(&e.field)
		ui.field_destroy(&e.secret)
		ui.field_destroy(&e.shown)
		ui.field_destroy(&e.search)
		ui.area_destroy(&e.area)
		ui.area_destroy(&e.grow)
		free(e)
	}, e)
	return session.start(t, {build = editors_build, user = e, no_renderer = no_renderer}, loc), e
}

@(test)
a_line_edit_moves_selects_and_deletes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.click(s, "field")
	session.type_text(s, "hello brave world")
	testing.expect_value(t, e.field.cursor, len("hello brave world"))
	session.key(s, .Left, {.Ctrl})
	testing.expect_value(t, e.field.cursor, len("hello brave "))
	session.key(s, .Backspace, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "hello world")
	session.key(s, .Home)
	testing.expect_value(t, e.field.cursor, 0)
	session.key(s, .Right, {.Shift}, repeat = 5)
	testing.expect_value(t, ui.field_selection(&e.field), "hello")
	session.type_text(s, "bye")
	testing.expect_value(t, ui.field_string(&e.field), "bye world")
	session.key(s, .Left, {.Ctrl})
	session.key(s, .Delete, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), " world")
	session.key(s, .End)
	session.key(s, .Left, {.Ctrl, .Shift})
	testing.expect_value(t, ui.field_selection(&e.field), "world")
}) }

// A character of several code points is one step for the caret and for Backspace.
@(test)
a_line_edit_moves_by_graphemes :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.click(s, "field")
	flag := "\U0001F1EB\U0001F1F7"   // two regional indicators: one flag
	session.type_text(s, strings.concatenate({"a", flag, "b"}, context.temp_allocator))
	session.key(s, .Left)
	testing.expect_value(t, e.field.cursor, 1 + len(flag))
	session.key(s, .Left)
	testing.expect_value(t, e.field.cursor, 1)
	session.key(s, .Right)
	session.key(s, .Backspace)
	testing.expect_value(t, ui.field_string(&e.field), "ab")
}) }

// Enter says committed, Esc cancelled and the focus goes.
@(test)
a_line_edit_says_committed_and_cancelled :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	e: Editors
	s := session.start(t, {user = &e, no_renderer = true, build = proc(s: ^session.Session) {
		e := (^Editors)(s.user)
		e.result = ui.line_edit("###field", &e.field)
		if e.result.committed { ui.field_set(&e.field, "done") }
	}})
	defer ui.field_destroy(&e.field)
	session.click(s, "field")
	session.type_text(s, "x")
	session.key(s, .Return)
	testing.expect_value(t, ui.field_string(&e.field), "done")
	testing.expect_value(t, session.focused_name(s), "field")
	session.key(s, .Escape)
	testing.expect_value(t, session.focused_name(s), "")
}) }

// What is typed in one go is one undo step; after a pause, another. By the session's clock: the merging must not read the system's.
@(test)
undo_steps_go_by_the_clock :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.click(s, "field")
	session.type_slowly(s, "one")
	session.advance(s, PAUSE_OVER_MERGE_MS)
	session.type_slowly(s, "two")
	testing.expect_value(t, ui.field_string(&e.field), "onetwo")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "one")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "")
	session.key(s, .Y, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "one")
	session.key(s, .Z, {.Ctrl, .Shift})
	testing.expect_value(t, ui.field_string(&e.field), "onetwo")
}) }

@(test)
cut_copy_paste_through_the_clipboard :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.click(s, "field")
	session.type_text(s, "take me")
	session.key(s, .A, {.Ctrl})
	session.key(s, .X, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "")
	testing.expect_value(t, session.clipboard(s), "take me")
	session.key(s, .V, {.Ctrl})
	session.key(s, .V, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "take metake me")
	// a line edit has one line: what is pasted has none other
	session.set_clipboard(s, "a\nb")
	session.key(s, .A, {.Ctrl})
	session.key(s, .V, {.Ctrl})
	testing.expect(t, !strings.contains(ui.field_string(&e.field), "\n"), "no line break in a line edit")
}) }

// Ctrl+V in one frame: the key, and nothing after it (the build that sees it asks the clipboard).
@(private = "file")
ctrl_v_one_frame :: proc(s: ^session.Session) {
	session.event(s, {kind = .Key_Press, key = .V, mods = {.Ctrl}})
	session.event(s, {kind = .Key_Release, key = .V, mods = {.Ctrl}})
	session.frame(s)
}

// A paste does not wait for the clipboard: the build of Ctrl+V asks, and the text comes in a later one (the window's
// clipboard_request), in one undo step, to the field or the editor that asked.
@(test)
a_paste_comes_in_a_later_build :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.set_clipboard(s, "pasted")
	session.click(s, "field")
	session.type_text(s, "ab")
	ctrl_v_one_frame(s)
	testing.expect_value(t, ui.field_string(&e.field), "ab")
	session.wait_until(s, e, proc(s: ^session.Session, e: ^Editors) -> bool { return ui.field_string(&e.field) == "abpasted" }, "the field's paste")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.field), "ab")
	// the editor: the same, its line ends kept
	session.set_clipboard(s, "one\ntwo")
	session.click(s, "area")
	ctrl_v_one_frame(s)
	testing.expect_value(t, ui.area_string(&e.area), "")
	session.wait_until(s, e, proc(s: ^session.Session, e: ^Editors) -> bool { return ui.area_string(&e.area) == "one\ntwo" }, "the editor's paste")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.area_string(&e.area), "")
}) }

// An answer that comes when the field that asked has lost the focus is dropped: neither it nor the focused one takes it.
@(test)
a_paste_for_a_field_left_is_dropped :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.set_clipboard(s, "late")
	session.click(s, "field")
	session.type_text(s, "ab")
	ctrl_v_one_frame(s)
	ui.set_focus(session.get(s, "search").key)   // (before the build the answer comes in)
	// (the process's store answers at the next poll: the frame after the request has it)
	session.frames(s, 2)
	testing.expect_value(t, ui.field_string(&e.field), "ab")
	testing.expect_value(t, ui.field_string(&e.search), "")
	session.click(s, "field")
	session.frames(s, 2)
	testing.expect_value(t, ui.field_string(&e.field), "ab")
}) }

// A right click on a field opens its menu, an icon on each item: Paste puts the clipboard at the caret, Cut takes the
// selection, and a secret's menu neither copies nor cuts.
@(test)
a_field_has_a_menu :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.set_clipboard(s, "XY")
	session.click(s, "field")
	session.type_text(s, "ab")
	session.click(s, "field", .Right)
	session.frames(s, 2)
	testing.expect(t, ui.ctx_menu_any_open(), "a right click opens it")
	// a menu, not a field's: its own tags (the field's made its panel see-through)
	panel := s.state.boxes[s.state.menus[0].panel]
	if testing.expect(t, panel != nil, "its panel") {
		tags := s.state.tag_sets[panel.tags_key]
		testing.expectf(t, len(tags) == 1 && tags[0] == "floating", "its own tags, not the field's: %v", tags)
	}
	icons := 0
	for i := 0; session.find(s, "ico", i) != nil; i += 1 { icons += 1 }
	testing.expectf(t, icons == 7, "an icon on each item: %d", icons)
	session.click_text(s, "Paste")
	session.frames(s, 2)
	testing.expect_value(t, ui.field_string(&e.field), "abXY")
	testing.expect(t, !ui.ctx_menu_any_open(), "chosen: it closes")
	session.key(s, .A, {.Ctrl})
	session.click(s, "field", .Right)
	session.frames(s, 2)
	session.click_text(s, "Cut")
	session.frames(s, 2)
	testing.expect_value(t, ui.field_string(&e.field), "")
	testing.expect_value(t, session.clipboard(s), "abXY")
	// a secret's: no copy, no cut
	session.click(s, "secret")
	session.type_text(s, "pw")
	session.key(s, .A, {.Ctrl})
	session.click(s, "secret", .Right)
	session.frames(s, 2)
	session.click_text(s, "Copy")
	session.frames(s, 2)
	testing.expect_value(t, session.clipboard(s), "abXY")
	session.key(s, .Escape)
}) }

// A clearable field has a cross while it holds text: it empties it, the field keeps the keyboard, and Undo brings the text back.
@(test)
a_clearable_field_has_a_cross :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	testing.expect(t, session.find(s, "clear") == nil, "empty: no cross")
	session.click(s, "search")
	session.type_text(s, "needle")
	session.frames(s, 2)
	testing.expect(t, session.find(s, "clear") != nil, "the cross")
	session.click(s, "clear")
	session.frames(s, 2)
	testing.expect_value(t, ui.field_string(&e.search), "")
	testing.expect(t, session.find(s, "clear") == nil, "emptied: no cross")
	testing.expect_value(t, ui.focus_key(), session.find(s, "search").key)
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.field_string(&e.search), "needle")
}) }

// A secret field shows no text and gives none away.
@(test)
a_secret_field_does_not_copy :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.set_clipboard(s, "before")
	session.click(s, "secret")
	session.type_text(s, "hunter2")
	session.key(s, .A, {.Ctrl})
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "before")
	session.key(s, .X, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "before")
	testing.expect_value(t, ui.field_string(&e.secret), "hunter2")
	testing.expect(t, session.find_text(s, "hunter2") == nil, "it is shown by no box")
}) }

// A secret field with a reveal button: the eye at its end shows the text, and hides it again; shown, it is text (copied). A
// secret field without one has no eye.
@(test)
a_secret_field_can_be_revealed :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	testing.expect(t, session.find(s, "reveal", 1) == nil, "one eye: the field that asks for it")
	session.set_clipboard(s, "before")
	session.click(s, "shown")
	session.type_text(s, "hunter2")
	field, eye := session.find(s, "shown"), session.find(s, "reveal")
	if !testing.expect(t, field != nil && eye != nil, "the field and its eye") { return }
	testing.expect(t, eye.rect.max.x <= field.rect.max.x + 0.5 && eye.rect.min.x > field.rect.min.x + (field.rect.max.x - field.rect.min.x) * 0.5, "at its end, inside it")
	shown_text :: proc(b: ^ui.Box) -> string { return (^ui.Line_Edit_Draw)(b.custom_user).text }
	testing.expect_value(t, shown_text(field), "•••••••")
	testing.expect_value(t, session.get(s, "reveal").a11y.name, "Show the password")   // (a button a screen reader names)
	session.click(s, "reveal")
	testing.expect(t, e.reveal, "shown")
	testing.expect_value(t, shown_text(session.find(s, "shown")), "hunter2")
	testing.expect_value(t, session.focused_name(s), "shown")   // (the field keeps the keyboard)
	session.type_text(s, "!")
	testing.expect_value(t, ui.field_string(&e.shown), "hunter2!")
	session.key(s, .Backspace)
	session.key(s, .A, {.Ctrl})
	session.key(s, .C, {.Ctrl})
	testing.expect_value(t, session.clipboard(s), "hunter2")
	session.click(s, "reveal")
	testing.expect(t, !e.reveal, "hidden again")
	testing.expect_value(t, shown_text(session.find(s, "shown")), "•••••••")
	testing.expect_value(t, ui.field_string(&e.shown), "hunter2")
}) }

// By the mouse: a press puts the caret, a drag selects, a double click a word.
@(test)
a_line_edit_by_the_mouse :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	ui.field_set(&e.field, "alpha beta gamma")
	session.frames(s, 2)
	b := session.get(s, "field")
	x0, x1 := b.rect.min.x + 2, b.rect.max.x - 2
	y := session.center(b).y
	session.click_at(s, {x1, y})
	testing.expect_value(t, e.field.cursor, len("alpha beta gamma"))
	session.advance(s, session.SEPARATE_CLICK_MS)   // (a press this soon would be a double click)
	session.drag(s, {x1, y}, {x0, y})
	testing.expect_value(t, ui.field_selection(&e.field), "alpha beta gamma")
	// a double click takes the word
	session.advance(s, session.SEPARATE_CLICK_MS)
	mid := b.rect.min.x + font.measure(s.state.fonts, b.font, b.font_size, "alpha be") + b.text_pad
	session.click_at(s, {mid, y}, count = 2)
	testing.expect_value(t, ui.field_selection(&e.field), "beta")
}) }

@(test)
a_text_area_goes_by_lines :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t)
	session.click(s, "area")
	session.type_text(s, "xxxxx")   // (one width for all: the caret keeps its x, not its column)
	session.key(s, .Return)
	session.type_text(s, "xxxx line")
	session.key(s, .Return)
	session.type_text(s, "3")
	testing.expect_value(t, ui.area_line_count(&e.area), 3)
	session.key(s, .Up)
	testing.expect_value(t, e.area.cursor, len("xxxxx\nx"))
	session.key(s, .Up)
	testing.expect_value(t, e.area.cursor, len("x"))
	session.key(s, .Home, {.Ctrl})
	testing.expect_value(t, e.area.cursor, 0)
	session.key(s, .End, {.Ctrl})
	testing.expect_value(t, e.area.cursor, len(ui.area_string(&e.area)))
	session.key(s, .Home)
	session.key(s, .Tab)
	testing.expect(t, strings.has_suffix(ui.area_string(&e.area), " 3"), "Tab indents where it is asked to")
	testing.expect_value(t, session.focused_name(s), "area")
	session.key(s, .A, {.Ctrl})
	session.key(s, .Backspace)
	testing.expect_value(t, ui.area_string(&e.area), "")
	session.key(s, .Z, {.Ctrl})
	testing.expect_value(t, ui.area_line_count(&e.area), 3)
}) }

// A long text: the view follows the caret, there and back.
@(test)
a_text_area_follows_its_caret :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t, no_renderer = false)   // (the caret's place is known once it is drawn)
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< LONG_LINES { strings.write_string(&sb, "a line\n") }
	ui.area_set(&e.area, strings.to_string(sb))
	session.click(s, "area")
	testing.expect_value(t, e.area.scroll.y, 0)
	session.key(s, .End, {.Ctrl})
	session.wait_idle(s)
	testing.expect(t, e.area.scroll.y > 0, "the view went down with the caret")
	caret, _, ok := ui.text_edit_caret_rect(&e.area)
	box := session.get(s, "area")
	testing.expectf(t, ok && caret.max.y <= box.rect.max.y && caret.min.y >= box.rect.min.y, "and the caret is in view: %v in %v", caret, box.rect)
	session.key(s, .Home, {.Ctrl})
	session.wait_idle(s)
	testing.expect_value(t, e.area.scroll.y, 0)
}) }

// A wrapped area that grows from one line to its most, and then scrolls.
@(test)
an_auto_height_area_grows_to_its_most :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, _ := editors_start(t)
	one := session.get(s, "grow").rect.max.y - session.get(s, "grow").rect.min.y
	session.click(s, "grow")
	session.type_text(s, "so many words that this line has to wrap, and then again, and again")
	session.wait_idle(s)
	more := session.get(s, "grow").rect.max.y - session.get(s, "grow").rect.min.y
	testing.expectf(t, more > one, "it grew: %v then %v", one, more)
	session.type_text(s, strings.repeat(" more words", 40, context.temp_allocator))
	session.wait_idle(s)
	most := session.get(s, "grow").rect.max.y - session.get(s, "grow").rect.min.y
	session.type_text(s, strings.repeat(" more words", 40, context.temp_allocator))
	session.wait_idle(s)
	same := session.get(s, "grow").rect.max.y - session.get(s, "grow").rect.min.y
	testing.expect_value(t, same, most)
}) }

// The caret: solid after a move, off and on again by the clock, its bar in the frame's pixels; none in a window that is not the user's.
@(test)
the_caret_blinks_by_the_clock :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, e := editors_start(t, no_renderer = false)
	session.click(s, "area")
	session.type_text(s, "x")
	r, _, ok := ui.text_edit_caret_rect(&e.area)
	if !testing.expect(t, ok, "a caret") { return }
	at := [2]int{int(r.min.x), int((r.min.y + r.max.y) * 0.5)}
	lit := session.pixel(session.capture(s), at.x, at.y)
	background := session.pixel(session.capture(s), at.x + 3, at.y)
	testing.expect(t, !session.near(lit, background), "the caret is drawn")
	seen_off := false
	for _ in 0 ..< CARET_FRAMES {
		session.frame(s)
		if session.near(session.pixel(session.capture(s), at.x, at.y), background) { seen_off = true; break }
	}
	testing.expect(t, seen_off, "it goes off by the clock, with no time waited for")
	session.key(s, .Left)
	session.key(s, .Right)
	testing.expect(t, !session.near(session.pixel(session.capture(s), at.x, at.y), background), "a move makes it solid")
	session.activate(s, false)
	testing.expect(t, session.near(session.pixel(session.capture(s), at.x, at.y), background), "a window in the back shows no caret")
	session.activate(s, true)
}) }

// The cursor the window asks for follows what the pointer is over.
@(test)
the_cursor_says_what_is_under_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	s, _ := editors_start(t)
	session.hover(s, "field")
	testing.expect_value(t, session.cursor(s), platform.Cursor.Text)
	session.hover(s, "area")
	testing.expect_value(t, session.cursor(s), platform.Cursor.Text)
	session.move(s, {f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)})
	testing.expect_value(t, session.cursor(s), platform.Cursor.Arrow)
}) }

// A field built for the first time, its text set with the caret at its end (a rename: the name selected), shows the text
// from its start: its width is not known in that build, and a scroll then showed only the text's end for one frame.
@(test)
a_new_field_is_not_scrolled :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	New_Field :: struct { field: ui.Text_Field, shown: bool }
	n: New_Field
	defer ui.field_destroy(&n.field)
	s := session.start(t, {user = &n, no_renderer = true, build = proc(s: ^session.Session) {
		n := (^New_Field)(s.user)
		if !n.shown { return }
		ui.next({width = ui.px(AREA_NARROW)})
		ui.line_edit("###new", &n.field)
	}})
	ui.field_set(&n.field, "Screenshot of the whole desktop, then copied")
	n.shown = true
	session.frames(s, 1)
	testing.expect_value(t, n.field.scroll_x, 0)
}) }

// Feel.undo_steps bounds the history of a line edit and of a text area alike: each keeps the last steps, the oldest go.
@(test)
undo_steps_bound_a_field_and_an_area_alike :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	UNDO_LIMIT :: 3
	TYPED :: "abcdef"
	KEPT :: "abc"   // what undoing every step kept gives back: the text before the last UNDO_LIMIT edits
	s, e := editors_start(t)
	f := ui.feel(s.state)
	f.undo_steps = UNDO_LIMIT
	f.undo_merge_ms = 0   // (each character its own step)
	ui.set_feel(s.state, f)

	session.click(s, "field")
	session.type_slowly(s, TYPED)
	testing.expect_value(t, ui.field_string(&e.field), TYPED)
	undone := 0
	for ui.field_undo(&e.field) { undone += 1 }
	testing.expect_value(t, undone, UNDO_LIMIT)
	testing.expect_value(t, ui.field_string(&e.field), KEPT)

	session.click(s, "area")
	session.type_slowly(s, TYPED)
	testing.expect_value(t, ui.area_string(&e.area), TYPED)
	undone = 0
	for ui.area_undo(&e.area) { undone += 1 }
	testing.expect_value(t, undone, UNDO_LIMIT)
	testing.expect_value(t, ui.area_string(&e.area), KEPT)
}) }
