package view_size_test

// view_size while a dialog opens (src/md/features/views.md 3.4, "A size asked while opening holds the dialog"): the
// first frame drawn has the size asked, not the registered one, for a dialog of a known size, which shows in its first
// build.

import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") FRAMES_MAX :: 40
@(private = "file") REGISTERED_EM :: [2]f32{20, 12}
@(private = "file") ASKED_EM :: [2]f32{36, 18}

@(private = "file")
Viewer :: struct {
	views: ui.Views,
	want:  bool,
	tall:  bool,   // the stretch dialog asks a taller size
}

@(private = "file")
viewer_build :: proc(s: ^session.Session) {
	r := (^Viewer)(s.user)
	if r.want { ui.view_open(&r.views, "viewer", r); r.want = false }
}

// (a viewer that sizes itself to what it shows, in its first build: a picture's size)
@(private = "file")
viewer_view :: proc(v: ^ui.View, r: ^Viewer) {
	ui.view_size(v, ASKED_EM.x, ASKED_EM.y)
	if ui.dialog_body("viewer_body") { ui.label("A picture") }
}

@(private = "file") STRETCH_LEAST_EM :: 6

@(private = "file")
stretch_view :: proc(v: ^ui.View, r: ^Viewer) {
	if r.tall { ui.view_size(v, 30, 40) }
	if ui.dialog_body("stretch_body", stretch = true) {
		ui.label("Above")
		ui.next({width = ui.fill(), height = ui.fill_least(STRETCH_LEAST_EM * ui.font_size())})
		_ = ui.build_box({}, "###stretched")
	}
	if ui.dialog_buttons("stretch_buttons") { _ = ui.button("stretch_ok", "OK") }
}

// A stretched body in a resizable dialog: it opens with its part at its least, the buttons under it, and the part takes
// what a taller dialog gives.
@(test)
a_stretched_body_opens_at_its_least_and_grows :: proc(t: ^testing.T) {
	r := new(Viewer)
	testing.cleanup(t, proc(p: rawptr) { v := (^Viewer)(p); ui.views_destroy(&v.views); free(v) }, r)
	ui.view_register(&r.views, "stretch", stretch_view, ui.View_Options{title = "Stretch", resizable = true, width_em = 30})
	s := session.start(t, {user = r, build = proc(s: ^session.Session) {
		r := (^Viewer)(s.user)
		if r.want { ui.view_open(&r.views, "stretch", r); r.want = false }
	}})
	r.want = true
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		b := session.find(s, "modal_view_stretch")
		return b != nil && b.last_build == s.state.build_index && b.transparency < 1
	}, "the dialog shows")
	part := session.get(s, "stretched")
	button := session.get(s, "stretch_ok")
	em := part.font_size
	h := part.rect.max.y - part.rect.min.y
	testing.expectf(t, abs(h - STRETCH_LEAST_EM * em) <= 1, "the part opens at its least: %v, not %v", h, STRETCH_LEAST_EM * em)
	testing.expect(t, button.rect.min.y >= part.rect.max.y, "the buttons are under it, in the dialog")
	r.tall = true
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		p := session.get(s, "stretched")
		return p.rect.max.y - p.rect.min.y > 20 * p.font_size
	}, "the part grows with the dialog")
	part = session.get(s, "stretched")
	h2 := part.rect.max.y - part.rect.min.y
	testing.expectf(t, h2 > h + 10 * em, "a taller dialog gives it the room: %v after %v", h2, h)
	ui.view_close(&r.views, "stretch")
	session.frames(s, 2)
}

@(test)
a_size_asked_while_opening_is_the_first_drawn :: proc(t: ^testing.T) {
	// (the views outlive the session: a cleanup made before the session runs after its end)
	r := new(Viewer)
	testing.cleanup(t, proc(p: rawptr) { v := (^Viewer)(p); ui.views_destroy(&v.views); free(v) }, r)
	ui.view_register(&r.views, "viewer", viewer_view, ui.View_Options{title = "Viewer", resizable = true, width_em = REGISTERED_EM.x, height_em = REGISTERED_EM.y})
	s := session.start(t, {user = r, build = viewer_build})
	r.want = true
	shown := false
	for _ in 0 ..< FRAMES_MAX {
		session.frame(s)
		b := session.find(s, "modal_view_viewer")
		if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { continue }
		w := b.rect.max.x - b.rect.min.x
		em := b.font_size
		testing.expectf(t, abs(w - ASKED_EM.x * em) <= 1, "the first frame drawn is %v wide: the size asked, %v, not the registered %v", w, ASKED_EM.x * em, REGISTERED_EM.x * em)
		shown = true
		break
	}
	testing.expect(t, shown, "the dialog never showed")
	// (closed before the session ends: it ends on a window with no dialog, as the views tests do)
	ui.view_close(&r.views, "viewer")
	session.frames(s, 2)
}
