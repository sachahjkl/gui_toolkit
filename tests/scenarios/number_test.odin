package scenarios_test

// A number one sets (ui.number), of an integer and of a float: its buttons, its wheel, its keys, the value typed in its
// field (applied at Enter or when the keyboard goes, clamped to its bounds and rounded to its step), its slider, and a
// disabled one that nothing changes. The wheel is the slider's own: a plain slider follows it too, and in a view that
// scrolls only once it has the keyboard.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{600, 300}
@(private = "file") ROW_WIDTH :: 360
@(private = "file") ROW_HEIGHT :: 28

@(private = "file")
Run :: struct {
	n:       int,
	x:       f32,
	off:     bool,
	changes: int,
}

@(private = "file")
count_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	ui.next({height = ui.px(ROW_HEIGHT)})
	if ui.number("###count", &r.n, lo = 0, hi = 20, disabled = r.off) { r.changes += 1 }
}

@(private = "file")
width_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	ui.next({width = ui.px(ROW_WIDTH), height = ui.px(ROW_HEIGHT)})
	ui.number("###width", &r.x, lo = 1, hi = 40, step = 0.5, unit = "px", slider = true)
}

// The text of the field: what is typed while it has the keyboard, else what it shows.
@(private = "file")
field_text :: proc(s: ^session.Session) -> string {
	if session.focused_name(s) == "value" { return ui.line_edit_string(&s.state.number_edit) }
	return ui.box_text(session.get(s, "value"))
}

// The buttons and the wheel step it; Shift steps ten; at a bound its button is disabled.
@(test)
an_integer_steps_by_its_buttons_and_the_wheel :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{n = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = count_build})
	testing.expect_value(t, field_text(s), "4")
	session.click(s, "inc")
	testing.expect_value(t, r.n, 5)
	session.click(s, "dec")
	session.click(s, "dec")
	testing.expect_value(t, r.n, 3)
	session.wheel(s, session.center(session.get(s, "value")), {0, -1})
	testing.expect_value(t, r.n, 4)
	session.wheel(s, session.center(session.get(s, "value")), {0, -1}, {.Shift})
	testing.expect_value(t, r.n, 14)
	session.wheel(s, session.center(session.get(s, "value")), {0, -1}, {.Shift})
	testing.expect_value(t, r.n, 20)
	testing.expect(t, .Disabled in session.get(s, "inc").flags, "+ is disabled at the upper bound")
	testing.expect(t, .Disabled not_in session.get(s, "dec").flags, "− is not")
	testing.expect_value(t, field_text(s), "20")
	testing.expect_value(t, r.changes, 6)
}) }

// Up / Down step it from the field, Shift by ten, Page Up by ten steps; what is typed applies at Enter, clamped and
// rounded; text that is no number, or Escape, gives the value back; the keyboard going elsewhere applies it too.
@(test)
an_integer_takes_keys_and_a_typed_value :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{n = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = count_build})
	session.click(s, "value")
	testing.expect_value(t, session.focused_name(s), "value")
	session.key(s, .Up)
	testing.expect_value(t, r.n, 5)
	session.key(s, .Down, {.Shift})
	testing.expect_value(t, r.n, 0)
	session.key(s, .Page_Up)
	testing.expect_value(t, r.n, 10)

	// (the field holds the value, all of it selected: typing replaces it)
	session.type_text(s, "12.6")
	session.key(s, .Return)
	testing.expect_value(t, r.n, 13)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "500")
	session.key(s, .Return)
	testing.expect_value(t, r.n, 20)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "-7")
	session.key(s, .Return)
	testing.expect_value(t, r.n, 0)

	session.key(s, .A, {.Ctrl})
	session.type_text(s, "thick")
	session.key(s, .Return)
	testing.expect_value(t, r.n, 0)
	testing.expect_value(t, field_text(s), "0")

	session.key(s, .A, {.Ctrl})
	session.type_text(s, "9")
	session.key(s, .Escape)
	testing.expect_value(t, r.n, 0)
	testing.expect_value(t, session.focused_name(s), "")
	testing.expect_value(t, field_text(s), "0")

	// (a press on nothing takes the keyboard away: what was typed applies)
	session.click(s, "value")
	session.type_text(s, "7")
	session.click_at(s, {f32(WINDOW.x) - 4, f32(WINDOW.y) - 4})
	testing.expect_value(t, r.n, 7)
	testing.expect_value(t, field_text(s), "7")
}) }

