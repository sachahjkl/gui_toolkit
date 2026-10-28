#+build linux
package platform

// The Linux window backend: the same public API as platform_win32.odin (open_window, poll_events, the window-state
// calls, text clipboard, config_dir...), dispatching to Wayland (window_wl_linux.odin) or X11 (window_x11_linux.odin),
// chosen at open_window from the environment (choose_backend in linux_lib.odin). Everything a backend does not vary
// (the offscreen path, the event queue bookkeeping, inject_event) lives here so both backends share it, exactly as the
// Win32 file is a single backend.
//
// Everything is in physical pixels; `window.dpi_scale` is the monitor's scale (the Wayland fractional-scale value, or
// Xft.dpi/96 on X11). A backend fills `size`, `dpi_scale`, `focused`, `active` and queues Events into `w.events`; this
// file hands them out with the same re-entrancy and drop-what-was-returned rules as Win32.

import "core:time"
import "core:strings"
import "core:sys/posix"

// The window state each backend keeps, behind one pointer so this struct stays free of Wayland and XCB types. The
// backend allocates it in open_window and frees it in destroy_window.
@(private) Wl_Window :: struct {}   // defined fully in window_wl_linux.odin
@(private) X11_Window :: struct {}  // defined fully in window_x11_linux.odin

Native_Window :: struct {
	backend:      Backend_Kind,
	wl:           rawptr,           // ^Wl_Window_State when backend == .Wayland
	x11:          rawptr,           // ^X11_Window_State when backend == .X11
	cursor:       Cursor,
	closed:       bool,
	in_poll:      bool,
	integrated:   bool,             // set_integrated_title: the app draws the title bar (client-side decorations)
	fullscreen:   bool,
	maximized:    bool,
	minimized:    bool,
	dark_title:   bool,
	display:      Display_Info,
	display_stale: bool,
	injected:     [dynamic]Event,   // inject_event
	returned:     int,
	keep_events:  bool,
	paint_requested: bool,
	stats:        Pump_Stats,
	buttons_down: Mouse_Buttons,
	// cursor state shared by both backends (cursors_linux.odin)
	custom_cursors: [dynamic]Custom_Entry,
	custom_cursor:  Custom_Cursor,
	custom_fallback: Cursor,
	// offscreen window (open_window_offscreen): no surface at all, so it runs with no display server (a service, an SSH
	// login, a CI runner). Input comes only through inject_event; an eventfd stands in for the message queue.
	offscreen:    bool,
	off_event:    posix.FD,         // eventfd: wait_event waits on it, wake / inject_event write to it
	off_state:    Off_State,
	off_place:    [4]int,
	off_visible:  bool,
	// drag and drop (dragdrop_wl_linux.odin / dragdrop_x11_linux.odin), made on first use
	dnd:          ^Dnd_State,
	// icons of the notification area this window owns (tray_linux.odin)
	trays:        [dynamic]^Tray,
	// the accessibility adapter / tree (a11y_linux.odin), nil until an assistive technology connects
	a11y:         rawptr,
}

// The emulated state of an offscreen window (mirrors Win32).
@(private) Off_State :: enum u8 { Normal, Minimized, Maximized, Fullscreen }

@(private, thread_local) pumping: int

// eventfd syscall (core:sys/posix does not wrap it): a counter the loop waits on and wake writes to, the Linux
// counterpart of Win32's auto-reset event. EFD_NONBLOCK | EFD_CLOEXEC.
foreign import libc "system:c"
@(default_calling_convention = "c", private)
foreign libc {
	eventfd :: proc(initval: u32, flags: i32) -> i32 ---
	@(link_name="read")  sys_read  :: proc(fd: i32, buf: rawptr, n: uint) -> int ---
	@(link_name="write") sys_write :: proc(fd: i32, buf: rawptr, n: uint) -> int ---
}
@(private) EFD_CLOEXEC :: 0o2000000
@(private) EFD_NONBLOCK :: 0o0004000

