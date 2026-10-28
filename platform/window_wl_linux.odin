#+build linux
package platform

// The Wayland window backend, over libwayland-client (by dlopen). One wl_display per process, shared by every window of
// the thread. A window is a wl_surface with an xdg_surface and xdg_toplevel (xdg-shell, wl_protocol_linux.odin). Server
// decorations are asked for through zxdg_decoration_manager_v1 when the compositor has it (KDE); where it does not
// (GNOME), the window is undecorated and the app draws its own title bar (integrated title) — the toolkit already does
// this on Windows, so the same frame works. Input comes from wl_seat (wl_pointer, wl_keyboard with its xkbcommon
// keymap, wl_touch); DPI from the wl_output scale (and wp_fractional_scale when the compositor offers it). The
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

// Process-wide Wayland connection and the globals bound from the registry.
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
	fractional_manager: rawptr,   // wp_fractional_scale_manager_v1 (optional; name only, not marshalled here)
	pointer:    Wl_Proxy,
	keyboard:   Wl_Proxy,
	touch:      Wl_Proxy,
	fd:         i32,
	output_scale: i32,            // integer buffer scale from wl_output (1, 2...)
	output_px:  [2]i32,           // the current output mode's pixel size (wl_output mode; 0 until one arrives)
	xkb_ctx:    Xkb_Context,
	xkb_keymap: Xkb_Keymap,
	xkb_state:  Xkb_State,
	// the seat's focus: which window the pointer / keyboard are over now (for routing input)
	pointer_focus:  ^Window,
	keyboard_focus: ^Window,
	pointer_pos:    [2]f32,
	// the clipboard text another client offered, and the fd/offer plumbing (clipboard_linux.odin uses the richer parts)
	clip_text:  string,
	have_offer: bool,
	offer:      Wl_Proxy,
	// the keyboard-enter serial: a wl_data_device.set_selection needs a recent input serial (clipboard owner)
	kbd_serial: u32,
	// the clipboard selection owner we run, and the MIME types the current selection offer advertises
	data_source:   Wl_Proxy,      // our wl_data_source while we own CLIPBOARD, nil otherwise
	offer_mimes:   [dynamic]string,   // the MIME types wlc.offer advertises (filled by the offer's `offer` events)
	// the primary (middle-click) selection, over zwp_primary_selection_v1 when the compositor has it
	primary_manager: Wl_Proxy,
	primary_device:  Wl_Proxy,
	primary_source:  Wl_Proxy,
	primary_offer:   Wl_Proxy,
	primary_mimes:   [dynamic]string,
	have_primary_offer: bool,
	// drag and drop (dragdrop_wl_linux.odin): the data-device drag state lives here so its listeners reach it
	dnd_offer:     Wl_Proxy,      // the offer of a drag now over a window
	dnd_mimes:     [dynamic]string,
	dnd_window:    ^Window,
	dnd_enter_serial: u32,
	dnd_x, dnd_y:  f32,
	dnd_source:    Wl_Proxy,      // our wl_data_source while we drag from this app
	dnd_sending:   bool,
	// IME (ime_wl_linux.odin): the text-input manager and the per-seat text-input object
	ti_manager:    Wl_Proxy,
	text_input:    Wl_Proxy,
	ti_enabled:    bool,
	ti_window:     ^Window,       // the window the text-input is enabled for
	preedit:       string,        // the uncommitted preedit string being built this commit cycle
	preedit_cursor: int,
	preedit_dirty: bool,
	pending_preedit: string,      // the preedit from preedit_string, applied on `done`
	pending_commit:  string,      // the committed string from commit_string, applied on `done`
	// cursor shapes (cursors_wl_linux.odin): the compositor draws them from a named shape (wp_cursor_shape_v1)
	cursor_shape_manager: Wl_Proxy,
	cursor_shape_device:  Wl_Proxy,
}

@(private) wlc: Wl_Conn
@(private) wl_ready: bool

@(private)
Wl_Window_State :: struct {
	surface:     Wl_Proxy,
	xdg_surface: Wl_Proxy,
	xdg_toplevel: Wl_Proxy,
	decoration:  Wl_Proxy,
	frame_cb:    Wl_Proxy,
	transparent: bool,
	title:       string,
	configured:  bool,
	pending_w, pending_h: int,     // the size the last xdg_toplevel.configure asked for (0 = app chooses)
	win:         ^Window,          // back pointer for the listeners
}

