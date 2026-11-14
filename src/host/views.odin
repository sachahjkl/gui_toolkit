package tk_host

// The windows of views (src/md/features/views.md, section 4.1): ui's View_Windows for the windows of a program. Each
// view's window is a Host on the program's Shared, with its own ui.State on the program's Views and its own surface.
// Its frames come after its owner's, inside the owner's host_frame (host_views_frames); hosts_due and hosts_wait count
// them. The program's loop does not change:
//
//   ui.views_set_windows(&app.views, host.view_windows(&app.shared))   once, at start-up, for every window
//
// One backend for the program: each view's owner State is a Host's (a main window, an editor's window, a view's window),
// and that Host makes its frames. Its system close re-attaches the view (ui.view_window_close_asked); its style follows
// its owner's (ui.style_follow, in ui.views_windows_step).

import "../platform"
import "../ui"

// A view's window: its Host, and the window whose views it shows.
View_Window :: struct {
	host:  Host,
	owner: ^Host,
	shown: bool,   // ui's step showed it: from now on its frames draw pictures
}

// The backend of the views' windows of a program's windows, all of them (the hosts on `sh`): a view's window is made
// after the frames of the Host that owns the view (View_Window_Ask.owner_state). Refused for an offscreen owner (a
// test's host: session.view_windows is the test's backend), and for an owner State that is no Host's.
view_windows :: proc(sh: ^Shared) -> ui.View_Windows {
	return {open = view_window_open, show = view_window_show, hide = view_window_hide, close = view_window_close, user = sh}
}

// The Host whose State is `st`: one of `sh`'s windows (nil: none).
@(private = "file")
host_of_state :: proc(sh: ^Shared, st: ^ui.State) -> ^Host {
	if st == nil { return nil }
	for h := sh.hosts; h != nil; h = h.next { if &h.state == st { return h } }
	return nil
}

// (its owner hid: off the screen, no picture until it shows again)
@(private = "file")
view_window_hide :: proc(user: rawptr, handle: rawptr) {
	vw := (^View_Window)(handle)
	vw.shown = false
	host_hide(&vw.host)
}

@(private = "file")
view_window_open :: proc(user: rawptr, ask: ui.View_Window_Ask) -> (state: ^ui.State, win: ^platform.Window, handle: rawptr) {
	sh := (^Shared)(user)
	owner := host_of_state(sh, ask.owner_state)
	if owner == nil || owner.win == nil || platform.is_offscreen(owner.win) { return }
	vw := new(View_Window)
	vw.owner = owner
	h := &vw.host
	o := Open_Options{title = ask.title, size = ask.size, under_children = ask.under_children}
	if !host_open(h, sh, o, proc(h: ^Host, size: Vec2) { ui.views_window_build() }, vw) {
		free(vw)
		return
	}
	h.background = owner.background
	h.after_input = owner.after_input
	h.partial_redraw = owner.partial_redraw
	h.params = proc(h: ^Host, p: ^ui.Build_Params) { p.inactive = !h.win.active }
	// (hidden, its unseen layouts are built and never drawn: a picture would put a buffer on a surface with no role
	// yet, and on Wayland the role given to it at the show is a protocol error, the end of the connection)
	h.hold = proc(h: ^Host, size: Vec2) -> int { return (^View_Window)(h.user).shown ? 0 : 1 }
	h.close_asked = proc(h: ^Host) { ui.view_window_close_asked(&h.state) }
	if at, ok := ask.at.?; ok { platform.move_window(h.win, at.x, at.y) }
	append(&sh.views, vw)
	return &h.state, h.win, vw
}

@(private = "file")
view_window_show :: proc(user: rawptr, handle: rawptr) {
	vw := (^View_Window)(handle)
	vw.shown = true
	host_show(&vw.host)
	platform.raise_window(vw.host.win)
}

@(private = "file")
view_window_close :: proc(user: rawptr, handle: rawptr) {
	vw := (^View_Window)(handle)
	sh := vw.host.shared
	for x, i in sh.views {
		if x == vw { ordered_remove(&sh.views, i); break }
	}
	host_close(&vw.host)
	free(vw)
}

// After a frame of `h`, outside any build: the step of its views' windows (ui.views_windows_step), then a frame of each
// of them, in the order they opened. A window the step closed is not in the list any more.
@(private)
host_views_frames :: proc(h: ^Host) {
	if ui.building() { return }
	ui.views_windows_step(&h.state)
	sh := h.shared
	// (a frame may open or close another: the list is read again each time)
	for i := 0; i < len(sh.views); i += 1 {
		vw := sh.views[i]
		if vw.owner != h || platform.is_closed(vw.host.win) { continue }
		host_frame(&vw.host)
	}
}

// `hosts` and the windows of their views, theirs too.
@(private)
host_with_views :: proc(hosts: []^Host) -> []^Host {
	if len(hosts) == 0 || hosts[0].shared == nil || len(hosts[0].shared.views) == 0 { return hosts }
	all := make([dynamic]^Host, 0, len(hosts) + len(hosts[0].shared.views), context.temp_allocator)
	append(&all, ..hosts)
	for i := 0; i < len(all); i += 1 {
		for vw in all[i].shared.views {
			if vw.owner == all[i] { append(&all, &vw.host) }
		}
	}
	return all[:]
}
