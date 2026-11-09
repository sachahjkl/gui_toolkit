#+build linux
package platform

// The Wayland window backend, over libwayland-client (by dlopen). One wl_display per thread that opens windows, shared by
// that thread's windows. A window is a wl_surface with an xdg_surface and xdg_toplevel (xdg-shell, wl_protocol_linux.odin). Server
// decorations are asked for through zxdg_decoration_manager_v1 when the compositor has it (KDE); where it does not
// (GNOME), the window is undecorated and the app draws its own title bar (integrated title) — the toolkit already does
// this on Windows, so the same frame works. Input comes from wl_seat (wl_pointer, wl_keyboard with its xkbcommon
// keymap; no wl_touch yet: a finger reaches a window as the compositor's emulated pointer, if it makes one); DPI from wp_fractional_scale with wp_viewporter when the compositor offers them, else the wl_output scale. The
// CLIPBOARD comes from wl_data_device (clipboard_linux.odin adds the richer flavours and the drag and drop).
//
// All event handling is in C callbacks (listeners); they stash into the per-window / per-seat state and queue Events,
// which poll_events hands out. wl_display's fd is poll(2)-ed by the loop (platform_linux.odin), with the
// prepare_read / read_events dance so several threads could read it safely (we read from one).

import "base:runtime"
import "core:time"
import "core:strings"
import "core:unicode/utf8"
import "core:sys/posix"
import "core:mem"

// The Context the C callbacks run under. Wayland dispatches listeners from inside wl_display_dispatch, which the UI
// thread calls; a default context with the toolkit's allocator is right there.
@(private)
wl_ctx_real :: proc "contextless" () -> runtime.Context { return runtime.default_context() }

// A thread's Wayland connection, the globals bound from the registry, and its seat's state.
@(private)
Wl_Conn :: struct {
	display:    Wl_Display,
	registry:   Wl_Proxy,
	compositor: Wl_Proxy,
	seat:       Wl_Proxy,
	output:     Wl_Proxy,
	shm:        Wl_Proxy,
	data_device_manager: Wl_Proxy,
	data_device: Wl_Proxy,
	xdg_wm_base: Wl_Proxy,
	decoration_manager: Wl_Proxy,
	fractional_manager: Wl_Proxy, // wp_fractional_scale_manager_v1 (optional)
	viewporter: Wl_Proxy,         // wp_viewporter (optional; fractional scaling needs both)
	pointer:    Wl_Proxy,
	keyboard:   Wl_Proxy,
	fd:         i32,
	output_scale: i32,            // integer buffer scale from wl_output (1, 2...)
	output_px:  [2]i32,           // the current output mode's pixel size (wl_output mode; 0 until one arrives)
	xkb_ctx:    Xkb_Context,
	xkb_keymap: Xkb_Keymap,
	xkb_state:  Xkb_State,
	// the seat's focus: which window the pointer / keyboard are over now (for routing input)
	pointer_focus:  ^Window,
	keyboard_focus: ^Window,
	key_repeat:     Key_Repeat,   // the compositor leaves the repeat of a held key to the client
	pointer_pos:    [2]f32,
	// the clipboard text another client offered, and the fd/offer plumbing (clipboard_linux.odin uses the richer parts)
	clip_text:  string,
	offer:      Wl_Proxy,
	// the keyboard-enter serial: a wl_data_device.set_selection needs a recent input serial (clipboard owner)
	kbd_serial: u32,
	// the clipboard selection owner we run, and the MIME types the current selection offer advertises
	data_source:   Wl_Proxy,      // our wl_data_source while we own CLIPBOARD, nil otherwise
	offer_mimes:   [dynamic]string,   // the MIME types wlc.offer advertises (filled by the offer's `offer` events)
	// drag and drop (dragdrop_wl_linux.odin): the data-device drag state lives here so its listeners reach it
	dnd_offer:     Wl_Proxy,      // the offer of a drag now over a window
	dnd_mimes:     [dynamic]string,
	dnd_window:    ^Window,
	dnd_enter_serial: u32,
	dnd_x, dnd_y:  f32,
	dnd_source:    Wl_Proxy,      // our wl_data_source while we drag from this app
	offer_actions: u32,           // what the source of the last offer allows (wl_data_offer.source_actions)
	dnd_told_action: u32,         // the action last asked for on the offer over the window
	// IME (ime_wl_linux.odin): the text-input manager and the per-seat text-input object
	ti_manager:    Wl_Proxy,
	text_input:    Wl_Proxy,
	ti_enabled:    bool,
	ti_window:     ^Window,       // the window the text-input is enabled for
	ti_rect:       [4]i32,        // the cursor rectangle told last (surface units)
	ime:           Ime_Compose,   // what the input method sent, applied on `done` (ime.odin)
	// cursor shapes (cursors_wl_linux.odin): the compositor draws them from a named shape (wp_cursor_shape_v1)
	cursor_shape_manager: Wl_Proxy,
	cursor_shape_device:  Wl_Proxy,
	cursor_sent:    u64,          // what was last sent (cursor_on_screen)
	cursor_surface: Wl_Proxy,     // the surface our cursor images are on
	// the serials the requests need: the pointer's last enter (set_cursor), its last button (a drag start, a selection)
	enter_serial:  u32,
	button_serial: u32,
	output_refresh_mhz: i32,      // the wl_output mode's refresh
	// an offer being described (its offer events) before data_offer / enter / selection say what it is for
	pending_offer:       Wl_Proxy,
	pending_offer_mimes: [dynamic]string,
	dnd_source_action:   u32,     // the action the compositor chose for our drag (wl_data_source.action)
	drag:          Wl_Drag_Store, // drag and drop (dragdrop_wl_linux.odin)
	link:          Display_Link,
	windows:       [dynamic]^Window,   // this connection's windows
}

// This thread's connection: each thread that opens windows has its own (its event queue, its seat's focus and serials), as its
// windows' calls and the listeners all run on it.
@(private, thread_local) wlc: Wl_Conn

@(private)
Wl_Window_State :: struct {
	surface:     Wl_Proxy,
	xdg_surface: Wl_Proxy,
	xdg_toplevel: Wl_Proxy,
	decoration:  Wl_Proxy,
	transparent: bool,
	title:       string,
	pending_w, pending_h: int,     // the size the last xdg_toplevel.configure asked for (0 = app chooses)
	server_side: bool,             // the decoration mode the compositor chose: it draws the frame
	acked:       bool,             // the role's first configure was acked: a buffer may be attached
	tiled:       bool,             // the last configure said an edge is tiled: a tiling compositor, which draws its border
	toplevel:    Show_State,       // what the last configure said; the window's state once it is shown
	floating:    [2]int,           // `logical` when it last was neither maximized nor full screen
	fractional:  Wl_Proxy,         // wp_fractional_scale_v1 and wp_viewport: the buffer has w.size pixels, the surface
	viewport:    Wl_Proxy,         // `logical` on the output (nil: an integer buffer scale)
	logical:     [2]int,           // the surface's size, in the compositor's units
	win:         ^Window,          // back pointer for the listeners
}

@(private)
wl_state :: proc(w: ^Window) -> ^Wl_Window_State { return (^Wl_Window_State)(w.wl) }

// Every request is marshalled by wl.proxy_marshal_flags directly (a true C variadic): the new-id argument is passed as
// nil (the library fills the id) when the request makes a new proxy, and the request arguments follow in protocol order.