@(private)
wl_state :: proc(w: ^Window) -> ^Wl_Window_State { return (^Wl_Window_State)(w.wl) }

// Every request is marshalled by wl.proxy_marshal_flags directly (a true C variadic): the new-id argument is passed as
// nil (the library fills the id) when the request makes a new proxy, and the request arguments follow in protocol order.

@(private)
wl_connect :: proc() -> bool {
	if wl_ready { return wlc.display != nil }
	wl_ready = true
	l := wayland_lib()
	if !l.ok { return false }
	xdg_build_tables()
	zwp_build_tables()
	zwp_ti_build_tables()
	wp_cursor_shape_build_tables()
	wlc.display = l.display_connect(nil)
	if wlc.display == nil { return false }
	wlc.fd = l.display_get_fd(wlc.display)
	wlc.output_scale = 1
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
	if wlc.primary_manager != nil && wlc.seat != nil {
		wlc.primary_device = wl.proxy_marshal_flags(wlc.primary_manager, ZWP_PRIMARY_DEVICE_MANAGER_GET_DEVICE,
			&zwp_primary_device_iface, wl.proxy_get_version(wlc.primary_manager), 0, nil, wlc.seat)
		if wlc.primary_device != nil { l.proxy_add_listener(wlc.primary_device, &primary_device_listener, nil) }
	}
	if wlc.ti_manager != nil && wlc.seat != nil {
		wlc.text_input = wl.proxy_marshal_flags(wlc.ti_manager, ZWP_TI_MANAGER_GET_TEXT_INPUT,
			&zwp_ti_iface, wl.proxy_get_version(wlc.ti_manager), 0, nil, wlc.seat)
		if wlc.text_input != nil { l.proxy_add_listener(wlc.text_input, &text_input_listener, nil) }
	}
	return wlc.xdg_wm_base != nil && wlc.compositor != nil
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

@(private)
registry_global :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32, iface: cstring, version: u32) {
	context = wl_ctx_real()
	s := string(iface)
	bind :: proc(name: u32, iface: ^Wl_Interface, want: u32, have: u32) -> Wl_Proxy {
		v := min(want, have)
		return wl.proxy_marshal_flags(wlc.registry, WL_REGISTRY_BIND, iface, v, 0, name, iface.name, v, nil)
	}
	switch s {
	case "wl_compositor": wlc.compositor = bind(name, wl.compositor_interface, 4, version)
	case "wl_shm":        wlc.shm = bind(name, wl.shm_interface, 1, version)
	case "wl_output":     if wlc.output == nil { wlc.output = bind(name, wl.output_interface, 2, version); wl.proxy_add_listener(wlc.output, &output_listener, nil) }
	case "wl_seat":
		if wlc.seat == nil {
			wlc.seat = bind(name, wl.seat_interface, 5, version)
			wl.proxy_add_listener(wlc.seat, &seat_listener, nil)
		}
	case "wl_data_device_manager": wlc.data_device_manager = bind(name, wl.data_device_manager_interface, 3, version)
	case "xdg_wm_base":   wlc.xdg_wm_base = bind(name, &xdg_wm_base_iface, 4, version)
	case "zxdg_decoration_manager_v1": wlc.decoration_manager = bind(name, &zxdg_decoration_manager_iface, 1, version)
	case "zwp_primary_selection_device_manager_v1": wlc.primary_manager = bind(name, &zwp_primary_device_manager_iface, 1, version)
	case "zwp_text_input_manager_v3": wlc.ti_manager = bind(name, &zwp_ti_manager_iface, 1, version)
	case "wp_cursor_shape_manager_v1": wlc.cursor_shape_manager = bind(name, &wp_cursor_shape_manager_iface, 1, version)
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
@(private) output_refresh_mhz: i32
@(private)
output_geometry :: proc "c" (data: rawptr, o: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {}
@(private)
output_mode :: proc "c" (data: rawptr, o: Wl_Proxy, flags: u32, w, h, refresh: i32) { if flags & 1 != 0 { output_refresh_mhz = refresh; wlc.output_px = {w, h} } }
@(private)
output_done :: proc "c" (data: rawptr, o: Wl_Proxy) {}
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
	WL_SEAT_POINTER :: 1; WL_SEAT_KEYBOARD :: 2; WL_SEAT_TOUCH :: 4
	if caps & WL_SEAT_POINTER != 0 && wlc.pointer == nil {
		wlc.pointer = wl.proxy_marshal_flags(seat, WL_SEAT_GET_POINTER, wl.pointer_interface, wl.proxy_get_version(seat), 0, nil)
		wl.proxy_add_listener(wlc.pointer, &pointer_listener, nil)
	}
	if caps & WL_SEAT_KEYBOARD != 0 && wlc.keyboard == nil {
		wlc.keyboard = wl.proxy_marshal_flags(seat, WL_SEAT_GET_KEYBOARD, wl.keyboard_interface, wl.proxy_get_version(seat), 0, nil)
		wl.proxy_add_listener(wlc.keyboard, &keyboard_listener, nil)
	}
	if caps & WL_SEAT_TOUCH != 0 && wlc.touch == nil {
		wlc.touch = wl.proxy_marshal_flags(seat, WL_SEAT_GET_TOUCH, wl.touch_interface, wl.proxy_get_version(seat), 0, nil)
	}
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
	wlc.pointer_focus = window_of_surface(surface)
	wlc.pointer_pos = {f32(wl_fixed_to_f64(sx)), f32(wl_fixed_to_f64(sy))}
	wl_enter_serial = serial
}
@(private) wl_enter_serial: u32
@(private) wl_button_serial: u32   // the last pointer button serial (for a drag start / selection)
@(private)
ptr_leave :: proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy) {
	context = wl_ctx_real()
	if w := wlc.pointer_focus; w != nil { wl_push(w, {kind = .Mouse_Leave}) }
	wlc.pointer_focus = nil
}
@(private)
ptr_motion :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, sx, sy: Wl_Fixed) {
	context = wl_ctx_real()
	w := wlc.pointer_focus
	if w == nil { return }
	wlc.pointer_pos = {f32(wl_fixed_to_f64(sx)) * w.dpi_scale, f32(wl_fixed_to_f64(sy)) * w.dpi_scale}
	wl_push(w, {kind = .Mouse_Move, pos = wlc.pointer_pos, mods = wl_mods(), buttons = w.buttons_down})
}
@(private)
ptr_button :: proc "c" (data: rawptr, p: Wl_Proxy, serial, time, button, state: u32) {
	context = wl_ctx_real()
	wl_button_serial = serial
	w := wlc.pointer_focus
	if w == nil { return }
	// Linux input-event-codes: BTN_LEFT 0x110, BTN_RIGHT 0x111, BTN_MIDDLE 0x112
	btn: Mouse_Button
	switch button {
	case 0x110: btn = .Left
	case 0x111: btn = .Right
	case 0x112: btn = .Middle
	case: return
	}
	press := state == 1
	if press { w.buttons_down += {btn} } else { w.buttons_down -= {btn} }
	wl_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = btn, pos = wlc.pointer_pos, mods = wl_mods(), buttons = w.buttons_down})
}
@(private)
ptr_axis :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, axis: u32, value: Wl_Fixed) {
	context = wl_ctx_real()
	w := wlc.pointer_focus
	if w == nil { return }
	// axis 0 vertical, 1 horizontal; value is in surface units (a notch ~= 10). Our delta is in notches (+y = down).
	v := f32(wl_fixed_to_f64(value)) / 10
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
	if wlc.xkb_keymap != nil { k.keymap_unref(wlc.xkb_keymap) }
	if wlc.xkb_state != nil { k.state_unref(wlc.xkb_state) }
	wlc.xkb_keymap = k.keymap_new_from_string(wlc.xkb_ctx, s, 1 /*TEXT_V1*/, XKB_KEYMAP_COMPILE_NO_FLAGS)
	if wlc.xkb_keymap != nil { wlc.xkb_state = k.state_new(wlc.xkb_keymap) }
}
@(private)
kb_enter :: proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy, keys: ^Wl_Array) {
	context = wl_ctx_real()
	wlc.kbd_serial = serial
	wlc.keyboard_focus = window_of_surface(surface)
	if w := wlc.keyboard_focus; w != nil { w.focused = true; w.active = true; wl_push(w, {kind = .Activate}) }
}
@(private)
kb_leave :: proc "c" (data: rawptr, kb: Wl_Proxy, serial: u32, surface: Wl_Proxy) {
	context = wl_ctx_real()
	if w := wlc.keyboard_focus; w != nil { w.focused = false; w.active = false; wl_push(w, {kind = .Activate}) }
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
	sym := k.state_key_get_one_sym(wlc.xkb_state, keycode)
	kk := key_from_keysym(sym)
	press := state == 1
	mods := wl_mods()
	if kk != .None { wl_push(w, {kind = press ? .Key_Press : .Key_Release, key = kk, mods = mods}) }
	if press && .Ctrl not_in mods && .Alt not_in mods {
		buf: [8]u8
		n := k.state_key_get_utf8(wlc.xkb_state, keycode, &buf[0], size_of(buf))
		if n > 0 { if r, sz := utf8.decode_rune(string(buf[:n])); sz > 0 && r >= 32 && r != 127 { wl_push(w, {kind = .Text, text = r, mods = mods}) } }
	}
}
@(private)
kb_modifiers :: proc "c" (data: rawptr, kb: Wl_Proxy, serial, dep, latched, locked, group: u32) {
	k := &xkb
	if k.ok && wlc.xkb_state != nil { k.state_update_mask(wlc.xkb_state, dep, latched, locked, 0, 0, group) }
}
@(private) kb_repeat :: proc "c" (data: rawptr, kb: Wl_Proxy, rate, delay: i32) {}

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
	w := st.win
	if st.pending_w > 0 && st.pending_h > 0 {
		pw, ph := int(f32(st.pending_w) * w.dpi_scale), int(f32(st.pending_h) * w.dpi_scale)
		if pw != w.size.x || ph != w.size.y { w.size = {pw, ph} }
	}
	st.configured = true
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
	// decode the states array (u32 each): 1 maximized, 2 fullscreen, 4 activated
	st.win.maximized = false
	st.win.fullscreen = false
	if states != nil && states.data != nil {
		n := states.size / size_of(u32)
		arr := ([^]u32)(states.data)
		for i in 0 ..< n {
			switch arr[i] {
			case 1: st.win.maximized = true
			case 2: st.win.fullscreen = true
			}
		}
	}
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
@(private) decoration_configure :: proc "c" (data: rawptr, d: Wl_Proxy, mode: u32) {}

