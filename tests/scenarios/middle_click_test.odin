package scenarios_test

// A middle press on a box that takes the middle button (.Middle_Click: a link that opens in a new tab) is its middle
// click and starts no autoscroll; on the background of the scroll area, or on a box that does not take it, it starts
// autoscroll. In a rich paragraph, one box whose links are runs inside it, the link takes the middle button and the
// plain text around it leaves the press to autoscroll.

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

@(private = "file")
Rich_App :: struct { res: ui.Rich_Result, middle_link: string, middle_count, clicked: int }

@(private = "file")
rich_build :: proc(s: ^session.Session) {
	app := (^Rich_App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	page := ui.build_box({.View_Scroll_Y, .Clip}, "###page")
	_ = ui.signal(page)
	ui.push_parent(page)
	// the link first on the first line; the plain text after it runs over several lines
	runs := []ui.Rich_Run{
		{text = "link", link = "https://example.org"},
		{text = " and plain words after it that wrap over more than one line of the paragraph, then more words still to fill the last line"},
	}
	ui.next({width = ui.px(240)})
	app.res = ui.rich_paragraph("###rich", runs)
	if app.res.link_middle_clicked >= 0 { app.middle_count += 1; app.middle_link = app.res.link }
	if app.res.link_clicked >= 0 { app.clicked += 1 }
	ui.next({width = ui.fill(), height = ui.px(2000)})
	ui.build_box({}, "###tall")
	ui.pop_parent()
}

@(test)
a_rich_link_keeps_its_middle_click :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	app: Rich_App
	s := session.start(t, {size = {400, 300}, user = &app, no_renderer = true, build = rich_build})
	session.frames(s, 3)
	b := session.get(s, "rich")
	testing.expect(t, b.rect.max.y - b.rect.min.y > 40, "the paragraph wraps over several lines")
	link := b.rect.min + {b.text_pad + 4, b.text_pad + 4}            // (the first letters of the first line: the link)
	plain := [2]f32{b.rect.min.x + b.text_pad + 10, b.rect.max.y - b.text_pad - 4}   // (the last line: plain text)
	// a middle click on the link: reported, with its target, and no autoscroll
	session.press(s, link, .Middle)
	testing.expect(t, !ui.autoscroll_running(s.state), "a middle press on a link starts no autoscroll")
	session.release(s, link, .Middle)
	session.frames(s, 1)
	testing.expect_value(t, app.middle_count, 1)
	testing.expect_value(t, app.middle_link, "https://example.org")
	testing.expect_value(t, app.clicked, 0)
	// a middle press on the paragraph's plain text: autoscroll, the paragraph reports nothing
	session.press(s, plain, .Middle)
	testing.expect(t, ui.autoscroll_running(s.state), "a middle press on the plain text starts autoscroll")
	session.release(s, plain, .Middle)
	session.key(s, .Escape)
	testing.expect(t, !ui.autoscroll_running(s.state), "Escape ends it")
	testing.expect_value(t, app.middle_count, 1)
	// a left click on the link is its click, as before
	session.click_at(s, link)
	session.frames(s, 1)
	testing.expect_value(t, app.clicked, 1)
	testing.expect_value(t, app.middle_count, 1)
}) }
