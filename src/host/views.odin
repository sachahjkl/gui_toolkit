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

// A view's window: its Host (first: a hook's ^Host is the View_Window), and the window whose views it shows.
View_Window :: struct {
	host:  Host,
	owner: ^Host,
	shown: bool,   // ui's step showed it: from now on its frames draw pictures
}

// The View_Window of a view's window's Host.
@(private = "file")
view_window_of :: proc(h: ^Host) -> ^View_Window { return (^View_Window)(h) }

// The backend of the views' windows of a program's windows, all of them (the hosts on `sh`): a view's window is made
// after the frames of the Host that owns the view (View_Window_Ask.owner_state). Refused for an owner State that is no
// Host's. An offscreen owner (a program's test: session.attach) gets offscreen windows, which build and draw no
// picture; session.view_window gives each to the test (src/md/features/views.md, section 4.1, decision 18).
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
	if owner == nil || owner.win == nil { return }
	offscreen := platform.is_offscreen(owner.win)
	vw := new(View_Window)
	vw.owner = owner
	h := &vw.host
	// (the program's decorations or the system's, as its owner's window: no frame of the system's flashes first)
	o := Open_Options{title = ask.title, size = ask.size, under_children = ask.under_children, integrated_title = ask.integrated_title, headless = offscreen}
	// (its user is the owner's: the program's hooks given to it read the program's data, as in its own windows)
	if !host_open(h, sh, o, proc(h: ^Host, size: Vec2) { ui.views_window_build() }, owner.user) {
		free(vw)
		return
	}
	h.owner = owner
	if offscreen {
		// (the owner's scale, as a window of the system on its monitor: the size asked stays logical)
		platform.set_offscreen_dpi(h.win, int(owner.win.dpi_scale * 96 + 0.5))
		platform.set_offscreen_active(h.win, false)   // (hidden: the user is not in it before its show)
	}
	view_window_follow(vw)
	// (its State follows its owner's by itself: ui.State.style_owner, its base style, its zoom, its theme, its fonts)
	h.params = proc(h: ^Host, p: ^ui.Build_Params) { p.inactive = !h.win.active }
	// (hidden, its unseen layouts are built and never drawn: a picture would put a buffer on a surface with no role
	// yet, and on Wayland the role given to it at the show is a protocol error, the end of the connection)
	h.hold = proc(h: ^Host, size: Vec2) -> int { return view_window_of(h).shown ? 0 : 1 }
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
	// (offscreen, no system activates it: the user is in it now, as a window of the system raised)
	if vw.host.win.offscreen {
		platform.set_offscreen_active(vw.owner.win, false)
		platform.set_offscreen_active(vw.host.win, true)
	}
}

@(private = "file")
view_window_close :: proc(user: rawptr, handle: rawptr) {
	vw := (^View_Window)(handle)
	sh := vw.host.shared
	// (offscreen: the owner gets the user back, as ui's raise_window of the owner does for a window of the system)
	if vw.host.win.offscreen && vw.host.win.active && vw.owner.win != nil { platform.set_offscreen_active(vw.owner.win, true) }
	for x, i in sh.views {
		if x == vw { ordered_remove(&sh.views, i); break }
	}
	host_close(&vw.host)
	free(vw)
}

// What a view's window takes from its owner Host at each frame: its ground (the theme's), the frames owed after an
// input, partial redraw, and the program's input hook (its terminals take their keys before the interface, in a view's
// window too). Its title bar's dark or light follows the owner's window (ui.views_windows_step).
@(private = "file")
view_window_follow :: proc(vw: ^View_Window) {
	h, o := &vw.host, vw.owner
	h.background = o.background
	h.after_input = o.after_input
	h.partial_redraw = o.partial_redraw
	h.input = o.input
}

// After a frame of `h`, outside any build: the step of its views' windows (ui.views_windows_step), then a frame of each
// of them, in the order they opened. A window the step closed is not in the list any more. A frame of `h` that came
// only from the pointer moving over it (ui.pointer_only_build) changed nothing they show: a view's window makes a frame
// then only when it is due on its own (its input, an animation, posted calls, a wake, frames owed).
@(private)
host_views_frames :: proc(h: ^Host) {
	if ui.building() { return }
	ui.views_windows_step(&h.state)
	sh := h.shared
	quiet := ui.pointer_only_build(&h.state)
	// (a frame may open or close another: the list is read again each time)
	for i := 0; i < len(sh.views); i += 1 {
		vw := sh.views[i]
		if vw.owner != h || host_done(&vw.host) { continue }
		view_window_follow(vw)
		v := &vw.host
		if quiet && v.settle == 0 && !host_close_waits(v) && !platform.events_waiting(v.win) && !ui.view_window_due(&v.state) { continue }
		host_frame(v)
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
