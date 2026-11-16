package host_test

// host.view_windows with an offscreen owner (src/md/features/views.md, section 4.1, decision 18): a program's test
// attaches its app (session.attach) and keeps the program's backend. A view's window is offscreen, framed by the
// owner's frames; session.view_window gives it to the test; it draws no picture over the owner's; its time is the
// owner's; view_close closes it.

import "core:testing"
import host "gt:host"
import "gt:platform"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
Aside :: struct {
	sh:     host.Shared,
	h:      host.Host,
	views:  ui.Views,
	clicks: int,
}

@(private = "file")
aside_view :: proc(v: ^ui.View, a: ^Aside) {
	if ui.button("aside_go", "Go").clicked { a.clicks += 1 }
}

@(private = "file")
aside_build :: proc(h: ^host.Host, size: host.Vec2) { ui.label("The page###page") }

@(test)
an_offscreen_owner_s_view_has_an_offscreen_window :: proc(t: ^testing.T) {
	a := new(Aside)
	if !host.host_open(&a.h, &a.sh, {title = "host views", size = SIZE, headless = true}, aside_build, a) {
		free(a)
		testing.fail_now(t, "no renderer (WARP)")
	}
	// (the app ends after the session: its cleanup first, as a program's test does)
	testing.cleanup(t, proc(p: rawptr) {
		a := (^Aside)(p)
		ui.views_destroy(&a.views)   // (its windows close, while the Shared is there)
		host.host_close(&a.h)
		free(a)
	}, a)
	ui.set_views(&a.h.state, &a.views)
	ui.view_register(&a.views, "aside", aside_view, ui.View_Options{title = "Aside", first = .External})
	ui.views_set_windows(&a.views, host.view_windows(&a.sh))
	s := session.attach(t, {win = a.h.win, state = &a.h.state, renderer = &a.sh.r, user = a, frame = proc(user: rawptr) { host.host_frame(&(^Aside)(user).h) }})
	session.frame(s)
	ui.view_open(&a.views, "aside", a, owner = &a.h.state)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		a := (^Aside)(s.user)
		w := session.view_window(s, &a.views, "aside")
		return w != nil && session.find(w, "aside_go") != nil && w.win.active
	}, "the view in its window, shown")
	w := session.view_window(s, &a.views, "aside")
	testing.expect(t, platform.is_offscreen(w.win), "offscreen, as its owner")
	testing.expect(t, !s.win.active, "the user is in the view's window")
	testing.expect(t, session.find(s, "aside_go") == nil, "not in the owner's window")
	testing.expect_value(t, len(a.sh.views), 1)
	if len(a.sh.views) == 1 { testing.expect_value(t, a.sh.views[0].host.frames.count, 0) }   // (no picture over the owner's)
	testing.expect_value(t, a.h.shown, SIZE)

	session.click(w, "aside_go")
	testing.expect_value(t, a.clicks, 1)
	// (its time is the owner's: the test's clock, through the attached State)
	before := s.clock
	session.advance(w, 200)
	testing.expect(t, s.clock >= before + 200, "advance on the view's window moves the application's clock")
	ui.use(w.state)
	testing.expect_value(t, ui.now_ms(), s.clock)
	ui.use(s.state)

	ui.view_close(&a.views, "aside")
	session.frames(s, 2)
	testing.expect_value(t, len(a.sh.views), 0)   // (the backend's close: the Host and its State gone)
	testing.expect(t, session.view_window(s, &a.views, "aside") == nil, "in no window")
	testing.expect(t, s.win.active, "the owner has the user back")
}
