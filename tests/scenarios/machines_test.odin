package scenarios_test

// What goes on over several frames, each in a state of its own: dialogs on one another, a find left behind, a word held
// by a double click, a press that no pointer made.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") FIELD_WIDTH :: 200
@(private = "file") SLIDER_WIDTH :: 300
// Inside the first word of a field, whatever its font.
@(private = "file") INTO_THE_FIRST_WORD :: 15
@(private = "file") TABS :: 5
@(private = "file") SETTLE_FRAMES :: 4

@(private = "file")
Dialogs :: struct {
	views:         ui.Views,
	first, second: bool,   // open it in the next build (the first before the second: the second is on top)
	page, field:   ui.Line_Edit,
}

@(private = "file")
dialogs_build :: proc(s: ^session.Session) {
	d := (^Dialogs)(s.user)
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###page", &d.page)
	if d.first { d.first = false; ui.view_open(&d.views, "first", d) }
	if d.second { d.second = false; ui.view_open(&d.views, "second", d) }
}

@(private = "file")
first_view :: proc(v: ^ui.View, d: ^Dialogs) {
	ui.next({width = ui.px(100)})
	ui.button("below", "Below")
}

@(private = "file")
second_view :: proc(v: ^ui.View, d: ^Dialogs) {
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###field", &d.field)
	ui.next({width = ui.px(100)})
	ui.button("above", "Above")
}

@(private = "file")
dialogs_init :: proc(d: ^Dialogs) {
	ui.view_register(&d.views, "first", first_view, ui.View_Options{title = "First"})
	ui.view_register(&d.views, "second", second_view, ui.View_Options{title = "Second"})
}

@(private = "file")
dialogs_end :: proc(d: ^Dialogs) {
	ui.views_destroy(&d.views)
	ui.line_edit_destroy(&d.page)
	ui.line_edit_destroy(&d.field)
}

// A dialog under another one is not opening again at each frame: what the top one's field was given, it keeps.
@(test)
a_field_of_the_top_dialog_keeps_the_keyboard :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	d := Dialogs{first = true, second = true}
	dialogs_init(&d)
	defer dialogs_end(&d)
	s := session.start(t, {size = WINDOW, user = &d, build = dialogs_build})
	session.frame(s)
	session.click(s, "field")
	session.type_text(s, "hi")
	testing.expect_value(t, ui.line_edit_string(&d.field), "hi")
}) }

// Tab goes round the dialog on top, not through the one under it.
@(test)
tab_stays_in_the_top_dialog :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	d := Dialogs{first = true, second = true}
	dialogs_init(&d)
	defer dialogs_end(&d)
	s := session.start(t, {size = WINDOW, user = &d, build = dialogs_build})
	session.frame(s)
	below := session.get(s, "below").key
	for _ in 0 ..< TABS {
		session.key(s, .Tab)
		testing.expect(t, s.state.focus_key != 0 && s.state.focus_key != below, "the focus is in the dialog on top")
	}
}) }

// What had the focus when a dialog opened has it again when it closes.
@(test)
a_closed_dialog_gives_the_focus_back :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	d: Dialogs
	dialogs_init(&d)
	defer dialogs_end(&d)
	s := session.start(t, {size = WINDOW, user = &d, build = dialogs_build})
	session.click(s, "page")
	d.first = true
	// (it is laid out unseen until its layout holds: the page loses the focus on the frame that shows it)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		b := session.find(s, "modal_view_first")
		return b != nil && b.transparency < 1
	}, "the dialog to show")
	testing.expect_value(t, s.state.focus_key, ui.Key(0))
	session.key(s, .Escape)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !ui.view_is_open(&(^Dialogs)(s.user).views, "first") }, "Escape to close it")
	session.type_text(s, "back")
	testing.expect_value(t, ui.line_edit_string(&d.page), "back")
}) }

// A find counting a long list asks for frames until it is done; its view gone (another page), nothing waits for it: the
// loop goes back to sleep.
@(test)
a_find_whose_view_is_gone_lets_the_loop_sleep :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { on_page: bool }
	r := Run{on_page = true}
	ROWS :: 50_000
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		if !r.on_page { ui.label("another page"); return }
		ui.next({width = ui.px(300), height = ui.px(200)})
		if ui.scroll_y("###view") {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column(id = "###col") {
				text :: proc(user: rawptr, i: int, allocator: runtime.Allocator, whole: bool) -> (string, bool) { return strings.clone("a word", allocator), true }
				lz := ui.lazy_begin(rows = {count = ROWS, text = text})
				for i in 0 ..< ROWS {
					if ui.lazy_item(lz, fmt.tprintf("###r%d", i)) { ui.label("a word###t") }
				}
			}
		}
		ui.find_bar(ui.prev_box("###view"))
	}})
	session.frames(s, 2)
	ui.find_open(session.get(s, "view").key, "word")
	session.frames(s, 2)
	testing.expect(t, ui.find_pending() && ui.needs_frame(s.state), "counting: the next frame is asked for")
	r.on_page = false
	for _ in 0 ..< SETTLE_FRAMES { session.frame(s) }
	testing.expect(t, !ui.needs_frame(s.state), "nothing is waiting for it")
}) }

// A double click takes the word, and a frame made while the button is still down does not put it back to a caret.
@(test)
a_word_stays_selected_while_the_button_is_held :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { f: ui.Line_Edit }
	r: Run
	defer ui.line_edit_destroy(&r.f)
	ui.line_edit_set(&r.f, "hello world")
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(FIELD_WIDTH)})
		ui.line_edit("###f", &r.f)
	}})
	b := session.get(s, "f")
	at := [2]f32{b.rect.min.x + INTO_THE_FIRST_WORD, session.center(b).y}
	session.click_at(s, at)
	session.press(s, at)
	session.move(s, {at.x + 1, at.y})
	session.frame(s)
	session.release(s, {at.x + 1, at.y})
	testing.expect_value(t, min(r.f.cursor, r.f.mark), 0)
	testing.expect_value(t, max(r.f.cursor, r.f.mark), len("hello"))
}) }

// Enter on a focused slider is no press at the place of the pointer: what it shows stays what it was.
@(test)
a_key_on_a_slider_is_not_the_pointer :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { v: f32 }
	r := Run{v = 0.25}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({width = ui.px(SLIDER_WIDTH)})
		ui.slider("###v", &r.v, 0, 1)
	}})
	b := session.get(s, "v")
	session.click_at(s, session.center(b))
	before := r.v
	session.move(s, {b.rect.max.x - 2, session.center(b).y})
	session.key(s, .Return)
	testing.expect_value(t, r.v, before)
}) }