@(private)
Frame_Listener :: struct { done: proc "c" (data: rawptr, cb: Wl_Proxy, time: u32) }
@(private) frame_listener := Frame_Listener{frame_done}
@(private)
frame_done :: proc "c" (data: rawptr, cb: Wl_Proxy, time: u32) {
	st := (^Wl_Window_State)(data)
	if st != nil { st.frame_cb = nil }
}

////////////////////////////////
// lifecycle

@(private)
wl_open :: proc(w: ^Window, title: string, size: [2]int, transparent: bool) -> bool {
	if !wl_connect() { report_missing("libwayland-client (or xdg-shell)"); return false }
	st := new(Wl_Window_State)
	st.win = w
	st.transparent = transparent
	st.title = strings.clone(title)
	w.wl = st
	w.dpi_scale = f32(wlc.output_scale)

	st.surface = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
	if st.surface == nil { free(st); w.wl = nil; return false }
	wl.proxy_set_user_data(st.surface, st)

	st.xdg_surface = wl.proxy_marshal_flags(wlc.xdg_wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_iface, wl.proxy_get_version(wlc.xdg_wm_base), 0, nil, st.surface)
	wl.proxy_add_listener(st.xdg_surface, &xdg_surface_listener, st)
	st.xdg_toplevel = wl.proxy_marshal_flags(st.xdg_surface, XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_iface, wl.proxy_get_version(st.xdg_surface), 0, nil)
	wl.proxy_add_listener(st.xdg_toplevel, &xdg_toplevel_listener, st)

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, nil, wl.proxy_get_version(st.xdg_toplevel), 0, ctitle)
	app_id := strings.clone_to_cstring("gui_toolkit", context.temp_allocator)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_APP_ID, nil, wl.proxy_get_version(st.xdg_toplevel), 0, app_id)

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

	w.size = {max(int(f32(size.x) * w.dpi_scale), 1), max(int(f32(size.y) * w.dpi_scale), 1)}
	if wlc.output_scale > 1 {
		wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_BUFFER_SCALE, nil, wl.proxy_get_version(st.surface), 0, wlc.output_scale)
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	wl.display_roundtrip(wlc.display)   // the first configure arrives; the surface is ready for the renderer
	return true
}