@(private)
wl_connect :: proc() -> bool {
	if wlc.link != .Untried { return wlc.link == .Connected }
	if wl_connect_now() {
		wlc.link = .Connected
		return true
	}
	// (a compositor without the shell: nothing of it stays, what reads wlc sees no connection)
	if wlc.display != nil { wl.display_disconnect(wlc.display) }
	wlc = {link = .Failed}
	return false
}

@(private = "file")
wl_connect_now :: proc() -> bool {
	l := wayland_lib()
	if !l.ok { return false }
	wlc.windows.allocator = runtime.heap_allocator()   // (outlives whatever allocator the first window was made under)
	wlc.display = l.display_connect(nil)
	if wlc.display == nil { return false }
	sigpipe_ignored()
	wlc.fd = l.display_get_fd(wlc.display)
	wlc.output_scale = 1
	wlc.key_repeat.rate, wlc.key_repeat.delay_ms = KEY_REPEAT_DEFAULT_RATE, KEY_REPEAT_DEFAULT_DELAY_MS
	// the registry, and bind the globals it advertises
	wlc.registry = l.proxy_marshal_flags(Wl_Proxy(wlc.display), 1 /*get_registry*/, l.registry_interface, l.proxy_get_version(Wl_Proxy(wlc.display)), 0, nil)
	if wlc.registry == nil { return false }
	l.proxy_add_listener(wlc.registry, &registry_listener, nil)
	l.display_roundtrip(wlc.display)   // first roundtrip: the globals arrive
	l.display_roundtrip(wlc.display)   // second: anything the first triggered (seat capabilities, output geometry)
	wl_init_xkb()
	if wlc.xdg_wm_base != nil { l.proxy_add_listener(wlc.xdg_wm_base, &wm_base_listener, nil) }
	if wlc.data_device_manager != nil && wlc.seat != nil {
		wlc.data_device = wl.proxy_marshal_flags(wlc.data_device_manager, WL_DATA_DEVICE_MANAGER_GET_DATA_DEVICE,
			wl.data_device_interface, wl.proxy_get_version(wlc.data_device_manager), 0, nil, wlc.seat)
		if wlc.data_device != nil { l.proxy_add_listener(wlc.data_device, &data_device_listener, nil) }
	}
	if wlc.ti_manager != nil && wlc.seat != nil {
		wlc.text_input = wl.proxy_marshal_flags(wlc.ti_manager, ZWP_TI_MANAGER_GET_TEXT_INPUT,
			&zwp_ti_iface, wl.proxy_get_version(wlc.ti_manager), 0, nil, wlc.seat)
		if wlc.text_input != nil { l.proxy_add_listener(wlc.text_input, &text_input_listener, nil) }
	}
	return wlc.xdg_wm_base != nil && wlc.compositor != nil
}

// A peer that closes its pipe while a data source writes to it is an EPIPE, not the end of the process. (An app that handles
// SIGPIPE itself keeps its handler.)
@(private = "file")
sigpipe_ignored :: proc() {
	old: posix.sigaction_t
	if posix.sigaction(.SIGPIPE, nil, &old) == .OK && old.sa_handler == auto_cast posix.SIG_DFL { posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN) }
}

@(private)
wl_init_xkb :: proc() {
	k := xkb_lib()
	if !k.ok { return }
	wlc.xkb_ctx = k.context_new(XKB_CONTEXT_NO_FLAGS)
	// the keymap itself arrives on wl_keyboard.keymap (a shared fd), compiled in keyboard_keymap
}

////////////////////////////////
// registry

@(private)
Registry_Listener :: struct {
	global:        proc "c" (data: rawptr, registry: Wl_Proxy, name: u32, iface: cstring, version: u32),
	global_remove: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32),
}
@(private) registry_listener := Registry_Listener{registry_global, registry_global_remove}

// The versions asked for (no more than the compositor has).
@(private = "file") WL_COMPOSITOR_VERSION :: 4
@(private = "file") WL_SEAT_VERSION :: 5
@(private = "file") WL_DATA_DEVICE_MANAGER_VERSION :: 3
@(private = "file") XDG_WM_BASE_VERSION :: 4
@(private = "file") WL_AXIS_UNITS_PER_NOTCH :: 10    // wl_pointer.axis: surface units of one notch of a wheel

@(private)
registry_global :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32, iface: cstring, version: u32) {
	context = wl_ctx_real()
	s := string(iface)
	bind :: proc(name: u32, iface: ^Wl_Interface, want: u32, have: u32) -> Wl_Proxy {
		v := min(want, have)
		return wl.proxy_marshal_flags(wlc.registry, WL_REGISTRY_BIND, iface, v, 0, name, iface.name, v, nil)
	}
	switch s {
	case "wl_compositor": wlc.compositor = bind(name, wl.compositor_interface, WL_COMPOSITOR_VERSION, version)
	case "wl_shm":        wlc.shm = bind(name, wl.shm_interface, 1, version)
	case "wl_output":     if wlc.output == nil { wlc.output = bind(name, wl.output_interface, 2, version); wl.proxy_add_listener(wlc.output, &output_listener, nil) }
	case "wl_seat":
		if wlc.seat == nil {
			wlc.seat = bind(name, wl.seat_interface, WL_SEAT_VERSION, version)
			wl.proxy_add_listener(wlc.seat, &seat_listener, nil)
		}
	case "wl_data_device_manager": wlc.data_device_manager = bind(name, wl.data_device_manager_interface, WL_DATA_DEVICE_MANAGER_VERSION, version)
	case "xdg_wm_base":   wlc.xdg_wm_base = bind(name, &xdg_wm_base_iface, XDG_WM_BASE_VERSION, version)
	case "zxdg_decoration_manager_v1": wlc.decoration_manager = bind(name, &zxdg_decoration_manager_iface, 1, version)
	case "zwp_text_input_manager_v3": wlc.ti_manager = bind(name, &zwp_ti_manager_iface, 1, version)
	case "wp_cursor_shape_manager_v1": wlc.cursor_shape_manager = bind(name, &wp_cursor_shape_manager_iface, 1, version)
	case "wp_fractional_scale_manager_v1": wlc.fractional_manager = bind(name, &wp_fractional_manager_iface, 1, version)
	case "wp_viewporter": wlc.viewporter = bind(name, &wp_viewporter_iface, 1, version)
	}
}

@(private)
registry_global_remove :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32) {}

////////////////////////////////
// xdg_wm_base (ping)

@(private)
Wm_Base_Listener :: struct { ping: proc "c" (data: rawptr, base: Wl_Proxy, serial: u32) }
@(private) wm_base_listener := Wm_Base_Listener{wm_base_ping}
@(private)
wm_base_ping :: proc "c" (data: rawptr, base: Wl_Proxy, serial: u32) {
	wl.proxy_marshal_flags(base, XDG_WM_BASE_PONG, nil, wl.proxy_get_version(base), 0, serial)
}

////////////////////////////////
// wl_output (scale for DPI)

