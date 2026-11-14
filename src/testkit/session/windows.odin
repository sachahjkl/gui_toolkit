package tk_session

// The test backend of the views' windows (ui.View_Windows; src/md/features/views.md, section 3.7): each window a view
// asks for is an offscreen window with a ui.State of its own on the application's Views, its fonts and its theme. It is
// a session of its own: find, click, key, focused_name work on it. Its frames are the application's: a frame of it, or
// of the application, makes the application's frame, then the step of the windows (ui.views_windows_step), then each
// window's.
//
//   ui.views_set_windows(&app.views, session.view_windows(s))
//   w := session.view_window(s, &app.views, "props")   // the window "props" is in (nil: none)

import "core:strings"
import "../../platform"
import "../../ui"

// What the test backend does.
Windows_Options :: struct {
	refuse:       bool,   // every window is refused: the view floats inside its owner, or stays where it was, and says so
	no_positions: bool,   // as on Wayland: no drop outside the owner, no drag of a window onto the owner's targets
}

// The backend of the views' windows of the application of `s` (one of `start`).
view_windows :: proc(s: ^Session, o := Windows_Options{}) -> ui.View_Windows {
	s.windows_o = o
	return {open = window_open, show = window_show, close = window_close, no_positions = o.no_positions, user = s}
}

// The session of the window a view is in now (nil: it is in none).
view_window :: proc(s: ^Session, vs: ^ui.Views, id: string, instance := "") -> ^Session {
	st := ui.view_window_state(vs, id, instance)
	if st == nil { return nil }
	for c in s.windows { if c.state == st { return c } }
	return nil
}

// Whether a view's window is on the screen (shown by the step, not closed).
window_shown :: proc(s: ^Session) -> bool { return s != nil && !s.hidden }

// The system asks the window to close (its title bar's cross, Alt+F4).
system_close :: proc(s: ^Session) {
	event(s, {kind = .Close})
	frames(s, INPUT_FRAMES)
}

@(private = "file")
window_open :: proc(user: rawptr, ask: ui.View_Window_Ask) -> (state: ^ui.State, win: ^platform.Window, handle: rawptr) {
	p := (^Session)(user)
	if p.windows_o.refuse || p.own == nil { return }
	dpi := p.win.dpi_scale
	w := platform.open_window_offscreen(ask.title, {int(f32(ask.size.x) * dpi), int(f32(ask.size.y) * dpi)}, dpi)
	if w == nil { return }
	if at, ok := ask.at.?; ok { platform.move_window(w, at.x, at.y) }
	c := new(Session)
	c.t, c.test, c.ctx, c.thread, c.parent, c.win = p.t, p.test, p.ctx, p.thread, p, w
	c.name, c.out = strings.clone(p.name), strings.clone(p.out)
	c.hidden = true
	po := p.own
	own := new(Own)
	own.build = proc(s: ^Session) { ui.views_window_build() }
	own.ui_font, own.mono_font, own.icon_font = po.ui_font, po.mono_font, po.icon_font
	own.animations, own.no_renderer = po.animations, true
	c.own = own
	ui.init(&own.state, &po.fonts, &po.theme)
	own.state.icon_font, own.state.mono_font = po.icon_font, po.mono_font
	c.state = &own.state
	ui.set_clock(c.state, &p.clock)
	ui.use(p.state)   // (the State in use stays the application's)
	append(&p.windows, c)
	return c.state, c.win, c
}

@(private = "file")
window_show :: proc(user: rawptr, handle: rawptr) {
	p, c := (^Session)(user), (^Session)(handle)
	c.hidden = false
	// (shown and activated: the user is in it now)
	platform.set_offscreen_active(p.win, false)
	platform.set_offscreen_active(c.win, true)
}

@(private = "file")
window_close :: proc(user: rawptr, handle: rawptr) {
	p, c := (^Session)(user), (^Session)(handle)
	for x, i in p.windows {
		if x == c { ordered_remove(&p.windows, i); break }
	}
	was_active := !c.hidden && c.win.active
	window_end(c)
	if was_active { platform.set_offscreen_active(p.win, true) }
}

// A window's session ends (its State, its window; the fonts and the theme are its parent's).
@(private)
window_end :: proc(c: ^Session) {
	ui.set_clock(c.state, nil)
	ui.destroy(&c.own.state)
	platform.destroy_window(c.win)
	free(c.own)
	delete(c.name)
	delete(c.out)
	free(c)
}

// After a frame of the application of `p`: the step of its views' windows, then a frame of each, in the order they
// opened; a window the system asked to close tells its view (ui.view_window_close_asked: it re-attaches).
@(private)
windows_frames :: proc(p: ^Session) {
	if p.own == nil || p.parent != nil || ui.building() { return }
	ui.views_windows_step(p.state)
	for i := 0; i < len(p.windows); i += 1 {
		c := p.windows[i]
		own_frame(c)
		if platform.is_closed(c.win) {
			platform.cancel_close(c.win)
			ui.view_window_close_asked(c.state)
		}
	}
	ui.use(p.state)
}