@(private)
wl_destroy :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil { return }
	if wlc.pointer_focus == w { wlc.pointer_focus = nil }
	if wlc.keyboard_focus == w { wlc.keyboard_focus = nil }
	if st.frame_cb != nil { wl.proxy_destroy(st.frame_cb) }
	if st.decoration != nil { wl.proxy_marshal_flags(st.decoration, ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE /*destroy op 0*/, nil, wl.proxy_get_version(st.decoration), WL_MARSHAL_FLAG_DESTROY) }
	if st.xdg_toplevel != nil { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_DESTROY, nil, wl.proxy_get_version(st.xdg_toplevel), WL_MARSHAL_FLAG_DESTROY) }
	if st.xdg_surface != nil { wl.proxy_marshal_flags(st.xdg_surface, XDG_SURFACE_DESTROY, nil, wl.proxy_get_version(st.xdg_surface), WL_MARSHAL_FLAG_DESTROY) }
	if st.surface != nil { wl.proxy_marshal_flags(st.surface, WL_SURFACE_DESTROY, nil, wl.proxy_get_version(st.surface), WL_MARSHAL_FLAG_DESTROY) }
	wl.display_flush(wlc.display)
	delete(st.title)
	free(st)
	w.wl = nil
}

@(private)
wl_set_title :: proc(w: ^Window, title: string) {
	st := wl_state(w)
	c := strings.clone_to_cstring(title, context.temp_allocator)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_TITLE, nil, wl.proxy_get_version(st.xdg_toplevel), 0, c)
	if title != st.title { delete(st.title); st.title = strings.clone(title) }
	wl.display_flush(wlc.display)
}