@(private)
Output_Listener :: struct {
	geometry: proc "c" (data: rawptr, o: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32),
	mode:     proc "c" (data: rawptr, o: Wl_Proxy, flags: u32, w, h, refresh: i32),
	done:     proc "c" (data: rawptr, o: Wl_Proxy),
	scale:    proc "c" (data: rawptr, o: Wl_Proxy, factor: i32),
}
@(private) output_listener := Output_Listener{output_geometry, output_mode, output_done, output_scale_ev}
@(private)
output_geometry :: proc "c" (data: rawptr, o: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {}
@(private)
output_mode :: proc "c" (data: rawptr, o: Wl_Proxy, flags: u32, w, h, refresh: i32) { if flags & 1 != 0 { wlc.output_refresh_mhz = refresh; wlc.output_px = {w, h} } }
// A change of the output is complete: the windows' rate and monitor are read again, and a window without a fractional
// scale follows the output's integer one.
@(private)
output_done :: proc "c" (data: rawptr, o: Wl_Proxy) {
	context = wl_ctx_real()
	for w in wlc.windows {
		w.display_stale = true
		st := wl_state(w)
		if st.viewport != nil || w.dpi_scale == f32(wlc.output_scale) { continue }
		w.dpi_scale = f32(wlc.output_scale)
		wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_BUFFER_SCALE, nil, wl.proxy_get_version(st.surface), 0, wlc.output_scale)
		wl_size_from_logical(w, st)
		w.paint_requested = true
		apply_cursor(w)
	}
}
@(private)
output_scale_ev :: proc "c" (data: rawptr, o: Wl_Proxy, factor: i32) { if factor > 0 { wlc.output_scale = factor } }

////////////////////////////////
// wl_seat and input

@(private)
Seat_Listener :: struct {
	capabilities: proc "c" (data: rawptr, seat: Wl_Proxy, caps: u32),
	name:         proc "c" (data: rawptr, seat: Wl_Proxy, name: cstring),
}
@(private) seat_listener := Seat_Listener{seat_capabilities, seat_name}
@(private)
seat_name :: proc "c" (data: rawptr, seat: Wl_Proxy, name: cstring) {}
@(private)
seat_capabilities :: proc "c" (data: rawptr, seat: Wl_Proxy, caps: u32) {
	WL_SEAT_POINTER :: 1; WL_SEAT_KEYBOARD :: 2
	context = wl_ctx_real()
	// (an object of a capability the seat lost stays dead when the capability comes back: a new one is asked for)
	if caps & WL_SEAT_POINTER != 0 && wlc.pointer == nil {
		wlc.pointer = wl.proxy_marshal_flags(seat, WL_SEAT_GET_POINTER, wl.pointer_interface, wl.proxy_get_version(seat), 0, nil)
		wl.proxy_add_listener(wlc.pointer, &pointer_listener, nil)
	} else if caps & WL_SEAT_POINTER == 0 && wlc.pointer != nil {
		if w := wlc.pointer_focus; w != nil { buttons_released(w, wlc.pointer_pos, wl_mods()); wl_push(w, {kind = .Mouse_Leave}) }
		wlc.pointer_focus = nil
		if wlc.cursor_shape_device != nil {
			wl.proxy_marshal_flags(wlc.cursor_shape_device, WP_CURSOR_SHAPE_DEVICE_DESTROY, nil, wl.proxy_get_version(wlc.cursor_shape_device), WL_MARSHAL_FLAG_DESTROY)
			wlc.cursor_shape_device = nil
		}
		wl_release_input(wlc.pointer, WL_POINTER_RELEASE)
		wlc.pointer = nil
	}
	if caps & WL_SEAT_KEYBOARD != 0 && wlc.keyboard == nil {
		wlc.keyboard = wl.proxy_marshal_flags(seat, WL_SEAT_GET_KEYBOARD, wl.keyboard_interface, wl.proxy_get_version(seat), 0, nil)
		wl.proxy_add_listener(wlc.keyboard, &keyboard_listener, nil)
	} else if caps & WL_SEAT_KEYBOARD == 0 && wlc.keyboard != nil {
		if w := wlc.keyboard_focus; w != nil { window_focus(w, false, {}) }
		wlc.keyboard_focus = nil
		wlc.key_repeat.held = false
		wl_release_input(wlc.keyboard, WL_KEYBOARD_RELEASE)
		wlc.keyboard = nil
	}
}

@(private = "file") WL_POINTER_RELEASE :: 1
@(private = "file") WL_KEYBOARD_RELEASE :: 0
@(private = "file") WL_INPUT_RELEASE_SINCE :: 3   // the seat's version that has their release

@(private = "file")
wl_release_input :: proc(p: Wl_Proxy, release: u32) {
	v := wl.proxy_get_version(p)
	if v >= WL_INPUT_RELEASE_SINCE { wl.proxy_marshal_flags(p, release, nil, v, WL_MARSHAL_FLAG_DESTROY) } else { wl.proxy_destroy(p) }
}

@(private)
Pointer_Listener :: struct {
	enter:  proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy, sx, sy: Wl_Fixed),
	leave:  proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy),
	motion: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, sx, sy: Wl_Fixed),
	button: proc "c" (data: rawptr, p: Wl_Proxy, serial, time, button, state: u32),
	axis:   proc "c" (data: rawptr, p: Wl_Proxy, time: u32, axis: u32, value: Wl_Fixed),
	frame:  proc "c" (data: rawptr, p: Wl_Proxy),
	axis_source: proc "c" (data: rawptr, p: Wl_Proxy, source: u32),
	axis_stop: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, axis: u32),
	axis_discrete: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, discrete: i32),
	axis_value120: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, value120: i32),
	axis_relative_direction: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, direction: u32),
}
@(private) pointer_listener := Pointer_Listener{ptr_enter, ptr_leave, ptr_motion, ptr_button, ptr_axis, ptr_frame, ptr_axis_src, ptr_axis_stop, ptr_axis_discrete, ptr_axis_v120, ptr_axis_dir}

@(private)
window_of_surface :: proc "contextless" (surface: Wl_Proxy) -> ^Window {
	// the surface's user data is the Wl_Window_State; its .win is the Window
	if surface == nil { return nil }
	ud := wl.proxy_get_user_data(surface)
	if ud == nil { return nil }
	st := (^Wl_Window_State)(ud)
	return st.win
}

