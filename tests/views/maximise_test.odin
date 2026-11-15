package views_test

// A resizable view shown as a dialog maximises to fill its window and restores (src/md/features/views.md, section 2.9):
// its header's button and a double click on its header do it; maximised it fills the window but MODAL_MARGIN_EM on each
// side, and keeps filling it as the window changes; restored it has its size back; the size the user gave it, the
// memory's, is never the maximised one; view_maximise after view_open opens it maximised.

import "core:math"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{900, 640}
@(private = "file") SMALLER :: [2]int{700, 500}
@(private = "file") VIEW :: "viewer"
@(private = "file") PANEL :: "modal_view_viewer"
@(private = "file") GRIP_MOVE :: [2]f32{30, 20}   // the drag of the dialog's bottom right grip
@(private = "file") AFTER :: 3                     // frames made after an act: what it changed holds
@(private = "file") SETTLE_FRAMES :: 20            // more than the six layouts a dialog is measured at most

@(private = "file")
Body :: struct {
	builds: int,
}

@(private = "file")
Run :: struct {
	views:   ui.Views,
	body:    Body,
	open:    bool,   // open the view in the next build
	at_open: bool,   // ... maximised (view_maximise after view_open)
	em:      f32,    // the font size of the last build (px)
}

@(private = "file")
run_build :: proc(s: ^session.Session) {
	r := (^Run)(s.user)
	r.em = ui.font_size()
	if r.open {
		r.open = false
		ui.view_open(&r.views, VIEW, &r.body)
		if r.at_open { ui.view_maximise(&r.views, VIEW, true) }
	}
	ui.label("The page###page")
}

// (a viewer: what is in it fills it, as a diagram's canvas does)
@(private = "file")
viewer_view :: proc(v: ^ui.View, b: ^Body) {
	b.builds += 1
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.build_box({}, "###viewer_canvas")
}

@(private = "file")
run_start :: proc(t: ^testing.T, r: ^Run) -> ^session.Session {
	ui.view_register(&r.views, VIEW, viewer_view, ui.View_Options{title = "Viewer", resizable = true, width_em = 24, height_em = 16})
	return session.start(t, {size = WINDOW, user = r, build = run_build})
}

@(private = "file")
run_end :: proc(r: ^Run) { ui.views_destroy(&r.views) }

@(private = "file")
wait_shown :: proc(s: ^session.Session) {
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		b := session.find(s, PANEL)
		return b != nil && b.transparency < 1
	}, "the dialog to show")
}

// Where a maximised dialog is in the window as it is now: all of it but MODAL_MARGIN_EM on each side (modal's rounding).
@(private = "file")
filled :: proc(s: ^session.Session, em: f32) -> ui.Rect {
	win := s.state.window_size
	margin := em * ui.MODAL_MARGIN_EM
	wh := ui.Vec2{math.round(win.x - 2 * margin), math.round(win.y - 2 * margin)}
	at := ui.Vec2{math.round((win.x - wh.x) * 0.5), math.round((win.y - wh.y) * 0.5)}
	return {at, at + wh}
}

@(private = "file")
near :: proc(a, b: ui.Rect) -> bool {
	return abs(a.min.x - b.min.x) <= 1 && abs(a.min.y - b.min.y) <= 1 && abs(a.max.x - b.max.x) <= 1 && abs(a.max.y - b.max.y) <= 1
}

// The dialog's panel is drawn at `want`.
@(private = "file")
wait_rect :: proc(s: ^session.Session, want: ui.Rect, what: string) {
	session.wait_until(s, want, proc(s: ^session.Session, want: ui.Rect) -> bool {
		b := session.find(s, PANEL)
		return b != nil && b.transparency < 1 && near(b.rect, want)
	}, what)
}