// Opens a window on the chosen backend. `size` is logical pixels (scaled by the monitor's DPI). `transparent`: an
// alpha surface the compositor blends (render.init transparent); `integrated_title`: the app draws the title bar
// (client-side decorations). Returns nil when no display server is reachable or the backend could not make the window.
open_window :: proc(title: string, size: [2]int, user: rawptr = nil, on_frame: proc(user: rawptr) = nil, transparent := false, integrated_title := false) -> ^Window {
	kind, missing := choose_backend()
	if kind == .None {
		if missing != "" { report_missing(missing) }
		return nil
	}
	w := new(Window)
	w.user = user
	w.on_frame = on_frame
	w.dpi_scale = 1
	w.focused = true
	w.active = true
	w.display_stale = true
	w.integrated = integrated_title
	w.backend = kind
	ok := false
	switch kind {
	case .Wayland: ok = wl_open(w, title, size, transparent)
	case .X11:     ok = x11_open(w, title, size, transparent)
	case .None:
	}
	if !ok {
		delete(w.events)
		delete(w.injected)
		free(w)
		return nil
	}
	return w
}

// A window with no surface: it renders to an offscreen target and never appears, so it runs where there is no display
// server at all. `size` is the client area in physical pixels (`dpi_scale` is the emulated scale). Mirrors the Win32
// offscreen path exactly; pair with render.init_offscreen. Free with destroy_window.
open_window_offscreen :: proc(title: string, size: [2]int, dpi_scale: f32 = 1, user: rawptr = nil, on_frame: proc(user: rawptr) = nil) -> ^Window {
	_ = title
	fd := eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)
	if fd < 0 { return nil }
	w := new(Window)
	w.user = user
	w.on_frame = on_frame
	w.offscreen = true
	w.off_event = posix.FD(fd)
	w.dpi_scale = dpi_scale > 0 ? dpi_scale : 1
	w.focused = true
	w.active = true
	w.size = {max(size.x, 1), max(size.y, 1)}
	w.off_state = .Normal
	w.off_place = {0, 0, w.size.x, w.size.y}
	return w
}

@(private)
report_missing :: proc(what: string) {
	msg := strings.concatenate({"platform: no window: ", what, "\n"}, context.temp_allocator)
	posix.write(posix.STDERR_FILENO, raw_data(msg), len(msg))
}

destroy_window :: proc(w: ^Window) {
	if w == nil { return }
	clipboard_watch(w, false)
	tray_destroy_all(w)
	dnd_destroy(w)
	a11y_detach(w)
	switch w.backend {
	case .Wayland: wl_destroy(w)
	case .X11:     x11_destroy(w)
	case .None:
	}
	cursors_destroy(w)
	if w.off_event > 0 { posix.close(w.off_event); w.off_event = 0 }
	delete(w.events)
	delete(w.injected)
	chrome_regions_destroy(&w.chrome)
	free(w)
}

////////////////////////////////
// Window state

set_size :: proc(w: ^Window, size: [2]int) {
	if w.offscreen {
		w.size = {max(size.x, 1), max(size.y, 1)}
		w.off_place[2], w.off_place[3] = w.size.x, w.size.y
		return
	}
	px := [2]int{max(int(f32(size.x) * w.dpi_scale), 1), max(int(f32(size.y) * w.dpi_scale), 1)}
	switch w.backend {
	case .Wayland: wl_set_size(w, px)
	case .X11:     x11_set_size(w, px)
	case .None:
	}
}

set_title :: proc(w: ^Window, title: string) {
	if w.offscreen { return }
	switch w.backend {
	case .Wayland: wl_set_title(w, title)
	case .X11:     x11_set_title(w, title)
	case .None:
	}
}

show_window :: proc(w: ^Window) {
	if w.offscreen {
		w.off_visible = true
		return
	}
	switch w.backend {
	case .Wayland: wl_show(w)
	case .X11:     x11_show(w)
	case .None:
	}
}

is_closed :: proc(w: ^Window) -> bool { return w.closed }
is_offscreen :: proc(w: ^Window) -> bool { return w.offscreen }

// Brings an already-shown window to the front (the user asked to switch to it). X11 asks the window manager
// (_NET_ACTIVE_WINDOW); Wayland does not let a client raise itself (the compositor decides), so it is a no-op there.
raise_window :: proc(w: ^Window) {
	if w == nil || w.offscreen { return }
	switch w.backend {
	case .X11:     x11_raise(w)
	case .Wayland: // the compositor owns focus / stacking; a client cannot raise itself
	case .None:
	}
}