@(private)
ptr_enter :: proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy, sx, sy: Wl_Fixed) {
	context = wl_ctx_real()
	wlc.pointer_focus = window_of_surface(surface)
	scale: f32 = wlc.pointer_focus != nil ? wlc.pointer_focus.dpi_scale : 1   // (as ptr_motion: a click before any motion lands here)
	wlc.pointer_pos = {f32(wl_fixed_to_f64(sx)) * scale, f32(wl_fixed_to_f64(sy)) * scale}
	wlc.enter_serial = serial
	if wlc.pointer_focus != nil { wl_apply_cursor(wlc.pointer_focus) }   // (the compositor forgot it when the pointer left)
}
@(private)
ptr_leave :: proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy) {
	context = wl_ctx_real()
	if w := wlc.pointer_focus; w != nil {
		buttons_released(w, wlc.pointer_pos, wl_mods())   // (the compositor took the pointer: the release will not come here)
		wl_push(w, {kind = .Mouse_Leave})
	}
	wlc.pointer_focus = nil
}
@(private)
ptr_motion :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, sx, sy: Wl_Fixed) {
	context = wl_ctx_real()
	w := wlc.pointer_focus
	if w == nil { return }
	wlc.pointer_pos = {f32(wl_fixed_to_f64(sx)) * w.dpi_scale, f32(wl_fixed_to_f64(sy)) * w.dpi_scale}
	frame_hover_at(w, wlc.pointer_pos)
	wl_push(w, {kind = .Mouse_Move, pos = wlc.pointer_pos, mods = wl_mods(), buttons = w.buttons_down})
}
@(private)
ptr_button :: proc "c" (data: rawptr, p: Wl_Proxy, serial, time, button, state: u32) {
	context = wl_ctx_real()
	wlc.button_serial = serial
	w := wlc.pointer_focus
	if w == nil { return }
	// Linux input-event-codes: BTN_LEFT 0x110, BTN_RIGHT 0x111, BTN_MIDDLE 0x112, BTN_SIDE 0x113, BTN_EXTRA 0x114, BTN_FORWARD 0x115, BTN_BACK 0x116
	btn: Mouse_Button
	switch button {
	case 0x110: btn = .Left
	case 0x111: btn = .Right
	case 0x112: btn = .Middle
	case 0x113, 0x116: btn = .Back
	case 0x114, 0x115: btn = .Forward
	case: return
	}
	press := state == 1
	if press && wl_frame_press(w, btn, serial, time) {
		wl_push(w, {kind = .Frame_Press, button = btn, pos = wlc.pointer_pos, mods = wl_mods(), buttons = w.buttons_down})
		return
	}
	if button_changes(w, btn, press) {
		wl_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = btn, pos = wlc.pointer_pos, mods = wl_mods(), buttons = w.buttons_down})
	}
}
// A press on the frame of an integrated title bar (frame_linux.odin): the compositor moves or resizes the window, a
// double click on the caption maximizes it, a right click there opens the compositor's window menu. True when it was
// the frame's: the app does not get the press.
@(private)
wl_frame_press :: proc(w: ^Window, btn: Mouse_Button, serial, time: u32) -> bool {
	h := frame_hit(w, wlc.pointer_pos)
	if !hit_is_frame(h) || wlc.seat == nil { return false }
	st := wl_state(w)
	if st.xdg_toplevel == nil { return false }   // (hidden)
	ver := wl.proxy_get_version(st.xdg_toplevel)
	#partial switch btn {
	case .Left:
		if h == .Caption {
			if caption_double_click(w, wlc.pointer_pos, time) { toggle_maximize(w); return true }
			wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_MOVE, nil, ver, 0, wlc.seat, serial)
		} else {
			wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_RESIZE, nil, ver, 0, wlc.seat, serial, wl_resize_edges(h))
		}
		wl.display_flush(wlc.display)
		return true
	case .Right:
		if h != .Caption { return false }
		wl_show_window_menu(w, wlc.pointer_pos)
		return true
	}
	return false
}

// xdg_toplevel.resize_edge of a band.
@(private)
wl_resize_edges :: proc(h: Hit) -> u32 {
	#partial switch h {
	case .Top:          return 1
	case .Bottom:       return 2
	case .Left:         return 4
	case .Top_Left:     return 5
	case .Bottom_Left:  return 6
	case .Right:        return 8
	case .Top_Right:    return 9
	case .Bottom_Right: return 10
	}
	return 0
}

@(private)
ptr_axis :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, axis: u32, value: Wl_Fixed) {
	context = wl_ctx_real()
	w := wlc.pointer_focus
	if w == nil { return }
	// axis 0 vertical, 1 horizontal; value is in surface units (a notch ~= 10). Our delta is in notches (+y = down).
	v := f32(wl_fixed_to_f64(value)) / WL_AXIS_UNITS_PER_NOTCH
	e := Event{kind = .Scroll, pos = wlc.pointer_pos, mods = wl_mods()}
	if axis == 0 { e.delta.y = v } else { e.delta.x = v }
	wl_push(w, e)
}
@(private) ptr_frame :: proc "c" (data: rawptr, p: Wl_Proxy) {}
@(private) ptr_axis_src :: proc "c" (data: rawptr, p: Wl_Proxy, source: u32) {}
@(private) ptr_axis_stop :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, axis: u32) {}
@(private) ptr_axis_discrete :: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, discrete: i32) {}
@(private) ptr_axis_v120 :: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, value120: i32) {}
@(private) ptr_axis_dir :: proc "c" (data: rawptr, p: Wl_Proxy, axis: u32, direction: u32) {}

@(private)
Keyboard_Listener :: struct {
	keymap:      proc "c" (data: rawptr, kb: Wl_Proxy, format: u32, fd: i32, size: u32),
	enter:       proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy, keys: ^Wl_Array),
	leave:       proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy),
	key:         proc "c" (data: rawptr, kb: Wl_Proxy, serial, time, key, state: u32),
	modifiers:   proc "c" (data: rawptr, kb: Wl_Proxy, serial, dep, latched, locked, group: u32),
	repeat_info: proc "c" (data: rawptr, kb: Wl_Proxy, rate, delay: i32),
}
@(private) keyboard_listener := Keyboard_Listener{kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat}

@(private)
kb_keymap :: proc "c" (data: rawptr, kb: Wl_Proxy, format: u32, fd: i32, size: u32) {
	context = wl_ctx_real()
	defer posix.close(posix.FD(fd))
	k := xkb_lib()
	if !k.ok || wlc.xkb_ctx == nil || format != 1 { return }   // 1 = XKB_V1
	// mmap the keymap string the compositor shared
	addr := sys_mmap(nil, uint(size), 1 /*PROT_READ*/, 2 /*MAP_PRIVATE*/, fd, 0)
	if addr == nil || addr == rawptr(~uintptr(0)) { return }
	defer sys_munmap(addr, uint(size))
	s := cstring(addr)
	// (the one held stays when this one does not compile: the keys go on as they were)
	keymap := k.keymap_new_from_string(wlc.xkb_ctx, s, 1 /*TEXT_V1*/, XKB_KEYMAP_COMPILE_NO_FLAGS)
	if keymap == nil { return }
	state := k.state_new(keymap)
	if state == nil { k.keymap_unref(keymap); return }
	if wlc.xkb_state != nil { k.state_unref(wlc.xkb_state) }
	if wlc.xkb_keymap != nil { k.keymap_unref(wlc.xkb_keymap) }
	wlc.xkb_keymap, wlc.xkb_state = keymap, state
	wlc.key_repeat.held = false   // (the key held is another one in this keymap)
}
@(private)
kb_enter :: proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy, keys: ^Wl_Array) {
	context = wl_ctx_real()
	wlc.kbd_serial = serial
	wlc.keyboard_focus = window_of_surface(surface)
	if w := wlc.keyboard_focus; w != nil { window_focus(w, true, {}) }
}
@(private)
kb_leave :: proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy) {
	context = wl_ctx_real()
	if w := wlc.keyboard_focus; w != nil { window_focus(w, false, {}) }
	wlc.key_repeat.held = false
	wlc.keyboard_focus = nil
}
@(private)
kb_key :: proc "c" (data: rawptr, kb: Wl_Proxy, serial, time, key, state: u32) {
	context = wl_ctx_real()
	wlc.kbd_serial = serial
	w := wlc.keyboard_focus
	if w == nil { return }
	k := xkb_lib()
	if !k.ok || wlc.xkb_state == nil { return }
	keycode := key + 8   // evdev to xkb
	press := state == 1
	wl_key_emit(w, keycode, press, false)
	if !press {
		key_repeat_release(&wlc.key_repeat, keycode)
	} else if wl_key_repeats(keycode) {
		key_repeat_press(&wlc.key_repeat, keycode, wl_now_ms())
	}
}

