package views_test

// The Internal presentation (src/md/features/views.md, section 5): a dialog detached by its icon (never a frame with
// the view in neither place or in both), by a drag of its header (under the pointer), an internal window moved by its
// header and resized by its corner (the rect remembered), re-attached, closed by Escape and by its button, two of them
// in front of each other by a press.

import "core:testing"
import store "../../src/store"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{1000, 720}
@(private = "file") DRAG :: [2]f32{120, 60}
@(private = "file") GROW :: [2]f32{60, 40}
@(private = "file") FRAMES_MAX :: 20   // more than the unseen layouts of a move (MODAL_MEASURES_MAX)
@(private = "file") EPS :: 1.5         // (a rect rounded to whole pixels)

@(private = "file")
Win :: struct {
	views:   ui.Views,
	want:    string,   // open in the next build
	answers: [dynamic]int,
	sat:     f32,      // the colour window's slider
}

@(private = "file")
win_build :: proc(s: ^session.Session) {
	r := (^Win)(s.user)
	if r.want != "" { ui.view_open(&r.views, r.want, r); r.want = "" }
	for id in ([]string{"ask", "other"}) {
		if code, ok := ui.view_ended(&r.views, id); ok { append(&r.answers, code) }
	}
	ui.label("The page###page")
}

@(private = "file")
win_view :: proc(v: ^ui.View, r: ^Win) {
	if ui.dialog_body("win_body") { ui.label("What is in it###win_words") }
	if ui.dialog_buttons("win_buttons") { _ = ui.button("win_ok", "OK") }
}

// A floating colour window narrower than what is in it (Saturation's label, a line of a width of its own).
@(private = "file")
colour_view :: proc(v: ^ui.View, r: ^Win) {
	ui.next({width = ui.px(WIDE_PX), height = ui.px(10)})
	_ = ui.build_box({}, "###colour_wide")
	if ui.form_row("Saturation") { ui.slider("###colour_sat", &r.sat, 0, 1, 0.01, "%.2f") }
}

@(private = "file") WIDE_PX :: 420   // (wider than COLOUR_EM)
@(private = "file") COLOUR_EM :: 12

@(private = "file")
win_start :: proc(t: ^testing.T, r: ^Win) -> ^session.Session {
	ui.view_register(&r.views, "ask", win_view, ui.View_Options{title = "Question"})
	ui.view_register(&r.views, "other", win_view, ui.View_Options{title = "Another"})
	ui.view_register(&r.views, "colour", colour_view, ui.View_Options{title = "Colour", first = .Internal, width_em = COLOUR_EM})
	return session.start(t, {size = WINDOW, user = r, build = win_build})
}

@(private = "file")
win_end :: proc(r: ^Win) {
	ui.views_destroy(&r.views)
	delete(r.answers)
}

// The box `name` drawn in the last build (not unseen).
@(private = "file")
drawn :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	b := session.find(s, name)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

@(private = "file")
wait_drawn :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	session.wait_until(s, name, proc(s: ^session.Session, name: string) -> bool { return drawn(s, name) != nil }, "it to show")
	return drawn(s, name)
}

// A point of a header's strip that is none of its buttons, nor an internal window's left grip (its edge's 0.4 em): in
// the margin before the title (1 em).
@(private = "file")
grab_point :: proc(header: ^ui.Box) -> [2]f32 {
	return {header.rect.min.x + GRAB_IN, (header.rect.min.y + header.rect.max.y) * 0.5}
}

@(private = "file") GRAB_IN :: 10   // (px: past the 6 px grip of a 15 px em, short of the title)

@(private = "file")
near :: proc(a, b: [2]f32) -> bool { return abs(a.x - b.x) <= EPS && abs(a.y - b.y) <= EPS }

// A floating window with no rect opens at what is in it (as wide as its widest line, centred), not at its narrower
// width_em; a form row's label shows whole; a resize never makes it narrower than that.
@(test)
a_floating_window_opens_at_what_is_in_it :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "colour"
	s := win_start(t, &r)
	frame := wait_drawn(s, "internal_view_colour")
	if frame == nil { return }
	width :: proc(b: ^ui.Box) -> f32 { return b.rect.max.x - b.rect.min.x }
	testing.expectf(t, width(frame) >= WIDE_PX, "as wide as its widest line: %v", frame.rect)
	centre := (frame.rect.min.x + frame.rect.max.x) * 0.5
	testing.expectf(t, abs(centre - f32(WINDOW.x) * 0.5) <= 2, "centred: %v", frame.rect)
	lbl := session.find(s, "lbl", within = frame)
	if lbl == nil { testing.expect(t, false, "the row's label"); return }
	testing.expectf(t, width(lbl) >= lbl.text_dim.x, "its label whole: %v for %v", width(lbl), lbl.text_dim.x)
	// a resize by its right edge, far to the left: it stops at what is in it
	grip := session.find(s, "view_grip3", within = frame)
	if grip == nil { testing.expect(t, false, "its right grip"); return }
	at := session.center(grip)
	session.drag(s, at, at - {width(frame), 0})
	session.frames(s, 2)
	frame = drawn(s, "internal_view_colour")
	testing.expectf(t, frame != nil && width(frame) >= WIDE_PX, "never under what is in it: %v", frame != nil ? frame.rect : ui.Rect{})
}