// Whether the window is on screen (mapped and not minimized). An offscreen window is never "visible" in this sense.
is_window_visible :: proc(w: ^Window) -> bool {
	if w == nil || w.offscreen { return false }
	return !w.closed && !w.minimized
}

// The native handles a renderer makes a wgpu surface from (neutral; see Surface_Handles). An offscreen window has none.
native_surface_handles :: proc(w: ^Window) -> Surface_Handles {
	if w == nil || w.offscreen { return {} }
	switch w.backend {
	case .Wayland:
		st := wl_state(w)
		if st == nil { return {} }
		return {backend = .Wayland, display = rawptr(wlc.display), surface = rawptr(st.surface)}
	case .X11:
		st := x11_state(w)
		if st == nil { return {} }
		return {backend = .X11, display = rawptr(x11c.c), window = u64(st.id)}
	case .None:
	}
	return {}
}
is_maximized :: proc(w: ^Window) -> bool { return w.offscreen ? w.off_state == .Maximized : w.maximized }
is_minimized :: proc(w: ^Window) -> bool { return w.offscreen ? w.off_state == .Minimized : w.minimized }
is_fullscreen :: proc(w: ^Window) -> bool { return w.offscreen ? w.off_state == .Fullscreen : w.fullscreen }
is_integrated_title :: proc(w: ^Window) -> bool { return w.integrated }

minimize :: proc(w: ^Window) {
	if w.offscreen { w.off_state = .Minimized; return }
	switch w.backend {
	case .Wayland: wl_minimize(w)
	case .X11:     x11_minimize(w)
	case .None:
	}
}

toggle_maximize :: proc(w: ^Window) {
	if w.offscreen { w.off_state = w.off_state == .Maximized ? .Normal : .Maximized; return }
	switch w.backend {
	case .Wayland: wl_set_maximized(w, !w.maximized)
	case .X11:     x11_set_maximized(w, !w.maximized)
	case .None:
	}
}

request_close :: proc(w: ^Window) {
	if w.offscreen { inject_event(w, Event{kind = .Close}); return }
	// the app sees a .Close event and decides; a backend has no "ask to close" of its own, so queue it directly
	inject_event(w, Event{kind = .Close})
	wake(w)
}

set_fullscreen :: proc(w: ^Window, on: bool) {
	if w.offscreen { w.off_state = on ? .Fullscreen : .Normal; return }
	if w.fullscreen == on { return }
	w.fullscreen = on
	w.display_stale = true
	switch w.backend {
	case .Wayland: wl_set_fullscreen(w, on)
	case .X11:     x11_set_fullscreen(w, on)
	case .None:
	}
}

set_integrated_title :: proc(w: ^Window, on: bool) {
	if w.integrated == on { return }
	w.integrated = on
	chrome_regions_clear(&w.chrome)
	if w.offscreen { return }
	switch w.backend {
	case .Wayland: wl_set_decorations(w, !on)
	case .X11:     x11_set_decorations(w, !on)
	case .None:
	}
}

// The title bar the app drew this frame (client pixels): copied, the caller keeps its regions.
set_chrome_regions :: proc(w: ^Window, c: ^Chrome_Regions) {
	chrome_regions_clear(&w.chrome)
	append(&w.chrome.caption, ..c.caption[:])
	append(&w.chrome.holes, ..c.holes[:])
	append(&w.chrome.slanted, ..c.slanted[:])
	append(&w.chrome.overlays, ..c.overlays[:])
	w.chrome.buttons = c.buttons
}

// The system menu at `pos`: Wayland asks the compositor (xdg_toplevel.show_window_menu), X11 has none, so nothing shows
// there. An app with an integrated title bar draws its own menu where this does nothing.
show_system_menu :: proc(w: ^Window, pos: [2]f32) {
	if w.offscreen { return }
	switch w.backend {
	case .Wayland: wl_show_window_menu(w, pos)
	case .X11:
	case .None:
	}
}

// Whether a 1-pixel top line should be drawn over an integrated title bar. The compositors draw their own borders, so
// the toolkit does not need the Windows-10 top-line workaround: always false.
needs_top_border :: proc(w: ^Window) -> bool { return false }