@(private) wl_set_size :: proc(w: ^Window, px: [2]int) { w.size = px; w.paint_requested = true }   // the renderer reconfigures; the compositor does not set a client size
@(private)
wl_show :: proc(w: ^Window) {
	st := wl_state(w)
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	wl.display_flush(wlc.display)
}
@(private) wl_minimize :: proc(w: ^Window) { st := wl_state(w); wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_MINIMIZED, nil, wl.proxy_get_version(st.xdg_toplevel), 0); wl.display_flush(wlc.display) }
@(private)
wl_set_maximized :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	op: u32 = on ? XDG_TOPLEVEL_SET_MAXIMIZED : XDG_TOPLEVEL_UNSET_MAXIMIZED
	wl.proxy_marshal_flags(st.xdg_toplevel, op, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
	wl.display_flush(wlc.display)
}
@(private)
wl_set_fullscreen :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
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
@(private) wl_fd :: proc(w: ^Window) -> i32 { return wlc.fd }
@(private)
wl_show_window_menu :: proc(w: ^Window, pos: [2]f32) {
	st := wl_state(w)
	if wlc.seat == nil { return }
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SHOW_WINDOW_MENU, nil, wl.proxy_get_version(st.xdg_toplevel), 0, wlc.seat, wl_enter_serial, i32(pos.x), i32(pos.y))
	wl.display_flush(wlc.display)
}
@(private) wl_wake :: proc(w: ^Window) { wl.display_flush(wlc.display) }

////////////////////////////////
// pump

@(private)
wl_push :: proc(w: ^Window, e: Event) {
	e := e
	e.stamp = time.tick_now()
	append(&w.events, e)
}

@(private)
wl_pump :: proc(w: ^Window, wait: bool, timeout_ms: int) {
	l := wayland_lib()
	// dispatch anything already queued without blocking
	l.display_dispatch_pending(wlc.display)
	l.display_flush(wlc.display)
	if wait && len(w.events) == 0 {
		r := poll_two(wlc.fd, dbus_fd(), timeout_ms > 0 ? timeout_ms : -1)
		if r.rendered { l.display_dispatch(wlc.display) }
		if r.readable { dbus_pump() }
	} else {
		l.display_dispatch_pending(wlc.display)
	}
	dbus_pump()
	l.display_flush(wlc.display)
}

@(private)
wl_wait :: proc(w: ^Window, timeout_ms: int) {
	if len(w.events) > 0 || len(w.injected) > 0 { return }
	wl.display_flush(wlc.display)
	poll_fd_wait(wlc.fd, timeout_ms > 0 ? timeout_ms : -1)
}

@(private)
wl_take_input :: proc(w: ^Window) {
	l := wayland_lib()
	l.display_dispatch_pending(wlc.display)
	l.display_flush(wlc.display)
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

_ :: mem