// The Detach icon: an internal window where the dialog was; in each frame the view is drawn in one place only.
@(test)
the_detach_icon_floats_the_dialog_where_it_is :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "ask"
	s := win_start(t, &r)
	dialog := wait_drawn(s, "modal_view_ask")
	if dialog == nil { return }
	was := dialog.rect
	session.click(s, "view_detach")
	shown_at: ui.Rect
	for i in 0 ..< FRAMES_MAX {
		d, w := drawn(s, "modal_view_ask"), drawn(s, "internal_view_ask")
		testing.expectf(t, (d != nil) != (w != nil), "frame %d: drawn in one place (dialog %v, window %v)", i, d != nil, w != nil)
		if w != nil { shown_at = w.rect; break }
		session.frame(s)
	}
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
	testing.expectf(t, near(shown_at.min, was.min) && near(shown_at.max, was.max), "where the dialog was: %v, then %v", was, shown_at)
	testing.expect(t, drawn(s, "modal_scrim_view_ask") == nil, "no scrim: not modal")
	testing.expect(t, ui.view_is_open(&r.views, "ask"))
}

// A drag of a dialog's header past the threshold: an internal window under the pointer, at once.
@(test)
a_dialog_s_header_dragged_detaches_it :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "ask"
	s := win_start(t, &r)
	dialog := wait_drawn(s, "modal_view_ask")
	header := session.find(s, "view_header")
	if dialog == nil || header == nil { return }
	was := dialog.rect
	from := grab_point(header)
	session.drag(s, from, from + DRAG)
	w := wait_drawn(s, "internal_view_ask")
	if w == nil { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
	testing.expectf(t, near(w.rect.min, was.min + DRAG), "under the pointer: %v, the dialog was at %v", w.rect.min, was.min)
	testing.expect(t, drawn(s, "modal_view_ask") == nil, "the dialog went")
}

// Escape during the drag of a dialog's header: the dialog shows back where it was in the frame of the Escape, never
// a frame with the view in neither place or in both.
@(test)
escape_during_a_header_drag_puts_the_dialog_back :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "ask"
	s := win_start(t, &r)
	dialog := wait_drawn(s, "modal_view_ask")
	header := session.find(s, "view_header")
	if dialog == nil || header == nil { return }
	was := dialog.rect
	from := grab_point(header)
	session.press(s, from)
	session.move(s, from + DRAG * 0.5)
	session.move(s, from + DRAG)
	testing.expect(t, drawn(s, "internal_view_ask") != nil, "dragged: an internal window")
	session.key(s, .Escape)
	for i in 0 ..< 4 {
		d, w := drawn(s, "modal_view_ask"), drawn(s, "internal_view_ask")
		testing.expectf(t, (d != nil) != (w != nil), "frame %d: drawn in one place (dialog %v, window %v)", i, d != nil, w != nil)
		if d != nil { testing.expectf(t, near(d.rect.min, was.min) && near(d.rect.max, was.max), "where it was: %v, now %v", was, d.rect) }
		session.frame(s)
	}
	session.release(s, from + DRAG)
	session.frames(s, 2)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Dialog)
	testing.expect(t, drawn(s, "modal_view_ask") != nil, "a dialog still")
}

