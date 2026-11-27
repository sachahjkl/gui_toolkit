package scenarios_test

// ui.wallpaper_set: the system's call on the chores, its result at a later build of the window. A file that cannot be
// read fails without asking the desktop (the person's background is never touched by a test).

import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Paper_Run :: struct { ask: bool, answers: int, result: platform.Wallpaper_Result }

@(test)
a_wallpaper_answers_at_a_later_build :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Paper_Run{ask = true}
	s := session.start(t, {size = {300, 200}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Paper_Run)(s.user)
		if r.ask {
			r.ask = false
			ui.wallpaper_set("/nonexistent/picture.png", proc(user: rawptr, result: platform.Wallpaper_Result) {
				r := (^Paper_Run)(user)
				r.answers += 1
				r.result = result
			}, r)
		}
	}})
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Paper_Run) -> bool { return r.answers > 0 }, "the answer")
	testing.expect_value(t, r.result, platform.Wallpaper_Result.Failed)
	session.frames(s, 3)
	testing.expect_value(t, r.answers, 1)
}) }
