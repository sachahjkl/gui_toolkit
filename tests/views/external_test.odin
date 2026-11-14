package views_test

// The External presentation (src/md/features/views.md, section 4) on the test backend (session.view_windows): a view
// moved into a window of its own never leaves a frame where it is nowhere, and is in two places for one frame at most;
// the window's system close re-attaches it; its Close and Escape close it; the focus goes into it; a refused window
// floats and says so; `moved` follows it; a drag released outside the owner opens a window there (not where positions
// are unknown); a window's header dragged onto the owner's dock target docks it.

import "core:testing"
import "../../src/platform"
import store "../../src/store"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") WINDOW :: [2]int{900, 640}
@(private = "file") FRAMES_MAX :: 40   // (more than the unseen layouts of a window and its show)

@(private = "file")
Ext :: struct {
	views:   ui.Views,
	want:    string,                // open in the next build
	answers: [dynamic]int,
	moves:   [dynamic]^platform.Window,   // what `moved` got
	frame:   bool,                  // build views_frame (its dock targets)
}

@(private = "file")
ext_build :: proc(s: ^session.Session) {
	r := (^Ext)(s.user)
	// (once the backend is set: the first frame of session.start comes before it)
	if r.want != "" && ui.views_windows_ready(&r.views) { ui.view_open(&r.views, r.want, r); r.want = "" }
	if code, ok := ui.view_ended(&r.views, "ask"); ok { append(&r.answers, code) }
	if r.frame {
		if ui.views_frame(&r.views) { ui.label("The page###page") }
	} else {
		ui.label("The page###page")
	}
}

@(private = "file")
ext_view :: proc(v: ^ui.View, r: ^Ext) {
	if ui.dialog_body("ext_body") { ui.label("What is in it###ext_words") }
	if ui.dialog_buttons("ext_buttons") { _ = ui.button("ext_ok", "OK") }
}

@(private = "file")
ext_start :: proc(t: ^testing.T, r: ^Ext, o := session.Windows_Options{}, first: Maybe(ui.View_Presentation) = nil) -> ^session.Session {
	moved :: proc(data: rawptr, win: ^platform.Window) { append(&(^Ext)(data).moves, win) }
	ui.view_register(&r.views, "ask", ext_view, ui.View_Options{title = "Question", first = first, moved = moved})
	s := session.start(t, {size = WINDOW, user = r, build = ext_build})
	ui.views_set_windows(&r.views, session.view_windows(s, o))
	return s
}

@(private = "file")
ext_end :: proc(r: ^Ext) {
	ui.views_destroy(&r.views)
	delete(r.answers)
	delete(r.moves)
}

// The box `name` built in the last build of `s` and not unseen.
@(private = "file")
drawn :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	if s == nil { return nil }
	b := session.find(s, name)
	if b == nil || b.last_build != s.state.build_index || b.transparency >= 1 { return nil }
	return b
}

// The view's window, shown, with its frame built in its last build.
@(private = "file")
window_drawn :: proc(s: ^session.Session, r: ^Ext) -> ^session.Session {
	w := session.view_window(s, &r.views, "ask")
	if !session.window_shown(w) || drawn(w, "external_view_ask") == nil { return nil }
	return w
}

// Frames until `ready`, FRAMES_MAX at most; false: the test says what it waited for.
@(private = "file")
wait :: proc(s: ^session.Session, r: ^Ext, ready: proc(s: ^session.Session, r: ^Ext) -> bool, what: string, loc := #caller_location) -> bool {
	for _ in 0 ..< FRAMES_MAX {
		if ready(s, r) { return true }
		session.frame(s)
	}
	testing.expectf(s.t, false, "%s not in %d frames (it is %v)", what, FRAMES_MAX, ui.view_presentation(&r.views, "ask"), loc = loc)
	return false
}

@(private = "file")
shown_as_window :: proc(s: ^session.Session, r: ^Ext) -> ^session.Session {
	if !wait(s, r, proc(s: ^session.Session, r: ^Ext) -> bool { return window_drawn(s, r) != nil }, "its window") { return nil }
	return window_drawn(s, r)
}

// The dialog moves into a window: every frame shows it somewhere, and in both places for one frame at most (the
// window's first picture is drawn before the dialog goes). Then the focus is in the window, and `moved` was told.
@(test)
a_dialog_moves_into_a_window_with_no_flash :: proc(t: ^testing.T) {
	r: Ext
	defer ext_end(&r)
	r.want = "ask"
	s := ext_start(t, &r)
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "modal_view_ask") != nil }, "the dialog") { return }
	ui.view_present(&r.views, "ask", .External)
	both, done := 0, false
	for i in 0 ..< FRAMES_MAX {
		session.frame(s)
		d, w := drawn(s, "modal_view_ask") != nil, window_drawn(s, &r) != nil
		testing.expectf(t, d || w, "frame %d: drawn nowhere", i)
		if d && w { both += 1 }
		if w && !d { done = true; break }
	}
	testing.expect(t, done, "in its window at last")
	testing.expectf(t, both <= 1, "in two places for %d frames", both)
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.External)
	w := window_drawn(s, &r)
	if w == nil { return }
	testing.expect(t, w.win.active && !s.win.active, "the window is the active one")
	testing.expectf(t, session.focused_name(w) != "", "the focus is in the window")
	testing.expect(t, len(r.moves) == 1 && r.moves[0] == w.win, "moved: to the window")
}

