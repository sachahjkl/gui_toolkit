package scenarios_test

// A middle press on a box that takes the middle button (.Middle_Click: a link that opens in a new tab) is its middle
// click and starts no autoscroll; on the background of the scroll area, or on a box that does not take it, it starts
// autoscroll.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file")
Middle_App :: struct { link_middle, button_middle: int }

@(private = "file")
middle_build :: proc(s: ^session.Session) {
	app := (^Middle_App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.View_Scroll_Y, .Clip}, "###page")
	_ = ui.signal(page)
	ui.push_parent(page)
	ui.next({width = ui.px(120), height = ui.px(30)})
	if ui.signal(ui.build_box({.Clickable, .Middle_Click}, "###link")).middle_clicked { app.link_middle += 1 }
	ui.next({width = ui.px(120), height = ui.px(30)})
	if ui.signal(ui.build_box({.Clickable}, "###plain")).middle_clicked { app.button_middle += 1 }
	ui.next({width = ui.fill(), height = ui.px(2000)})
	ui.build_box({}, "###tall")
	ui.pop_parent()
}

@(test)
a_link_keeps_its_middle_click :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: Middle_App
	s := session.start(t, {size = {400, 300}, user = &app, no_renderer = true, build = middle_build})
	session.frames(s, 3)
	link := session.center(session.get(s, "link"))
	session.press(s, link, .Middle)
	testing.expect(t, !ui.autoscroll_running(s.state), "a middle press on a link starts no autoscroll")
	session.release(s, link, .Middle)
	testing.expect_value(t, app.link_middle, 1)
	// on the background: autoscroll, held while the button is down
	ground := [2]f32{300, 200}   // (on the tall box, in the window: its middle is far below)
	session.press(s, ground, .Middle)
	testing.expect(t, ui.autoscroll_running(s.state), "a middle press on the background starts autoscroll")
	session.release(s, ground, .Middle)
	session.key(s, .Escape)
	testing.expect(t, !ui.autoscroll_running(s.state), "Escape ends it")
	// a box that does not take the middle button leaves it to autoscroll
	plain := session.center(session.get(s, "plain"))
	session.press(s, plain, .Middle)
	testing.expect(t, ui.autoscroll_running(s.state), "a box without .Middle_Click leaves the press to autoscroll")
	session.release(s, plain, .Middle)
	testing.expect_value(t, app.button_middle, 0)
}) }
