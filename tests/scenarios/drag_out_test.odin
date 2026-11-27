package scenarios_test

// ui.Drag_Out (src/md/features/drag-out.md): a box's press that moves past the system's threshold starts one drag out,
// with its file; a press that stays under it starts none; a press is one drag however far it goes; in an offscreen
// window the drag is recorded, not started.

import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Out_Run :: struct { d: ui.Drag_Out, started: int }

@(test)
a_press_past_the_threshold_drags_its_file_out_once :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Out_Run
	defer ui.drag_out_destroy(&r.d)
	s := session.start(t, {size = {400, 300}, user = &r, no_renderer = true, build = proc(s: ^session.Session) {
		r := (^Out_Run)(s.user)
		for name in ([]string{"###one", "###two"}) {
			ui.next({width = ui.px(120), height = ui.px(60)})
			b := ui.build_box({.Clickable}, name)
			if _, started := ui.drag_out_files(&r.d, b, ui.signal(b), {name == "###one" ? "/pictures/one.png" : "/pictures/two.png"}); started { r.started += 1 }
		}
	}})
	session.wait_idle(s)
	th := platform.drag_threshold(s.win)
	one := session.center(session.get(s, "one"))
	session.drag(s, one, one + {th.x * 0.5, 0})
	testing.expect_value(t, r.d.drags, 0)   // (under the threshold: a click's wobble)
	session.drag(s, one, one + {th.x * 6, th.y * 6}, steps = 12)
	testing.expect_value(t, r.d.drags, 1)   // (one drag a press, however far it goes)
	testing.expect_value(t, r.started, 1)
	if testing.expect_value(t, len(r.d.recorded), 1) { testing.expect_value(t, r.d.recorded[0], "/pictures/one.png") }
	two := session.center(session.get(s, "two"))
	session.drag(s, two, two + {0, th.y * 3})
	testing.expect_value(t, r.d.drags, 2)   // (another press: another drag)
	if len(r.d.recorded) == 2 { testing.expect_value(t, r.d.recorded[1], "/pictures/two.png") }
}) }