// Disabled: neither its buttons, nor the wheel, nor a press on its field change it.
@(test)
a_disabled_number_does_not_change :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{n = 4, off = true}
	s := session.start(t, {size = WINDOW, user = &r, build = count_build})
	session.click(s, "inc")
	session.wheel(s, session.center(session.get(s, "value")), {0, -1})
	session.click(s, "value")
	session.key(s, .Up)
	testing.expect_value(t, r.n, 4)
	testing.expect_value(t, session.focused_name(s), "")
	testing.expect(t, .Disabled in session.get(s, "value").flags, "its field is disabled")
}) }

// A screen reader sees a spin button and steps it.
@(test)
a_number_is_a_spin_button :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{n = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = count_build})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	field := session.get(s, "value")
	testing.expect(t, field.a11y != nil && field.a11y.role == .Spin_Button, "a spin button")
	ui.a11y_inject(s.state, {action = .Increment, target = u64(field.key)})
	session.frames(s, 2)
	testing.expect_value(t, r.n, 5)
}) }

// A float: its step rounds what is typed and its field shows the step's digits; the slider and the wheel over it move it.
@(test)
a_float_rounds_to_its_step_and_follows_its_slider :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{x = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = width_build})
	testing.expect_value(t, field_text(s), "4.0")
	session.wheel(s, session.center(session.get(s, "slider")), {0, -1})
	testing.expect_value(t, r.x, 4.5)
	session.wheel(s, session.center(session.get(s, "value")), {0, 2})
	testing.expect_value(t, r.x, 3.5)

	session.click(s, "value")
	session.type_text(s, "12.3")
	session.key(s, .Return)
	testing.expect_value(t, r.x, 12.5)
	testing.expect_value(t, field_text(s), "12.5")
	session.key(s, .Up)
	testing.expect_value(t, r.x, 13)

	b := session.get(s, "slider")
	session.click_at(s, {b.rect.max.x - 2, session.center(b).y})
	testing.expect_value(t, r.x, 40)
	testing.expect_value(t, field_text(s), "40.0")
	session.click_at(s, {b.rect.min.x + 2, session.center(b).y})
	testing.expect_value(t, r.x, 1)
}) }

// The wheel is the slider's own, not the number's: a plain slider follows it too.
@(test)
a_plain_slider_follows_the_wheel :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Plain :: struct { v: f32 }
	r := Plain{v = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Plain)(s.user)
		ui.next({width = ui.px(ROW_WIDTH), height = ui.px(ROW_HEIGHT)})
		ui.slider("###plain", &r.v, 0, 10, 1)
	}})
	session.wheel(s, session.center(session.get(s, "plain")), {0, -1})
	testing.expect_value(t, r.v, 5)
	session.wheel(s, session.center(session.get(s, "plain")), {0, 3})
	testing.expect_value(t, r.v, 2)
}) }

// In a view that scrolls, the wheel over a slider scrolls the view, until the slider has the keyboard.
@(test)
a_slider_in_a_scrolling_view_takes_the_wheel_once_focused :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Page :: struct { v: f32 }
	r := Page{v = 4}
	s := session.start(t, {size = WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Page)(s.user)
		ui.next({width = ui.px(ROW_WIDTH), height = ui.px(200), axis = .Y})
		page := ui.build_box({.View_Scroll_Y, .Clip}, "###page")
		_ = ui.signal(page)   // (a box scrolls in its signal)
		ui.push_parent(page)
		ui.next({width = ui.px(ROW_WIDTH - 40), height = ui.px(ROW_HEIGHT)})
		ui.slider("###in_page", &r.v, 0, 10, 1)
		ui.next({width = ui.px(10), height = ui.px(1000)})
		ui.build_box({}, "###tall")
		ui.pop_parent()
	}})
	at := session.center(session.get(s, "in_page"))
	session.wheel(s, at, {0, -1})
	testing.expect_value(t, r.v, 4)   // (the page had it)
	session.click_at(s, session.center(session.get(s, "in_page")))
	before := r.v
	session.wheel(s, session.center(session.get(s, "in_page")), {0, -1})
	testing.expect_value(t, r.v, before + 1)
}) }
