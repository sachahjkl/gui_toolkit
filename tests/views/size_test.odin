package views_test

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

@(test)
a_size_asked_while_opening_is_the_first_drawn :: proc(t: ^testing.T) {
	r: Viewer
	defer ui.views_destroy(&r.views)
	ui.view_register(&r.views, "viewer", viewer_view, ui.View_Options{title = "Viewer", resizable = true, width_em = REGISTERED_EM.x, height_em = REGISTERED_EM.y})
	s := session.start(t, {size = {1200, 900}, user = &r, build = viewer_build})
	r.want = true
	for _ in 0 ..< FRAMES_MAX {
		session.frame(s)
		b := session.find(s, "modal_view_viewer")
		if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { continue }
		w := b.rect.max.x - b.rect.min.x
		em := b.font_size
		testing.expectf(t, abs(w - ASKED_EM.x * em) <= 1, "the first frame drawn is %v wide: the size asked, %v, not the registered %v", w, ASKED_EM.x * em, REGISTERED_EM.x * em)
		return
	}
	testing.expect(t, false, "the dialog never showed")
}