// Thickness of the resize band along the top of an integrated title bar (physical pixels).
resize_border :: proc(w: ^Window) -> int { return max(int(8 * w.dpi_scale), 1) }

// Translucent window (acrylic on Windows): the compositor blends whatever the app leaves transparent when the surface
// has an alpha channel (open the window with render.init transparent). There is no extra backdrop effect to turn on,
// so this reports whether the window was made translucent at all.
set_backdrop :: proc(w: ^Window, on: bool) -> bool {
	if w.offscreen { return false }
	return w.backend == .Wayland ? wl_transparent(w) : x11_transparent(w)
}

// Windows 11's rounded corners / coloured border have no portable counterpart: the compositor decides. No-ops.
set_square_corners :: proc(w: ^Window, square: bool) {}
set_border_color :: proc(w: ^Window, rgb: Maybe(u32)) {}

// Matches the title bar to a dark or light theme. With client-side decorations by libdecor this re-tints them; with
// server-side decorations the compositor follows org.freedesktop.appearance, so this records the preference only.
set_dark_title :: proc(w: ^Window, dark: bool) {
	if w.dark_title == dark { return }
	w.dark_title = dark
	if w.offscreen { return }
	if w.backend == .Wayland { wl_set_dark(w, dark) }
}

// Sets an offscreen window's emulated scale (dpi/96) and resizes its client area to keep the same logical size
// (mirrors Win32). A no-op for a real window.
set_offscreen_dpi :: proc(w: ^Window, dpi: int) {
	if !w.offscreen || dpi <= 0 { return }
	old := max(w.dpi_scale, 0.0625)
	k := (f32(dpi) / 96) / old
	w.dpi_scale = f32(dpi) / 96
	w.size = {max(int(f32(w.size.x) * k + 0.5), 1), max(int(f32(w.size.y) * k + 0.5), 1)}
	w.off_place[2], w.off_place[3] = w.size.x, w.size.y
}

////////////////////////////////
// Event loop

// An opaque wake handle an offscreen window waits on, for a thread that wants to wake the loop (host.post). Pass it
// back to wake_signal. nil for a real window (wake it with `wake`). The eventfd is held for the window's life.
wake_handle :: proc(w: ^Window) -> rawptr { return w != nil && w.offscreen ? rawptr(uintptr(w.off_event)) : nil }

// Signals a wake handle got from wake_handle, from any thread. The neutral form of SetEvent.
wake_signal :: proc(h: rawptr) {
	if h == nil { return }
	one: u64 = 1
	sys_write(i32(uintptr(h)), &one, size_of(one))
}

// Requests a wake-up for the loop (a timer, an animation): write the eventfd, or make the backend send a no-op event.
wake :: proc(w: ^Window) {
	if w.offscreen {
		one: u64 = 1
		sys_write(i32(w.off_event), &one, size_of(one))
		return
	}
	switch w.backend {
	case .Wayland: wl_wake(w)
	case .X11:     x11_wake(w)
	case .None:
	}
}

// Collects pending events. With `wait` the call blocks until at least one arrives (idle = 0 % CPU) or `timeout_ms`
// elapsed (> 0). The returned slice is valid until the next call. Re-entrant calls return nil.
poll_events :: proc(w: ^Window, wait: bool, timeout_ms := 0) -> []Event {
	if w.in_poll { return nil }
	w.in_poll = true
	pumping += 1
	defer { w.in_poll = false; pumping -= 1 }

	if !w.keep_events { drop_returned(w) }
	w.keep_events = false

	if w.offscreen {
		if wait && len(w.events) == 0 && len(w.injected) == 0 { off_wait(w, timeout_ms) }
		off_drain(w)
		take_injected(w)
		w.returned = len(w.events)
		return w.events[:]
	}

	switch w.backend {
	case .Wayland: wl_pump(w, wait, timeout_ms)
	case .X11:     x11_pump(w, wait, timeout_ms)
	case .None:
	}
	take_injected(w)
	w.returned = len(w.events)
	return w.events[:]
}