// Its header moves it, its corner resizes it, and the rect is remembered once let go.
@(test)
an_internal_window_moves_and_resizes :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "ask"
	s := win_start(t, &r)
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Win) -> bool { return ui.view_is_open(&r.views, "ask") }, "it to open")
	ui.view_present(&r.views, "ask", .Internal)
	w := wait_drawn(s, "internal_view_ask")
	if w == nil { return }
	was := w.rect
	header := session.get(s, "view_header", within = w)
	from := grab_point(header)
	session.drag(s, from, from + DRAG)
	session.frames(s, 2)
	w = drawn(s, "internal_view_ask")
	if w == nil { return }
	testing.expectf(t, near(w.rect.min, was.min + DRAG) && near(w.rect.max, was.max + DRAG), "moved by the pointer: %v, then %v", was, w.rect)

	moved := w.rect
	grip := session.get(s, "view_grip7", within = w)   // (the bottom right corner)
	at := session.center(grip)
	session.drag(s, at, at + GROW)
	session.frames(s, 2)
	w = drawn(s, "internal_view_ask")
	if w == nil { return }
	testing.expectf(t, near(w.rect.min, moved.min) && near(w.rect.max, moved.max + GROW), "the corner held follows, the other stays: %v, then %v", moved, w.rect)

	text, ok := store.get(&r.views.memory, "ask")
	m, parsed := ui.views_parse(text)
	testing.expect(t, ok && parsed, "remembered")
	sc := s.state.scale
	testing.expectf(t, abs(f32(m.internal[2]) * sc - (w.rect.max.x - w.rect.min.x)) <= EPS, "its width remembered: %v", m.internal)
	testing.expect_value(t, m.as, ui.View_Presentation.Internal)
}

// Re-attach brings it back home, a dialog; Close and Escape end it with VIEW_CANCELLED.
@(test)
an_internal_window_reattaches_and_closes :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	r.want = "ask"
	s := win_start(t, &r)
	wait_drawn(s, "modal_view_ask")
	session.click(s, "view_detach")
	wait_drawn(s, "internal_view_ask")
	session.click(s, "view_reattach")
	for i in 0 ..< FRAMES_MAX {
		d, w := drawn(s, "modal_view_ask"), drawn(s, "internal_view_ask")
		testing.expectf(t, (d != nil) != (w != nil), "frame %d: drawn in one place", i)
		if d != nil { break }
		session.frame(s)
	}
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Dialog)
	testing.expect(t, ui.view_is_open(&r.views, "ask"), "re-attach is not a close")
	testing.expect_value(t, len(r.answers), 0)

	// its Close
	session.click(s, "view_detach")
	wait_drawn(s, "internal_view_ask")
	session.click(s, "view_close")
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Win) -> bool { return len(r.answers) >= 1 }, "the answer")
	testing.expect_value(t, r.answers[0], ui.VIEW_CANCELLED)

	// Escape, the focus inside it (it went to its first stop as it showed)
	r.want = "ask"   // (it opens where it was: an internal window)
	w := wait_drawn(s, "internal_view_ask")
	if w == nil { return }
	testing.expect(t, focus_within(s, w), "the focus went into it")
	session.key(s, .Escape)
	session.wait_until(s, &r, proc(s: ^session.Session, r: ^Win) -> bool { return len(r.answers) >= 2 }, "the answer")
	testing.expect_value(t, r.answers[1], ui.VIEW_CANCELLED)
}

// Two internal windows: the one pressed comes in front (built after the other); neither blocks the page.
@(test)
a_press_brings_an_internal_window_to_the_front :: proc(t: ^testing.T) {
	r: Win
	defer win_end(&r)
	_ = store.set(&r.views.memory, "ask", ui.views_format({as = .Internal, internal = {100, 100, 360, 240}}))
	_ = store.set(&r.views.memory, "other", ui.views_format({as = .Internal, internal = {200, 160, 360, 240}}))
	r.want = "ask"
	s := win_start(t, &r)
	wait_drawn(s, "internal_view_ask")
	r.want = "other"
	wait_drawn(s, "internal_view_other")
	testing.expect(t, order(s, "internal_view_other") > order(s, "internal_view_ask"), "the last opened in front")
	// (a point of `ask` that `other` does not cover)
	session.click_at(s, {120, 130})
	session.frames(s, 2)
	testing.expect(t, order(s, "internal_view_ask") > order(s, "internal_view_other"), "the one pressed in front")
	testing.expect(t, !ui.views_hold_keys(&r.views), "an internal window holds no key")
}

// Its place among the root's boxes: the later is drawn over the earlier.
@(private = "file")
order :: proc(s: ^session.Session, name: string) -> int {
	b := session.find(s, name)
	i := 0
	for c := s.state.root.first; c != nil; c = c.next {
		if c == b { return i }
		i += 1
	}
	return -1
}

// Whether the focused box is `root` or under it.
@(private = "file")
focus_within :: proc(s: ^session.Session, root: ^ui.Box) -> bool {
	for b := s.state.boxes[s.state.focus_key] or_else nil; b != nil; b = b.parent {
		if b == root { return true }
	}
	return false
}
