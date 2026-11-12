package scenarios_test

// A slider with its field: the value typed is applied at Enter, clamped and rounded to the step; the slider moves the
// field's number.

import "core:testing"
import "../../src/testkit/session"
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
a_value_typed_is_applied_clamped_and_rounded :: proc(t: ^testing.T) {
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
}

@(test)
the_slider_moves_the_number :: proc(t: ^testing.T) {
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
}