// A key's events: its Key_Press or Key_Release, and the text it types.
@(private)
wl_key_emit :: proc(w: ^Window, keycode: u32, press, repeat: bool) {
	k := xkb_lib()
	kk := key_from_xkb(wlc.xkb_keymap, wlc.xkb_state, keycode)
	mods := wl_mods()
	if kk != .None && key_changes(w, kk, press) { wl_push(w, {kind = press ? .Key_Press : .Key_Release, key = kk, mods = mods, repeat = repeat}) }
	if press && .Ctrl not_in mods && .Alt not_in mods {
		buf: [8]u8
		n := k.state_key_get_utf8(wlc.xkb_state, keycode, &buf[0], size_of(buf))
		if n > 0 { if r, sz := utf8.decode_rune(string(buf[:n])); sz > 0 && r >= RUNE_FIRST_PRINTABLE && r != RUNE_DEL { wl_push(w, {kind = .Text, text = r, mods = mods}) } }
	}
}

// Whether a key repeats in the keymap (the modifiers do not, and xkb knows the rest).
@(private)
wl_key_repeats :: proc(keycode: u32) -> bool {
	k := xkb_lib()
	#partial switch key_from_keysym(k.state_key_get_one_sym(wlc.xkb_state, keycode)) {
	case .Shift, .Ctrl, .Alt: return false
	}
	return k.keymap_key_repeats == nil || k.keymap_key_repeats(wlc.xkb_keymap, keycode) != 0
}

@(private)
wl_now_ms :: proc() -> f64 { return f64(time.tick_now()._nsec) / 1e6 }

// The repeats that are due go to the window that has the keyboard.
@(private)
wl_key_repeat_tick :: proc() {
	w := wlc.keyboard_focus
	if w == nil || wlc.xkb_state == nil { wlc.key_repeat.held = false; return }
	now := wl_now_ms()
	for key_repeat_take(&wlc.key_repeat, now) { wl_key_emit(w, wlc.key_repeat.code, true, true) }
}

// The wait of a poll: `timeout_ms` (0: none), shortened to the next repeat of a held key.
@(private)
wl_poll_timeout :: proc(timeout_ms: int) -> int {
	t := timeout_ms > 0 ? timeout_ms : -1
	if r := key_repeat_wait_ms(&wlc.key_repeat, wl_now_ms()); r >= 0 && (t < 0 || r < t) { t = r }
	return t
}

@(private)
kb_modifiers :: proc "c" (data: rawptr, kb: Wl_Proxy, serial, dep, latched, locked, group: u32) {
	k := &xkb
	if k.ok && wlc.xkb_state != nil { k.state_update_mask(wlc.xkb_state, dep, latched, locked, 0, 0, group) }
}
@(private)
kb_repeat :: proc "c" (data: rawptr, kb: Wl_Proxy, rate, delay: i32) {
	wlc.key_repeat.rate, wlc.key_repeat.delay_ms = int(rate), int(delay)
	if rate <= 0 { wlc.key_repeat.held = false }
}

@(private)
wl_mods :: proc "contextless" () -> (m: Modifiers) {
	k := &xkb
	if !k.ok || wlc.xkb_state == nil { return }
	if k.state_mod_name_is_active(wlc.xkb_state, "Control", XKB_STATE_MODS_EFFECTIVE) > 0 { m += {.Ctrl} }
	if k.state_mod_name_is_active(wlc.xkb_state, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0 { m += {.Shift} }
	if k.state_mod_name_is_active(wlc.xkb_state, "Mod1", XKB_STATE_MODS_EFFECTIVE) > 0 { m += {.Alt} }
	return
}

////////////////////////////////
// xdg_surface / xdg_toplevel listeners

@(private)
Xdg_Surface_Listener :: struct { configure: proc "c" (data: rawptr, s: Wl_Proxy, serial: u32) }
@(private) xdg_surface_listener := Xdg_Surface_Listener{xdg_surface_configure}
@(private)
xdg_surface_configure :: proc "c" (data: rawptr, s: Wl_Proxy, serial: u32) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	wl.proxy_marshal_flags(s, XDG_SURFACE_ACK_CONFIGURE, nil, wl.proxy_get_version(s), 0, serial)
	if st == nil || st.win == nil { return }
	st.acked = true
	w := st.win
	if st.pending_w > 0 && st.pending_h > 0 {
		st.logical = {st.pending_w, st.pending_h}
		if st.toplevel == .Normal { st.floating = st.logical }
		wl_size_from_logical(w, st)
	} else if st.floating != {} {
		st.logical = st.floating   // (no size asked for, after a maximize: the one before it)
		wl_size_from_logical(w, st)
	}
	w.paint_requested = true
}

@(private)
Xdg_Toplevel_Listener :: struct {
	configure: proc "c" (data: rawptr, t: Wl_Proxy, w, h: i32, states: ^Wl_Array),
	close:     proc "c" (data: rawptr, t: Wl_Proxy),
	configure_bounds: proc "c" (data: rawptr, t: Wl_Proxy, w, h: i32),
	wm_capabilities: proc "c" (data: rawptr, t: Wl_Proxy, caps: ^Wl_Array),
}
@(private) xdg_toplevel_listener := Xdg_Toplevel_Listener{xdg_toplevel_configure, xdg_toplevel_close, xdg_toplevel_bounds, xdg_toplevel_caps}
@(private)
xdg_toplevel_configure :: proc "c" (data: rawptr, t: Wl_Proxy, w, h: i32, states: ^Wl_Array) {
	st := (^Wl_Window_State)(data)
	if st == nil || st.win == nil { return }
	st.pending_w, st.pending_h = int(w), int(h)
	// decode the states array (u32 each): 1 maximized, 2 fullscreen, 4 activated, 5 to 8 tiled left, right, top, bottom.
	// (No state says a toplevel is minimized.)
	st.toplevel = .Normal
	st.tiled = false
	if states != nil && states.data != nil {
		n := states.size / size_of(u32)
		arr := ([^]u32)(states.data)
		for i in 0 ..< n {
			switch arr[i] {
			case 1: if st.toplevel == .Normal { st.toplevel = .Maximized }
			case 2: st.toplevel = .Fullscreen
			case 5, 6, 7, 8: st.tiled = true
			}
		}
	}
	st.win.system_frame = st.server_side || st.tiled
	if st.win.show != .Hidden { st.win.show = st.toplevel }
}
@(private)
xdg_toplevel_close :: proc "c" (data: rawptr, t: Wl_Proxy) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st != nil && st.win != nil { st.win.closed = true; wl_push(st.win, {kind = .Close}) }
}
@(private) xdg_toplevel_bounds :: proc "c" (data: rawptr, t: Wl_Proxy, w, h: i32) {}
@(private) xdg_toplevel_caps :: proc "c" (data: rawptr, t: Wl_Proxy, caps: ^Wl_Array) {}

@(private)
Decoration_Listener :: struct { configure: proc "c" (data: rawptr, d: Wl_Proxy, mode: u32) }
@(private) decoration_listener := Decoration_Listener{decoration_configure}
@(private)
decoration_configure :: proc "c" (data: rawptr, d: Wl_Proxy, mode: u32) {
	st := (^Wl_Window_State)(data)
	if st == nil || st.win == nil { return }
	st.server_side = mode == ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE
	st.win.system_frame = st.server_side || st.tiled
}