// The header's button, left of the close cross, maximises it: the window's room but the margin, no grips, and a window
// resized keeps it filling; Escape still closes it.
@(test)
the_button_maximises_a_dialog :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.open = true
	s := run_start(t, &r)
	wait_shown(s)
	testing.expect(t, !ui.view_maximised(&r.views, VIEW), "it opens at its size")
	button, cross := session.find(s, "view_maximise"), session.find(s, "dialog_close")
	testing.expect(t, button != nil && cross != nil, "the Maximise button and the close cross")
	if button != nil && cross != nil { testing.expect(t, button.rect.max.x <= cross.rect.min.x, "Maximise is left of the close cross") }

	session.click(s, "view_maximise")
	wait_rect(s, filled(s, r.em), "the dialog to fill the window")
	testing.expect(t, ui.view_maximised(&r.views, VIEW))
	testing.expect(t, session.find(s, "modal_grip7") == nil, "no grips while maximised")

	session.resize(s, SMALLER)
	wait_rect(s, filled(s, r.em), "the dialog to fill the smaller window")

	session.key(s, .Escape)
	session.wait_gone(s, PANEL)
	testing.expect(t, !ui.view_is_open(&r.views, VIEW), "Escape closes it, maximised")
}

// Restore, the same button, gives it back the size it had.
@(test)
restore_gives_back_its_size :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.open = true
	s := run_start(t, &r)
	wait_shown(s)
	before := session.find(s, PANEL).rect
	session.click(s, "view_maximise")
	wait_rect(s, filled(s, r.em), "the dialog to fill the window")
	session.click(s, "view_maximise")
	wait_rect(s, before, "the dialog at its size again")
	testing.expect(t, !ui.view_maximised(&r.views, VIEW))
}

// A double click on the header maximises it, another restores it; its presses do not detach it.
@(test)
a_double_click_on_the_header_toggles :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.open = true
	s := run_start(t, &r)
	wait_shown(s)
	before := session.find(s, PANEL).rect
	session.click(s, "view_header_title", count = 2)
	wait_rect(s, filled(s, r.em), "the dialog to fill the window")
	testing.expect(t, ui.view_maximised(&r.views, VIEW))
	session.click(s, "view_header_title", count = 2)
	wait_rect(s, before, "the dialog at its size again")
	testing.expect(t, !ui.view_maximised(&r.views, VIEW))
	testing.expect_value(t, ui.view_presentation(&r.views, VIEW), ui.View_Presentation.Dialog)
}

// The size the user gave it is the remembered one, maximised or not, and it opens again at it, not maximised.
@(test)
the_remembered_size_is_not_the_maximised_one :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.open = true
	s := run_start(t, &r)
	wait_shown(s)
	grip := session.find(s, "modal_grip7")
	testing.expect(t, grip != nil, "the resize grip")
	if grip == nil { return }
	at := session.center(grip)
	session.drag(s, at, at + GRIP_MOVE)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return ui.view_dialog_size(&(^Run)(s.user).views, VIEW) != {} }, "the size kept")
	kept := ui.view_dialog_size(&r.views, VIEW)
	sized := session.find(s, PANEL).rect

	session.click(s, "view_maximise")
	wait_rect(s, filled(s, r.em), "the dialog to fill the window")
	session.frames(s, AFTER)
	testing.expect_value(t, ui.view_dialog_size(&r.views, VIEW), kept)

	// (closed maximised: the memory has the user's size)
	ui.view_close(&r.views, VIEW)
	session.wait_gone(s, PANEL)
	testing.expect_value(t, ui.view_dialog_size(&r.views, VIEW), kept)

	r.open = true
	wait_rect(s, sized, "the dialog at the user's size, not maximised")
	testing.expect(t, !ui.view_maximised(&r.views, VIEW), "maximised is this opening's only")
}

// view_maximise after view_open: the first frame drawn is the maximised one.
@(test)
a_view_opens_maximised :: proc(t: ^testing.T) {
	r: Run
	defer run_end(&r)
	r.open, r.at_open = true, true
	s := run_start(t, &r)
	shown := false
	for _ in 0 ..< SETTLE_FRAMES {
		b := session.find(s, PANEL)
		if b != nil && b.transparency < 1 {
			shown = true
			testing.expect(t, near(b.rect, filled(s, r.em)), "its first frame drawn fills the window")
			break
		}
		session.frame(s)
	}
	testing.expect(t, shown, "it shows once settled")
	testing.expect(t, ui.view_maximised(&r.views, VIEW))
}