// Blocks until an event is pending or `timeout_ms` elapsed (0 = no timeout). Consumes nothing (follow with
// render.wait_for_frame then poll_events(w, false), as the Win32 path does).
wait_event :: proc(w: ^Window, timeout_ms := 0) {
	if w.offscreen {
		if len(w.injected) > 0 || len(w.events) > 0 { return }
		off_wait(w, timeout_ms)
		return
	}
	switch w.backend {
	case .Wayland: wl_wait(w, timeout_ms)
	case .X11:     x11_wait(w, timeout_ms)
	case .None:
	}
}

// Waits until `handle` is signaled or `timeout_ms` passed (0: no limit), taking the window's keyboard and mouse input
// as it arrives (time-stamped, kept for the next poll_events). `handle` is a render frame-latency fd (poll(2)-able):
// render.frame_waitable returns one on wgpu. Returns true when the handle was signaled. The frame then starts on fresh
// input, as the Win32 MsgWaitForMultipleObjectsEx path does.
wait_handle :: proc(w: ^Window, handle: rawptr, timeout_ms := 0) -> bool {
	if handle == nil { return true }
	if w.in_poll {
		// a nested call (a frame callback): just wait on the handle, take no input
		return poll_fd_wait(i32(uintptr(handle)), timeout_ms) > 0
	}
	w.in_poll = true
	pumping += 1
	defer { w.in_poll = false; pumping -= 1 }
	if !w.keep_events { drop_returned(w) }
	w.keep_events = true
	fd := i32(uintptr(handle))
	start := time.tick_now()
	for {
		switch w.backend {
		case .Wayland: wl_take_input(w)
		case .X11:     x11_take_input(w)
		case .None:
		}
		left := -1
		if timeout_ms > 0 {
			rem := f64(timeout_ms) - time.duration_milliseconds(time.tick_since(start))
			if rem <= 0 { return poll_fd_wait(fd, 0) > 0 }
			left = int(rem + 0.999)
		}
		// wait on both the render fd and the window's connection fd: whichever wakes first
		conn := w.backend == .Wayland ? wl_fd(w) : x11_fd(w)
		r := poll_two(fd, conn, left)
		if r.rendered { return true }
		if r.timed_out { return false }
		// the connection woke us: loop, take the input it carries, and wait again on what is left of the timeout
	}
}

@(private)
Poll_Result :: struct { rendered, readable, timed_out: bool }

// poll(2) on one fd. Returns > 0 when readable, 0 on timeout, < 0 on error.
@(private)
poll_fd_wait :: proc(fd: i32, timeout_ms: int) -> int {
	pfd := Pollfd{fd = fd, events = POLLIN}
	return int(poll(&pfd, 1, i32(timeout_ms)))
}

// poll(2) on the render fd and the connection fd together.
@(private)
poll_two :: proc(render_fd, conn_fd: i32, timeout_ms: int) -> (res: Poll_Result) {
	fds: [2]Pollfd
	n: uint = 0
	ri, ci := -1, -1
	if render_fd >= 0 { fds[n] = {fd = render_fd, events = POLLIN}; ri = int(n); n += 1 }
	if conn_fd >= 0 { fds[n] = {fd = conn_fd, events = POLLIN}; ci = int(n); n += 1 }
	if n == 0 { res.timed_out = true; return }
	r := poll(&fds[0], n, i32(timeout_ms))
	if r == 0 { res.timed_out = true; return }
	if r < 0 { res.timed_out = true; return }
	if ri >= 0 && (fds[ri].revents & POLLIN) != 0 { res.rendered = true }
	if ci >= 0 && (fds[ci].revents & POLLIN) != 0 { res.readable = true }
	return
}

@(private) Pollfd :: struct { fd: i32, events: i16, revents: i16 }
@(private) POLLIN :: i16(0x0001)
@(default_calling_convention = "c", private)
foreign libc {
	poll :: proc(fds: ^Pollfd, nfds: uint, timeout: i32) -> i32 ---
}

// True once after the backend asked for a repaint (the surface was resized or revealed) while the app polled.
take_paint_request :: proc(w: ^Window) -> bool {
	r := w.paint_requested
	w.paint_requested = false
	return r
}

pump_stats :: proc(w: ^Window) -> Pump_Stats { return w.stats }

// Queues an event as if the system had delivered it (tests, remote control, macros). Call from the thread that polls.
inject_event :: proc(w: ^Window, e: Event) {
	append(&w.injected, e)
	if w.offscreen { one: u64 = 1; sys_write(i32(w.off_event), &one, size_of(one)) }
}

