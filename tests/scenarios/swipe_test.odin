package scenarios_test

// A swipe of the fingers on a touchpad gives one step per gesture (ui.swipe_step): a new gesture after a pause or a lift
// gives another, a wheel's notches and a scroll up and down give none.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Swipe_App :: struct { sw: ui.Swipe, next, back: int }

@(private = "file")
swipe_build :: proc(s: ^session.Session) {
	app := (^Swipe_App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	view := ui.build_box({}, "###view")
	switch ui.swipe_step(&app.sw, view.rect) {
	case 1:  app.next += 1
	case -1: app.back += 1
	}
}

@(test)
a_swipe_gives_one_step_per_gesture :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: Swipe_App
	s := session.start(t, {size = {400, 300}, user = &app, no_renderer = true, build = swipe_build})
	session.frames(s, 3)
	at := session.center(session.get(s, "view"))
	for _ in 0 ..< 6 { session.finger_scroll(s, at, {1.5, 0}) }
	testing.expect_value(t, app.next, 1)   // (9 notches: one step, at the threshold)
	// a pause ends the gesture: the next one steps the other way
	session.advance(s, ui.SWIPE_PAUSE_MS + 50)
	for _ in 0 ..< 4 { session.finger_scroll(s, at, {-1.5, 0}) }
	testing.expect_value(t, app.back, 1)
	// the fingers lift: a new gesture at once gives its step, with no pause
	session.finger_lift(s)
	for _ in 0 ..< 4 { session.finger_scroll(s, at, {-1.5, 0}) }
	testing.expect_value(t, app.back, 2)
	// a wheel's notches, however many, are no swipe
	session.advance(s, ui.SWIPE_PAUSE_MS + 50)
	for _ in 0 ..< 6 { session.wheel(s, at, {3, 0}) }
	testing.expect_value(t, app.next, 1)
	// fingers that scroll up and down and drift sideways give no step
	session.advance(s, ui.SWIPE_PAUSE_MS + 50)
	for _ in 0 ..< 6 { session.finger_scroll(s, at, {1, 3}) }
	testing.expect_value(t, app.next, 1)
	testing.expect_value(t, app.back, 2)
}) }