// The system's close of the window re-attaches the view: a dialog again, still open, its window gone, its size kept.
@(test)
the_system_close_reattaches :: proc(t: ^testing.T) {
	r: Ext
	defer ext_end(&r)
	r.want = "ask"
	s := ext_start(t, &r)
	session.frames(s, 3)
	ui.view_present(&r.views, "ask", .External)
	w := shown_as_window(s, &r)
	if w == nil { return }
	session.system_close(w)
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "modal_view_ask") != nil && session.view_window(s, &r.views, "ask") == nil }, "the dialog back, the window gone") { return }
	testing.expect(t, ui.view_is_open(&r.views, "ask"), "still open")
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Dialog)
	testing.expect_value(t, len(r.answers), 0)
	m := ui.views_parse(store_text(&r.views, "ask")) or_else ui.View_Memory{}
	testing.expectf(t, m.window[0] > 0 && m.window[1] > 0, "its window's size remembered: %v", m.window)
	testing.expect(t, s.win.active, "the owner has the user back")
}

// The window's Close button closes the view (cancelled); Escape too.
@(test)
the_window_s_close_and_escape_close_the_view :: proc(t: ^testing.T) {
	r: Ext
	defer ext_end(&r)
	r.want = "ask"
	s := ext_start(t, &r, first = .External)
	w := shown_as_window(s, &r)
	if w == nil { return }
	b := drawn(w, "view_close")
	if b == nil { testing.expect(t, false, "its Close button"); return }
	session.click_at(w, session.center(b))
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return len(r.answers) == 1 }, "the answer") { return }
	testing.expect_value(t, r.answers[0], ui.VIEW_CANCELLED)
	session.frames(s, 2)
	testing.expect(t, session.view_window(s, &r.views, "ask") == nil, "its window went")

	r.want = "ask"
	w = shown_as_window(s, &r)
	if w == nil { return }
	session.key(w, .Escape)
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return len(r.answers) == 2 }, "Escape's answer") { return }
	testing.expect_value(t, r.answers[1], ui.VIEW_CANCELLED)
}

// No window can open: a view that opens as External floats inside its owner, and the owner says why.
@(test)
a_refused_window_floats_and_says_so :: proc(t: ^testing.T) {
	r: Ext
	defer ext_end(&r)
	r.want = "ask"
	s := ext_start(t, &r, {refuse = true}, first = .External)
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "internal_view_ask") != nil }, "the floating window") { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
	testing.expect(t, session.find_text(s, "No window") != nil, "the toast says why")
	testing.expect(t, len(s.windows) == 0, "no window")
}

// A floating window's header dragged and let go outside the owner: a window of its own there. Where positions are
// unknown (Wayland), it stays a floating window.
@(test)
a_drag_released_outside_opens_a_window_there :: proc(t: ^testing.T) {
	for no_positions in ([]bool{false, true}) {
		r: Ext
		r.want = "ask"
		s := ext_start(t, &r, {no_positions = no_positions}, first = .Internal)
		ok := wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "internal_view_ask") != nil }, "the floating window")
		header := drawn(s, "view_header")
		if ok && header != nil {
			from := [2]f32{header.rect.min.x + 10, (header.rect.min.y + header.rect.max.y) * 0.5}
			out := [2]f32{f32(WINDOW.x) + 200, from.y}
			session.press(s, from)
			session.move(s, from + {40, 0})
			session.move(s, out)
			session.release(s, out)
			if no_positions {
				session.frames(s, 6)
				testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Internal)
				testing.expect(t, len(s.windows) == 0, "Wayland: no window")
			} else if w := shown_as_window(s, &r); w != nil {
				testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.External)
				at := platform.client_origin(w.win)
				testing.expectf(t, at.x >= WINDOW.x, "opened where it was let go: %v", at)
			}
		}
		ext_end(&r)
	}
}

// A window's header dragged over the owner shows the owner's dock targets; let go on the right one, the view docks
// there and its window goes.
@(test)
a_window_dragged_onto_a_target_docks :: proc(t: ^testing.T) {
	r: Ext
	defer ext_end(&r)
	r.want = "ask"
	r.frame = true
	s := ext_start(t, &r, first = .External)
	w := shown_as_window(s, &r)
	if w == nil { return }
	header := drawn(w, "view_header")
	if header == nil { testing.expect(t, false, "its header"); return }
	// (the pointer as the system moves it: a place of the screen, in the window's pixels wherever the window is now)
	screen :: proc(w: ^session.Session, at: [2]int) -> [2]f32 {
		o := platform.client_origin(w.win)
		return {f32(at.x - o.x), f32(at.y - o.y)}
	}
	o := platform.client_origin(w.win)
	start := [2]int{o.x + int(header.rect.min.x) + 10, o.y + int((header.rect.min.y + header.rect.max.y) * 0.5)}
	session.press(w, screen(w, start))
	session.move(w, screen(w, start + {40, 0}))
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "view_target__Right") != nil }, "the owner's targets") { return }
	target := drawn(s, "view_target__Right")
	so := platform.client_origin(s.win)
	at := [2]int{so.x + int(session.center(target).x), so.y + int(session.center(target).y)}
	session.move(w, screen(w, at))
	session.frames(s, 2)
	session.move(w, screen(w, at))
	session.release(w, screen(w, at))
	if !wait(s, &r, proc(s: ^session.Session, r: ^Ext) -> bool { return drawn(s, "view_panel_view_ask") != nil }, "the panel") { return }
	testing.expect_value(t, ui.view_presentation(&r.views, "ask"), ui.View_Presentation.Panel)
	session.frames(s, 2)
	testing.expect(t, session.view_window(s, &r.views, "ask") == nil, "its window went")
}

// The text of a view's line in the memory ("": none).
@(private = "file")
store_text :: proc(vs: ^ui.Views, id: string) -> string {
	text, _ := store.get(&vs.memory, id)
	return text
}
