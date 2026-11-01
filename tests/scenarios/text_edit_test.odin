package scenarios_test

// Editing text: a line edit and a text area, by the keyboard and the mouse, the undo steps by the session's clock, the caret by its pixels.

import "core:strings"
import "core:testing"
import "../../font"
import "../../platform"
import "../../testkit/session"
import "../../ui"

// A stretch of the clock longer than what merges typing into one undo step (ui FIELD_UNDO_MERGE_MS).
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
		ui.area_destroy(&e.area)
		ui.area_destroy(&e.grow)
		free(e)
	}, e)
	return session.start(t, {build = editors_build, user = e, no_renderer = no_renderer}, loc), e
}

@(test)
a_line_edit_moves_selects_and_deletes :: proc(t: ^testing.T) {
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
}

// A character of several code points is one step for the caret and for Backspace.
@(test)
a_line_edit_moves_by_graphemes :: proc(t: ^testing.T) {
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
}

// Enter says committed, Esc cancelled and the focus goes.
@(test)
a_line_edit_says_committed_and_cancelled :: proc(t: ^testing.T) {
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
}

// What is typed in one go is one undo step; after a pause, another. By the session's clock: the merging must not read the system's.
@(test)
undo_steps_go_by_the_clock :: proc(t: ^testing.T) {
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
}

@(test)
cut_copy_paste_through_the_clipboard :: proc(t: ^testing.T) {
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
}

// A secret field shows no text and gives none away.
@(test)
a_secret_field_does_not_copy :: proc(t: ^testing.T) {
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
}

// By the mouse: a press puts the caret, a drag selects, a double click a word.
@(test)
a_line_edit_by_the_mouse :: proc(t: ^testing.T) {
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
}

@(test)
a_text_area_goes_by_lines :: proc(t: ^testing.T) {
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
}

// A long text: the view follows the caret, there and back.
@(test)
a_text_area_follows_its_caret :: proc(t: ^testing.T) {
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
}

// A wrapped area that grows from one line to its most, and then scrolls.
@(test)
an_auto_height_area_grows_to_its_most :: proc(t: ^testing.T) {
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
}

// The caret: solid after a move, off and on again by the clock, its bar in the frame's pixels; none in a window that is not the user's.
@(test)
the_caret_blinks_by_the_clock :: proc(t: ^testing.T) {
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
}

// The cursor the window asks for follows what the pointer is over.
@(test)
the_cursor_says_what_is_under_the_pointer :: proc(t: ^testing.T) {
	s, _ := editors_start(t)
	session.hover(s, "field")
	testing.expect_value(t, session.cursor(s), platform.Cursor.Text)
	session.hover(s, "area")
	testing.expect_value(t, session.cursor(s), platform.Cursor.Text)
	session.move(s, {f32(session.DEFAULT_SIZE.x - 1), f32(session.DEFAULT_SIZE.y - 1)})
	testing.expect_value(t, session.cursor(s), platform.Cursor.Arrow)
}
