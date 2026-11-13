package scenarios_test

// What goes on over several frames, each in a state of its own: dialogs on one another, a sweep left behind, a word held
// by a double click, a press that no pointer made.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{600, 500}
@(private = "file") FIELD_WIDTH :: 200
@(private = "file") SLIDER_WIDTH :: 300
// Inside the first word of a field, whatever its font.
@(private = "file") INTO_THE_FIRST_WORD :: 15
@(private = "file") TABS :: 5
@(private = "file") SETTLE_FRAMES :: 4

@(private = "file")
Dialogs :: struct {
	first, second: bool,
	page, field:   ui.Line_Edit,
}

@(private = "file")
dialogs_build :: proc(s: ^session.Session) {
	d := (^Dialogs)(s.user)
	ui.next({width = ui.px(FIELD_WIDTH)})
	ui.line_edit("###page", &d.page)
	if ui.modal("first", &d.first, {width_em = 400 / ui.font_size()}) {
		ui.next({width = ui.px(100)})
		ui.button("below", "Below")
	}
	if ui.modal("second", &d.second, {width_em = 300 / ui.font_size()}) {
		ui.next({width = ui.px(FIELD_WIDTH)})
		ui.line_edit("###field", &d.field)
		ui.next({width = ui.px(100)})
		ui.button("above", "Above")
	}
}

// A dialog under another one is not opening again at each frame: what the top one's field was given, it keeps.
@(test)
a_field_of_the_top_dialog_keeps_the_keyboard :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	d := Dialogs{first = true, second = true}
	defer { ui.line_edit_destroy(&d.page); ui.line_edit_destroy(&d.field) }
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
	defer { ui.line_edit_destroy(&d.page); ui.line_edit_destroy(&d.field) }
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
	defer { ui.line_edit_destroy(&d.page); ui.line_edit_destroy(&d.field) }
	s := session.start(t, {size = WINDOW, user = &d, build = dialogs_build})
	session.click(s, "page")
	d.first = true
	session.frame(s)
	session.frame(s)
	testing.expect_value(t, s.state.focus_key, ui.Key(0))
	session.key(s, .Escape)
	session.frame(s)
	testing.expect(t, !d.first, "Escape closed it")
	session.type_text(s, "back")
	testing.expect_value(t, ui.line_edit_string(&d.page), "back")
}) }

// The sweep that was due when the page went away is due no longer: the loop goes back to sleep.
@(test)
a_sweep_nobody_asks_for_lets_the_loop_sleep :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { on_page: bool }
	r := Run{on_page = true}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.find("word")
		if r.on_page { _ = ui.find_sweep() }
		ui.label("a word")
	}})
	session.frame(s)
	testing.expect(t, ui.wake_ms(s.state) > 0, "the sweep is on its way: a wake when its time comes")
	testing.expect(t, !ui.needs_frame(s.state), "and no frame until then")
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
