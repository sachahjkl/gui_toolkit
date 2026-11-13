package scenarios_test

// A range slider moves the thumb that is active, as ui.slider moves its own: each thumb is a Tab stop; the keys step it
// (its step), Home and End take it to its ends (the other thumb is one), the wheel moves it, and a press takes the
// nearest thumb.

import "core:testing"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{500, 200}
@(private = "file") TRACK_WIDTH :: 400
@(private = "file") TRACK_HEIGHT :: 28

@(private = "file")
Range :: struct { lo, hi: f32 }

@(private = "file")
range_build :: proc(s: ^session.Session) {
	r := (^Range)(s.user)
	ui.next({width = ui.px(TRACK_WIDTH), height = ui.px(TRACK_HEIGHT)})
	ui.range_slider("###range", &r.lo, &r.hi, 0, 100, 5, "%.0f %%")
}

@(test)
a_range_slider_moves_its_active_thumb_by_keys :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Range{lo = 20, hi = 70}
	s := session.start(t, {size = WINDOW, user = &r, build = range_build})
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "lo")
	session.key(s, .Right)
	testing.expect_value(t, r.lo, 25)
	session.key(s, .Page_Up)
	testing.expect_value(t, r.lo, 70)   // (ten steps would pass the other thumb: it stops there)
	session.key(s, .Home)
	testing.expect_value(t, r.lo, 0)

	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "hi")
	session.key(s, .Left)
	testing.expect_value(t, r.hi, 65)
	session.key(s, .End)
	testing.expect_value(t, r.hi, 100)
	session.key(s, .Home)
	testing.expect_value(t, r.hi, 0)   // (its low end is the other thumb)
	testing.expect_value(t, r.lo, 0)
}) }

// The wheel moves the thumb that has the keyboard; a press takes the nearest thumb, which then has it.
@(test)
a_range_slider_takes_the_wheel_and_a_press :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Range{lo = 20, hi = 70}
	s := session.start(t, {size = WINDOW, user = &r, build = range_build})
	track := session.get(s, "range")
	session.key(s, .Tab)
	session.key(s, .Tab)
	testing.expect_value(t, session.focused_name(s), "hi")
	session.wheel(s, session.center(track), {0, -1})
	testing.expect_value(t, r.hi, 75)
	testing.expect_value(t, r.lo, 20)

	lo_thumb := session.get(s, "lo")
	session.click_at(s, session.center(lo_thumb) + {-20, 0})
	testing.expect_value(t, session.focused_name(s), "lo")
	testing.expect(t, r.lo < 20, "the press moved the low thumb")
	before := r.lo
	session.wheel(s, session.center(track), {0, -1})
	testing.expect_value(t, r.lo, before + 5)
}) }

// Each thumb is a slider for a screen reader, and a request moves it.
@(test)
a_range_slider_thumb_is_a_slider :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Range{lo = 20, hi = 70}
	s := session.start(t, {size = WINDOW, user = &r, build = range_build})
	ui.a11y_capture(s.state, true)
	session.frames(s, 2)
	hi := session.get(s, "hi")
	testing.expect(t, hi.a11y != nil && hi.a11y.role == .Slider, "a slider")
	testing.expect_value(t, hi.a11y.value, "70 %")
	ui.a11y_inject(s.state, {action = .Set_Value, data = .Numeric_Value, num = 90, target = u64(hi.key)})
	session.frames(s, 2)
	testing.expect_value(t, r.hi, 90)
}) }