////////////////////////////////
// lifecycle

// The buffer's size from the surface's and the scale, and the surface's size to the compositor.
@(private)
wl_size_from_logical :: proc(w: ^Window, st: ^Wl_Window_State) {
	w.size = {max(int(f32(st.logical.x) * w.dpi_scale + 0.5), 1), max(int(f32(st.logical.y) * w.dpi_scale + 0.5), 1)}
	if st.viewport != nil {
		wl.proxy_marshal_flags(st.viewport, WP_VIEWPORT_SET_DESTINATION, nil, wl.proxy_get_version(st.viewport), 0, i32(max(st.logical.x, 1)), i32(max(st.logical.y, 1)))
	}
}

@(private)
Fractional_Listener :: struct { preferred_scale: proc "c" (data: rawptr, f: Wl_Proxy, scale: u32) }
@(private) fractional_listener := Fractional_Listener{fractional_preferred}

@(private = "file") FRACTIONAL_DENOMINATOR :: 120

@(private)
fractional_preferred :: proc "c" (data: rawptr, f: Wl_Proxy, scale: u32) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st == nil || st.win == nil || scale == 0 { return }
	w := st.win
	k := f32(scale) / FRACTIONAL_DENOMINATOR
	if k == w.dpi_scale { return }
	w.dpi_scale = k
	wl_size_from_logical(w, st)
	w.paint_requested = true
	apply_cursor(w)
}

@(private)
wl_open :: proc(w: ^Window, title: string, size: [2]int, transparent: bool) -> bool {
	if !wl_connect() { report_missing("libwayland-client (or xdg-shell)"); return false }
	st := new(Wl_Window_State)
	st.win = w
	st.transparent = transparent
	st.title = strings.clone(title)
	w.wl = st
	w.dpi_scale = f32(wlc.output_scale)

	st.logical = {max(size.x, 1), max(size.y, 1)}
	st.floating = st.logical
	st.toplevel = .Normal
	if !wl_surface_make(w, st) { delete(st.title); free(st); w.wl = nil; return false }
	append(&wlc.windows, w)
	wl.display_roundtrip(wlc.display)   // the first configure arrives; the surface is ready for the renderer
	return true
}

// How long a shown window waits for its first configure, and how long each poll for it lasts.
@(private) WL_FIRST_CONFIGURE_WAIT_MS :: 500
@(private) WL_FIRST_CONFIGURE_POLL_MS :: 5

// The window's surface, its scale objects and its toplevel role, committed without a buffer (the compositor answers with
// the first configure). Made at open, and again when a hidden window is shown (wl_hide destroyed them).
@(private)
wl_surface_make :: proc(w: ^Window, st: ^Wl_Window_State) -> bool {
	st.surface = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
	if st.surface == nil { return false }
	wl.proxy_set_user_data(st.surface, st)
	if wlc.fractional_manager != nil && wlc.viewporter != nil {
		st.viewport = wl.proxy_marshal_flags(wlc.viewporter, WP_VIEWPORTER_GET_VIEWPORT, &wp_viewport_iface, wl.proxy_get_version(wlc.viewporter), 0, nil, st.surface)
		st.fractional = wl.proxy_marshal_flags(wlc.fractional_manager, WP_FRACTIONAL_MANAGER_GET, &wp_fractional_iface, wl.proxy_get_version(wlc.fractional_manager), 0, nil, st.surface)
		if st.fractional != nil { wl.proxy_add_listener(st.fractional, &fractional_listener, st) }
	}
	wl_role_make(w, st)
	wl_size_from_logical(w, st)
	if wlc.output_scale > 1 && st.viewport == nil {
		wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_BUFFER_SCALE, nil, wl.proxy_get_version(st.surface), 0, wlc.output_scale)
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	return true
}

// The surface and its scale objects go (wl_surface_make makes them again).
@(private)
wl_surface_destroy :: proc(st: ^Wl_Window_State) {
	if st.fractional != nil { wl.proxy_marshal_flags(st.fractional, WP_FRACTIONAL_DESTROY, nil, wl.proxy_get_version(st.fractional), WL_MARSHAL_FLAG_DESTROY) }
	if st.viewport != nil { wl.proxy_marshal_flags(st.viewport, WP_VIEWPORT_DESTROY, nil, wl.proxy_get_version(st.viewport), WL_MARSHAL_FLAG_DESTROY) }
	if st.surface != nil { wl.proxy_marshal_flags(st.surface, WL_SURFACE_DESTROY, nil, wl.proxy_get_version(st.surface), WL_MARSHAL_FLAG_DESTROY) }
	st.fractional, st.viewport, st.surface = nil, nil, nil
}

// The toplevel role of the surface: its xdg_surface and xdg_toplevel, the title, the app id, the decoration.
@(private)
wl_role_make :: proc(w: ^Window, st: ^Wl_Window_State) {
	st.acked = false
	st.xdg_surface = wl.proxy_marshal_flags(wlc.xdg_wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_iface, wl.proxy_get_version(wlc.xdg_wm_base), 0, nil, st.surface)
	wl.proxy_add_listener(st.xdg_surface, &xdg_surface_listener, st)
	st.xdg_toplevel = wl.proxy_marshal_flags(st.xdg_surface, XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_iface, wl.proxy_get_version(st.xdg_surface), 0, nil)
	wl.proxy_add_listener(st.xdg_toplevel, &xdg_toplevel_listener, st)

	ctitle := strings.clone_to_cstring(st.title, context.temp_allocator)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, nil, wl.proxy_get_version(st.xdg_toplevel), 0, ctitle)
	cid := strings.clone_to_cstring(app_id_or_exe(), context.temp_allocator)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_APP_ID, nil, wl.proxy_get_version(st.xdg_toplevel), 0, cid)

	// server-side decorations when the compositor offers them and the app did not ask for an integrated title
	if wlc.decoration_manager != nil {
		st.decoration = wl.proxy_marshal_flags(wlc.decoration_manager, ZXDG_DECORATION_MANAGER_GET_TOPLEVEL_DECORATION,
			&zxdg_toplevel_decoration_iface, wl.proxy_get_version(wlc.decoration_manager), 0, nil, st.xdg_toplevel)
		if st.decoration != nil {
			wl.proxy_add_listener(st.decoration, &decoration_listener, st)
			mode: u32 = w.integrated ? ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE : ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE
			wl.proxy_marshal_flags(st.decoration, ZXDG_TOPLEVEL_DECORATION_SET_MODE, nil, wl.proxy_get_version(st.decoration), 0, mode)
		}
	}
}

// (The decoration goes before its toplevel, as the protocol asks.)
@(private)
wl_role_destroy :: proc(st: ^Wl_Window_State) {
	if st.decoration != nil { wl.proxy_marshal_flags(st.decoration, ZXDG_TOPLEVEL_DECORATION_DESTROY, nil, wl.proxy_get_version(st.decoration), WL_MARSHAL_FLAG_DESTROY) }
	if st.xdg_toplevel != nil { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_DESTROY, nil, wl.proxy_get_version(st.xdg_toplevel), WL_MARSHAL_FLAG_DESTROY) }
	if st.xdg_surface != nil { wl.proxy_marshal_flags(st.xdg_surface, XDG_SURFACE_DESTROY, nil, wl.proxy_get_version(st.xdg_surface), WL_MARSHAL_FLAG_DESTROY) }
	st.decoration, st.xdg_toplevel, st.xdg_surface = nil, nil, nil
}