@(private)
take_injected :: proc(w: ^Window) {
	if len(w.injected) == 0 { return }
	now := time.tick_now()
	for &e in w.injected {
		e.stamp = now
		e.injected = true
		if e.kind == .Close { w.closed = true }
		append(&w.events, e)
	}
	clear(&w.injected)
}

@(private)
drop_returned :: proc(w: ^Window) {
	n := min(w.returned, len(w.events))
	w.returned = 0
	if n == 0 { return }
	copy(w.events[:], w.events[n:])
	resize(&w.events, len(w.events) - n)
}

@(private)
off_wait :: proc(w: ^Window, timeout_ms: int) {
	poll_fd_wait(i32(w.off_event), timeout_ms > 0 ? timeout_ms : -1)
}

@(private)
off_drain :: proc(w: ^Window) {
	buf: u64
	for sys_read(i32(w.off_event), &buf, size_of(buf)) == size_of(u64) {}   // clear the counter
}

////////////////////////////////
// Plain-text clipboard (the rich clipboard is in clipboard_linux.odin). Both backends own their selection.

get_clipboard :: proc(w: ^Window, allocator := context.allocator) -> string {
	if w == nil || w.offscreen { return "" }
	switch w.backend {
	case .Wayland: return wl_clipboard_get_text(w, allocator)
	case .X11:     return x11_clipboard_get_text(w, allocator)
	case .None:
	}
	return ""
}

set_clipboard :: proc(w: ^Window, text: string) {
	if w == nil || w.offscreen { return }
	switch w.backend {
	case .Wayland: wl_clipboard_set_text(w, text)
	case .X11:     x11_clipboard_set_text(w, text)
	case .None:
	}
}

////////////////////////////////
// System queries

// The accessibility "reduce animations" preference (org.freedesktop.appearance, read by theme_linux.odin): true when
// the user has not asked to reduce them.
os_animations_enabled :: proc() -> bool { return !reduce_motion_preferred() }

// Per-user config directory: $XDG_CONFIG_HOME, else $HOME/.config.
config_dir :: proc(allocator := context.allocator) -> string {
	if x := posix.getenv("XDG_CONFIG_HOME"); x != nil && string(x) != "" {
		return strings.clone(string(x), allocator)
	}
	if home := posix.getenv("HOME"); home != nil && string(home) != "" {
		return strings.concatenate({string(home), "/.config"}, allocator)
	}
	return ""
}

// Path of a font the system ships, by its file name (e.g. "DejaVuSans.ttf"), searched under the usual font folders.
// font_system_linux.odin in the font package is the richer lookup; this is the Win32 system_font_path's counterpart.
system_font_path :: proc(file: string, allocator := context.temp_allocator) -> string {
	dirs := [?]string{"/usr/share/fonts", "/usr/local/share/fonts"}
	if home := posix.getenv("HOME"); home != nil && string(home) != "" {
		p := strings.concatenate({string(home), "/.fonts/", file}, context.temp_allocator)
		if path_exists(p) { return strings.clone(p, allocator) }
		p = strings.concatenate({string(home), "/.local/share/fonts/", file}, context.temp_allocator)
		if path_exists(p) { return strings.clone(p, allocator) }
	}
	for d in dirs {
		p := strings.concatenate({d, "/", file}, context.temp_allocator)
		if path_exists(p) { return strings.clone(p, allocator) }
		// a common layout: /usr/share/fonts/truetype/<...>/file — a shallow search of one level
		p = strings.concatenate({d, "/truetype/", file}, context.temp_allocator)
		if path_exists(p) { return strings.clone(p, allocator) }
	}
	return strings.clone(file, allocator)
}

@(private)
path_exists :: proc(p: string) -> bool {
	c := strings.clone_to_cstring(p, context.temp_allocator)
	return posix.access(c, posix.F_OK) == .OK
}

// The app icon as RGBA8 (straight alpha, sRGB) at `size` x `size`: Linux carries no icon inside the executable, so an
// app supplies its own; this answers "no icon here".
app_icon_rgba :: proc(size: int, allocator := context.allocator) -> (pixels: []u8, ok: bool) { return nil, false }
