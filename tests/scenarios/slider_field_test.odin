package scenarios_test

// A slider with its field: the value typed is applied at Enter, clamped and rounded to the step; the slider moves the
// field's number.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{600, 300}
@(private = "file") ROW_WIDTH :: 360
@(private = "file") ROW_HEIGHT :: 28

@(private = "file")
Run :: struct {
	v:       f32,
	f:       ui.Slider_Field,
	changes: int,
}

@(private = "file")
build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	ui.next({width = ui.px(ROW_WIDTH), height = ui.px(ROW_HEIGHT)})
	if ui.slider_field("###width", &r.f, &r.v, 1, 40, 1, unit = "px") { r.changes += 1 }
}

@(test)
a_value_typed_is_applied_clamped_and_rounded :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{v = 4}
	defer ui.slider_field_destroy(&r.f)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	testing.expect_value(t, ui.field_string(&r.f.text), "4")

	session.click(s, "value")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "12.6")
	session.key(s, .Return)
	testing.expect_value(t, r.v, 13)
	testing.expect_value(t, ui.field_string(&r.f.text), "13")

	session.key(s, .A, {.Ctrl})
	session.type_text(s, "500")
	session.key(s, .Return)
	testing.expect_value(t, r.v, 40)

	// not a number: the value stays, the field shows it again
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "thick")
	session.key(s, .Return)
	testing.expect_value(t, r.v, 40)
	testing.expect_value(t, ui.field_string(&r.f.text), "40")
	testing.expect(t, r.changes == 2)
}) }

@(test)
the_slider_moves_the_number :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{v = 4}
	defer ui.slider_field_destroy(&r.f)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	b := session.get(s, "slider")
	session.click_at(s, {b.rect.min.x + 2, session.center(b).y})
	session.click_at(s, {b.rect.max.x - 2, session.center(b).y})
	testing.expect_value(t, r.v, 40)
	session.key(s, .Left)
	testing.expect_value(t, r.v, 39)
	testing.expect_value(t, ui.field_string(&r.f.text), "39")
}) }

// The wheel up over the field or the slider is a step more, down a step less; − and + a step each.
@(test)
the_wheel_and_the_buttons_step_the_value :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Run{v = 4}
	defer ui.slider_field_destroy(&r.f)
	s := session.start(t, {size = WINDOW, user = &r, build = build})
	session.wheel(s, session.center(session.get(s, "value")), {0, -1})
	testing.expect_value(t, r.v, 5)
	session.wheel(s, session.center(session.get(s, "slider")), {0, 2})
	testing.expect_value(t, r.v, 3)
	testing.expect_value(t, ui.field_string(&r.f.text), "3")
	session.click(s, "inc")
	testing.expect_value(t, r.v, 4)
	session.click(s, "dec")
	session.click(s, "dec")
	testing.expect_value(t, r.v, 2)
	session.wheel(s, session.center(session.get(s, "value")), {0, -1}, {.Shift})
	testing.expect_value(t, r.v, 12)
}) }

// The wheel is the slider's own, not slider_field's: a plain slider follows it too.
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