// The role and the surface go; wl_show makes new ones. Not the role alone: the last frames' content updates may wait in
// the surface's queue (a FIFO barrier of wp_fifo_v1 that an unmapped surface never clears), and every later commit,
// the new role's first one included, would wait behind them. A new surface starts with an empty queue. What renders to
// the surface releases it first (host_hide: render.surface_drop).
@(private)
wl_hide :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil || st.surface == nil { return }
	// what the seat keeps of the window: its leave may name a surface that is gone
	if wlc.pointer_focus == w { wlc.pointer_focus = nil }
	if wlc.keyboard_focus == w { wlc.keyboard_focus = nil; wlc.key_repeat.held = false }
	window_focus(w, false, {})
	wl_role_destroy(st)
	wl_surface_destroy(st)
	wl.display_flush(wlc.display)
	w.show = .Hidden
}

@(private)
wl_destroy :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil { return }
	for x, i in wlc.windows { if x == w { ordered_remove(&wlc.windows, i); break } }
	// what the seat keeps of the window: the compositor's leave for it may still be on its way
	if wlc.pointer_focus == w { wlc.pointer_focus = nil }
	if wlc.keyboard_focus == w { wlc.keyboard_focus = nil; wlc.key_repeat.held = false }
	if wlc.dnd_window == w { wlc.dnd_window = nil }
	if wlc.ti_window == w { wlc.ti_window = nil }
	wl_role_destroy(st)
	wl_surface_destroy(st)
	wl.display_flush(wlc.display)
	delete(st.title)
	free(st)
	w.wl = nil
}

@(private)
wl_set_title :: proc(w: ^Window, title: string) {
	st := wl_state(w)
	c := strings.clone_to_cstring(title, context.temp_allocator)
	if st.xdg_toplevel != nil { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, nil, wl.proxy_get_version(st.xdg_toplevel), 0, c) }   // (hidden: the next role takes st.title)
	if title != st.title { delete(st.title); st.title = strings.clone(title) }
	wl.display_flush(wlc.display)
}

@(private)
wl_set_size :: proc(w: ^Window, px: [2]int) {
	w.size = px
	w.paint_requested = true
	if st := wl_state(w); st != nil {
		st.logical = {max(int(f32(px.x) / w.dpi_scale + 0.5), 1), max(int(f32(px.y) / w.dpi_scale + 0.5), 1)}
		wl_size_from_logical(w, st)
	}
}
//   // the renderer reconfigures; the compositor does not set a client size
@(private)
wl_show :: proc(w: ^Window) {
	st := wl_state(w)
	if st.surface == nil {
		// hidden (wl_hide): a new surface and role, their first configure, then the next frame's buffer maps them. The
		// renderer makes its surface on the new one (Window.shown_again: host_frame, render.surface_remake).
		st.toplevel = .Normal
		if !wl_surface_make(w, st) { return }
		w.shown_again += 1
		// A buffer before the first configure is acked is a protocol error, and a compositor may send that configure after
		// a roundtrip (Hyprland lays the window out first): wait for it.
		deadline := time.tick_add(time.tick_now(), WL_FIRST_CONFIGURE_WAIT_MS * time.Millisecond)
		for !st.acked && time.tick_diff(time.tick_now(), deadline) > 0 {
			wl.display_roundtrip(wlc.display)
			if !st.acked { poll_fd_wait(wlc.fd, WL_FIRST_CONFIGURE_POLL_MS) }
		}
		w.show = st.toplevel
		w.paint_requested = true
		return
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	wl.display_flush(wlc.display)
	w.show = st.toplevel
}
@(private) wl_minimize :: proc(w: ^Window) { st := wl_state(w); if st.xdg_toplevel == nil { return }; wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_MINIMIZED, nil, wl.proxy_get_version(st.xdg_toplevel), 0); wl.display_flush(wlc.display) }
@(private)
wl_set_maximized :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	if st.xdg_toplevel == nil { return }
	op: u32 = on ? XDG_TOPLEVEL_SET_MAXIMIZED : XDG_TOPLEVEL_UNSET_MAXIMIZED
	wl.proxy_marshal_flags(st.xdg_toplevel, op, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
	wl.display_flush(wlc.display)
}
@(private)
wl_set_fullscreen :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	if st.xdg_toplevel == nil { return }
	if on { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, nil, wl.proxy_get_version(st.xdg_toplevel), 0, nil) }
	else  { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_UNSET_FULLSCREEN, nil, wl.proxy_get_version(st.xdg_toplevel), 0) }
	wl.display_flush(wlc.display)
}
@(private)
wl_set_decorations :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	if st.decoration == nil { return }
	mode: u32 = on ? ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE : ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE
	wl.proxy_marshal_flags(st.decoration, ZXDG_TOPLEVEL_DECORATION_SET_MODE, nil, wl.proxy_get_version(st.decoration), 0, mode)
	wl.display_flush(wlc.display)
}
@(private) wl_set_dark :: proc(w: ^Window, dark: bool) {}
@(private) wl_transparent :: proc(w: ^Window) -> bool { return wl_state(w).transparent }
@(private) wl_fd :: proc(w: ^Window) -> i32 { return wlc.link == .Connected ? wlc.fd : -1 }
@(private)
wl_show_window_menu :: proc(w: ^Window, pos: [2]f32) {
	st := wl_state(w)
	if wlc.seat == nil || st.xdg_toplevel == nil { return }
	// (the serial of the press that asked for it; the place in the surface's units)
	scale := w.dpi_scale > 0 ? w.dpi_scale : 1
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SHOW_WINDOW_MENU, nil, wl.proxy_get_version(st.xdg_toplevel), 0, wlc.seat, wlc.button_serial, i32(pos.x / scale), i32(pos.y / scale))
	wl.display_flush(wlc.display)
}

////////////////////////////////
// pump

@(private)
wl_push :: proc(w: ^Window, e: Event) {
	e := e
	e.stamp = time.tick_now()
	append(&w.events, e)
}

// Reads what the socket holds, without waiting, and dispatches it (wl_display_dispatch_pending alone never reads).
@(private)
wl_read_available :: proc() {
	if wlc.link != .Connected { return }
	l := wayland_lib()
	defer wl_check_link()
	for l.display_prepare_read(wlc.display) != 0 { if l.display_dispatch_pending(wlc.display) < 0 { return } }
	l.display_flush(wlc.display)
	if poll_fd_wait(wlc.fd, 0) > 0 { l.display_read_events(wlc.display) } else { l.display_cancel_read(wlc.display) }
	l.display_dispatch_pending(wlc.display)
}

@(private)
wl_pump :: proc(w: ^Window, wait: bool, timeout_ms: int) {
	l := wayland_lib()
	// dispatch anything already queued without blocking
	l.display_dispatch_pending(wlc.display)
	l.display_flush(wlc.display)
	if wait && len(w.events) == 0 && len(w.injected) == 0 { poll_sources(w, wl_fd(w), wl_poll_timeout(timeout_ms)) }
	wl_read_available()
	wl_key_repeat_tick()
	dbus_pump()
	l.display_flush(wlc.display)
}

// A display in error has no more events, and its socket reads as ready for good.
@(private)
wl_check_link :: proc() {
	if wlc.link != .Connected || wl.display_get_error(wlc.display) == 0 { return }
	wlc.link = .Lost
	display_lost(wlc.windows[:])
}

@(private)
// Until something comes for the window (its input, a repaint asked for), the clipboard changes, a wake, the session bus,
// the accessibility bus, or the time. The connection's fd alone is not enough: the renderer's own traffic (the presentation
// feedback and the FIFO events of the frame just shown, the ids of its callbacks) makes it readable at each refresh, and a
// wait that ended there drew a frame at each refresh, for ever.
wl_wait :: proc(w: ^Window, timeout_ms: int) {
	deadline := time.tick_add(time.tick_now(), time.Duration(timeout_ms) * time.Millisecond)
	clip_was := clipboard_sequence()
	for {
		// (what a roundtrip read: poll(2) would not see it; kept for the next poll_events)
		wl_read_available()
		if wait_is_over(w) || clipboard_sequence() != clip_was { return }
		wl.display_flush(wlc.display)
		left := -1
		if timeout_ms > 0 {
			left = int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
			if left <= 0 { return }
		}
		r := poll_sources(w, wl_fd(w), wl_poll_timeout(left))
		if !r.conn || r.other { return }   // (the time, a key's repeat, or another source)
	}
}

@(private)
wl_take_input :: proc(w: ^Window) {
	wl_read_available()
	wl_key_repeat_tick()
}

////////////////////////////////
// text clipboard (wl_data_device) — the richer flavours and drag and drop are in clipboard_linux.odin

@(private)
Data_Device_Listener :: struct {
	data_offer:   proc "c" (data: rawptr, dd: Wl_Proxy, offer: Wl_Proxy),
	enter:        proc "c" (data: rawptr, dd: Wl_Proxy, serial: u32, surface: Wl_Proxy, x, y: Wl_Fixed, offer: Wl_Proxy),
	leave:        proc "c" (data: rawptr, dd: Wl_Proxy),
	motion:       proc "c" (data: rawptr, dd: Wl_Proxy, time: u32, x, y: Wl_Fixed),
	drop:         proc "c" (data: rawptr, dd: Wl_Proxy),
	selection:    proc "c" (data: rawptr, dd: Wl_Proxy, offer: Wl_Proxy),
}
@(private) data_device_listener := Data_Device_Listener{dd_data_offer, dd_enter, dd_leave, dd_motion, dd_drop, dd_selection}
// The data_device callbacks route to the clipboard / drag-and-drop code (clipboard_wl_linux.odin, dragdrop_wl_linux.odin).
@(private)
dd_data_offer :: proc "c" (data: rawptr, dd: Wl_Proxy, offer: Wl_Proxy) {
	context = wl_ctx_real()
	wl_offer_new(offer)
}
@(private)
dd_enter :: proc "c" (data: rawptr, dd: Wl_Proxy, serial: u32, surface: Wl_Proxy, x, y: Wl_Fixed, offer: Wl_Proxy) {
	context = wl_ctx_real()
	wl_dnd_enter(serial, surface, f32(wl_fixed_to_f64(x)), f32(wl_fixed_to_f64(y)), offer)
}
@(private)
dd_leave :: proc "c" (data: rawptr, dd: Wl_Proxy) { context = wl_ctx_real(); wl_dnd_leave() }
@(private)
dd_motion :: proc "c" (data: rawptr, dd: Wl_Proxy, time: u32, x, y: Wl_Fixed) {
	context = wl_ctx_real()
	wl_dnd_motion(f32(wl_fixed_to_f64(x)), f32(wl_fixed_to_f64(y)))
}
@(private)
dd_drop :: proc "c" (data: rawptr, dd: Wl_Proxy) { context = wl_ctx_real(); wl_dnd_drop() }
@(private)
dd_selection :: proc "c" (data: rawptr, dd: Wl_Proxy, offer: Wl_Proxy) {
	context = wl_ctx_real()
	wl_selection_set(offer)
}

@(private)
sys_mmap :: proc "contextless" (addr: rawptr, length: uint, prot, flags, fd: i32, offset: int) -> rawptr {
	return raw_mmap(addr, length, prot, flags, fd, offset)
}
foreign import libc_wl "system:c"
@(default_calling_convention = "c", private)
foreign libc_wl {
	@(link_name="mmap")   raw_mmap   :: proc(addr: rawptr, length: uint, prot, flags, fd: i32, offset: int) -> rawptr ---
	@(link_name="munmap") sys_munmap :: proc(addr: rawptr, length: uint) -> i32 ---
}

// A wl_buffer of `size` pixels in shared memory (ARGB8888, in memory BGRA), holding `bgra` when given. nil when the system refused.
@(private)
wl_shm_buffer :: proc(size: [2]int, bgra: []u8 = nil) -> Wl_Proxy {
	if wlc.shm == nil { return nil }
	stride, bytes := size.x * 4, size.x * size.y * 4
	fd := memfd_create("gui_toolkit", 0)
	if fd < 0 { return nil }
	defer posix.close(posix.FD(fd))
	if posix.ftruncate(posix.FD(fd), posix.off_t(bytes)) != .OK { return nil }
	if len(bgra) >= bytes {
		PROT_READ_WRITE :: 3
		MAP_SHARED :: 1
		mem := sys_mmap(nil, uint(bytes), PROT_READ_WRITE, MAP_SHARED, fd, 0)
		if mem == nil || mem == rawptr(~uintptr(0)) { return nil }
		copy(([^]u8)(mem)[:bytes], bgra[:bytes])
		sys_munmap(mem, uint(bytes))
	}
	pool := wl.proxy_marshal_flags(wlc.shm, WL_SHM_CREATE_POOL, wl.shm_pool_interface, wl.proxy_get_version(wlc.shm), 0, nil, fd, i32(bytes))
	if pool == nil { return nil }
	buffer := wl.proxy_marshal_flags(pool, WL_SHM_POOL_CREATE_BUFFER, wl.buffer_interface, wl.proxy_get_version(pool), 0, nil, i32(0), i32(size.x), i32(size.y), i32(stride), u32(0))
	wl.proxy_marshal_flags(pool, WL_SHM_POOL_DESTROY, nil, wl.proxy_get_version(pool), WL_MARSHAL_FLAG_DESTROY)
	return buffer
}

// Shows the window with a plain picture: a surface without a buffer is not on the screen, gets no pointer nor keyboard. For
// a test that has no renderer (tests/linux_desktop). No-op on X11, whose windows are on the screen once mapped.
test_show_plain :: proc(w: ^Window) {
	if w.backend != .Wayland { return }
	st := wl_state(w)
	if st == nil { return }
	buffer := wl_shm_buffer({max(w.size.x, 1), max(w.size.y, 1)})
	if buffer == nil { return }
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_ATTACH, nil, wl.proxy_get_version(st.surface), 0, buffer, i32(0), i32(0))
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	wl.display_roundtrip(wlc.display)
}
@(private = "file") WL_SHM_CREATE_POOL :: 0
@(private = "file") WL_SHM_POOL_CREATE_BUFFER :: 0
@(private = "file") WL_SHM_POOL_DESTROY :: 1
foreign import libc_memfd "system:c"
@(default_calling_convention = "c", private = "file")
foreign libc_memfd {
	memfd_create :: proc(name: cstring, flags: u32) -> i32 ---
}

_ :: mem
