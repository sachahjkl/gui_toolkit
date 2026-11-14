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
import "core:fmt"
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
	activation: Wl_Proxy,         // xdg_activation_v1 (optional): raise_window asks the focus with it
	virtual_keyboards: Wl_Proxy,  // zwp_virtual_keyboard_manager_v1 (optional): send_hotkey types with it
	subcompositor: Wl_Proxy,      // wl_subcompositor (optional): the resize bands outside the window (outside_bands_wl_linux.odin)
	clear_buffer: Wl_Proxy,       // one transparent pixel, the picture of those bands (made on first use)
	pointer_surface: Wl_Proxy,    // the surface the pointer is on: a window's, or the ring of its bands
	toplevel_manager: Wl_Proxy,   // zwlr_foreign_toplevel_manager_v1 (optional): the session's windows (toplevels)
	layer_shell: Wl_Proxy,        // zwlr_layer_shell_v1 (optional): overlay windows (overlay_wl_linux.odin)
	xdg_output_manager: Wl_Proxy, // zxdg_output_manager_v1 (optional): the outputs' logical places
	outputs:    [dynamic]^Wl_Output_Info,   // every wl_output (`output` is the first one's proxy)
	toplevels:  [dynamic]Wl_Toplevel,
	toplevel_serial: u64,         // the last toplevel's id
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
	key_repeat_told: bool,        // the compositor gave its rate and delay (kb_repeat): input_defaults' no more
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
	activation_token: Wl_Proxy,    // an xdg_activation_token_v1 waiting for its `done` (wl_activate)
	wanted:      Show_State,       // maximized or full screen, asked while there was no role: the next role asks it once
	minimize_wanted: bool,         // minimized, asked while there was no role: the next show asks it once its role is configured
	scale_given: bool,             // a preferred_scale came: until then the scale follows the output's integer one
	win:         ^Window,          // back pointer for the listeners
	frame_cb:    Wl_Proxy,         // wl_surface.frame asked with the last picture, until the compositor says it showed it
	frame_held:  bool,             // a picture waited for that word (wl_frame_shown_held): its coming asks for a repaint
	frame_asked: time.Tick,        // when frame_cb was asked (wl_frame_shown_waited_ms)
	// a picture of this surface was presented (its first frame_shown_ask): until then the compositor has not mapped it,
	// and an activation would name a window it does not know yet (ShojiWM drops it): it waits in activate_*
	presented:   bool,
	drawn:       [2]int,           // w.size at the last picture's commit: another size is a step of a resize no picture shows yet
	output:      u32,              // the registry name of the output the surface entered last (wl_surface.enter); 0: none yet
	activate_pending: bool,        // raise_window asked the focus before the first picture
	activate_token:   string,      // raise_window_token did (owned)
	outside:     Wl_Outside_Bands, // the resize bands around the window (outside_bands_wl_linux.odin)
	// an overlay (open_overlay): a layer surface instead of a toplevel, on the output of that registry name (0: the
	// compositor's choice)
	overlay:     bool,
	layer_surface: Wl_Proxy,
	overlay_output: u32,
	overlay_keyboard: Overlay_Keyboard,   // an overlay's: whether it takes the keyboard from its showing
	// set_input_region: the rects (logical) that take the pointer, when `input_limited`; kept so a new surface gets them
	input_limited: bool,
	input_rects: [dynamic][4]int,
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
	wlc.outputs.allocator = runtime.heap_allocator()
	wlc.display = l.display_connect(nil)
	if wlc.display == nil { return false }
	sigpipe_ignored()
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
	case "wl_output":
		// (each one, for an overlay's choice of output; the first one gives the scale of the windows)
		o := wl_output_add(name, bind(name, wl.output_interface, 2, version))
		if wlc.output == nil && o != nil { wlc.output = o.proxy }
	case "zxdg_output_manager_v1":
		wlc.xdg_output_manager = bind(name, &zxdg_output_manager_iface, ZXDG_OUTPUT_MANAGER_VERSION, version)
		for o in wlc.outputs { wl_xdg_output_of(o) }
	case "zwlr_layer_shell_v1": wlc.layer_shell = bind(name, &zwlr_layer_shell_iface, ZWLR_LAYER_SHELL_VERSION, version)
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
	case "wl_subcompositor": if wl.subcompositor_interface != nil { wlc.subcompositor = bind(name, wl.subcompositor_interface, 1, version) }
	case "wp_viewporter": wlc.viewporter = bind(name, &wp_viewporter_iface, 1, version)
	case "xdg_activation_v1": wlc.activation = bind(name, &xdg_activation_iface, 1, version)
	case "zwp_virtual_keyboard_manager_v1": wlc.virtual_keyboards = bind(name, &vk_manager_iface, 1, version)
	case "zwlr_foreign_toplevel_manager_v1":
		wlc.toplevel_manager = bind(name, &ftl_manager_iface, 3, version)
		wl.proxy_add_listener(wlc.toplevel_manager, &ftl_manager_listener, nil)
	}
}

@(private)
registry_global_remove :: proc "c" (data: rawptr, registry: Wl_Proxy, name: u32) {
	context = wl_ctx_real()
	wl_output_remove(name)
}

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
// (`data` is the output's Wl_Output_Info; the connection's own fields follow the first output, `wlc.output`)
@(private)
output_geometry :: proc "c" (data: rawptr, o: Wl_Proxy, x, y, pw, ph, subpixel: i32, make, model: cstring, transform: i32) {
	if info := (^Wl_Output_Info)(data); info != nil { info.position, info.transform = {x, y}, transform }
}
@(private)
output_mode :: proc "c" (data: rawptr, o: Wl_Proxy, flags: u32, w, h, refresh: i32) {
	if flags & 1 == 0 { return }
	if info := (^Wl_Output_Info)(data); info != nil { info.mode = {w, h} }
	if o == wlc.output { wlc.output_refresh_mhz = refresh; wlc.output_px = {w, h} }
}
// A change of the output is complete: the windows' rate and monitor are read again, and a window without a fractional
// scale follows the output's integer one. So does a window with one that the compositor has given no scale yet: it
// sends one when the surface enters an output or gets its role, not to a surface that was never shown.
@(private)
output_done :: proc "c" (data: rawptr, o: Wl_Proxy) {
	context = wl_ctx_real()
	if o != wlc.output { return }
	for w in wlc.windows {
		w.display_stale = true
		st := wl_state(w)
		// (an overlay's scale is its own output's: wl_open_overlay, fractional_preferred)
		if st.overlay || st.scale_given || w.dpi_scale == f32(wlc.output_scale) { continue }
		w.dpi_scale = f32(wlc.output_scale)
		// (a hidden window has no surface: wl_surface_make sets the buffer scale of the next one)
		if st.surface != nil && st.viewport == nil {
			wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_BUFFER_SCALE, nil, wl.proxy_get_version(st.surface), 0, wlc.output_scale)
		}
		wl_size_from_logical(w, st)
		w.paint_requested = true
		apply_cursor(w)
	}
}
@(private)
output_scale_ev :: proc "c" (data: rawptr, o: Wl_Proxy, factor: i32) {
	if factor <= 0 { return }
	if info := (^Wl_Output_Info)(data); info != nil { info.scale = factor }
	if o == wlc.output { wlc.output_scale = factor }
}

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
	wlc.pointer_surface = surface
	// (as ptr_motion: a click before any motion lands here)
	if wlc.pointer_focus != nil { wlc.pointer_pos = wl_pointer_point(wlc.pointer_focus, surface, sx, sy) }
	wlc.enter_serial = serial
	// (the band under the pointer now: entering the ring shows its resize cursor before any motion)
	if w := wlc.pointer_focus; w != nil { w.frame_hover = frame_hit(w, wlc.pointer_pos); wl_apply_cursor(w) }   // (the compositor forgot it when the pointer left)
}
@(private)
ptr_leave :: proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy) {
	context = wl_ctx_real()
	if w := wlc.pointer_focus; w != nil {
		buttons_released(w, wlc.pointer_pos, wl_mods())   // (the compositor took the pointer: the release will not come here)
		wl_push(w, {kind = .Mouse_Leave})
	}
	wlc.pointer_focus = nil
	wlc.pointer_surface = nil
}
@(private)
ptr_motion :: proc "c" (data: rawptr, p: Wl_Proxy, time: u32, sx, sy: Wl_Fixed) {
	context = wl_ctx_real()
	w := wlc.pointer_focus
	if w == nil { return }
	wlc.pointer_pos = wl_pointer_point(w, wlc.pointer_surface, sx, sy)
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
// double click on the caption maximizes it, a right click there opens the compositor's window menu (unless the app takes
// it: set_caption_menu_app). True when it was
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
		if h != .Caption || w.caption_menu_app { return false }   // (the app's: set_caption_menu_app)
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
		if !wlc.key_repeat_told {   // (the compositor said nothing yet: the thread's input defaults, as they are now)
			d := input_defaults()
			wlc.key_repeat.rate, wlc.key_repeat.delay_ms = d.key_repeat_rate, d.key_repeat_delay_ms
		}
		key_repeat_press(&wlc.key_repeat, keycode, wl_now_ms())
	}
}

// A key's events: its Key_Press or Key_Release, and the text it types.
@(private)
wl_key_emit :: proc(w: ^Window, keycode: u32, press, repeat: bool) {
	k := xkb_lib()
	kk := key_from_xkb(wlc.xkb_keymap, wlc.xkb_state, keycode)
	mods := wl_mods()
	super := wl_super()
	if kk != .None && key_changes(w, kk, press) { wl_push(w, {kind = press ? .Key_Press : .Key_Release, key = kk, mods = mods, repeat = repeat, super = super}) }
	// a key Key does not name: the character of its first level, with no modifier (a recorder of shortcuts reads it)
	if kk == .None && press && !repeat && k.keymap_key_get_syms_by_level != nil && k.state_key_get_layout != nil {
		syms: [^]Xkb_Keysym
		if k.keymap_key_get_syms_by_level(wlc.xkb_keymap, keycode, k.state_key_get_layout(wlc.xkb_state, keycode), 0, &syms) >= 1 {
			if ch := rune(k.keysym_to_utf32(syms[0])); ch > ' ' && ch != RUNE_DEL { wl_push(w, {kind = .Key_Press, char = ch, mods = mods, super = super}) }
		}
	}
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
	wlc.key_repeat_told = true
	if rate <= 0 { wlc.key_repeat.held = false }
}

// Whether the Super key is held (xkb's Mod4, where every layout puts it).
@(private)
wl_super :: proc "contextless" () -> bool {
	k := &xkb
	if !k.ok || wlc.xkb_state == nil { return false }
	return k.state_mod_name_is_active(wlc.xkb_state, "Mod4", XKB_STATE_MODS_EFFECTIVE) > 0
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
	wl_outside_bands_update(w, st)   // (a state without a size: maximized, tiled, back to normal)
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
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st == nil || st.win == nil { return }
	st.server_side = mode == ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE
	st.win.system_frame = st.server_side || st.tiled
	wl_outside_bands_update(st.win, st)
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
	wl_outside_bands_update(w, st)
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
	st.scale_given = true
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
	st.wanted = .Normal
	// a surface for the renderer, with no role: no toplevel exists until the first show, so a window never shown (a
	// program that starts in the notification area) is in no task bar
	if !wl_surface_make(w, st, role = false) { delete(st.title); free(st); w.wl = nil; return false }
	append(&wlc.windows, w)
	// (what the compositor says of the new surface. A surface with no role is on no output: most compositors send its
	// preferred scale only with the first configure of wl_show, which waits for it before the first buffer)
	wl.display_roundtrip(wlc.display)
	return true
}

// How long a shown window waits for its first configure, and how long each poll for it lasts.
@(private) WL_FIRST_CONFIGURE_WAIT_MS :: 500
@(private) WL_FIRST_CONFIGURE_POLL_MS :: 5

// The window's surface and its scale objects, and with `role` its toplevel role, committed without a buffer (the
// compositor answers with the first configure). Made at open without the role, and with it when a hidden window is shown
// again (wl_hide destroyed them).
@(private)
wl_surface_make :: proc(w: ^Window, st: ^Wl_Window_State, role: bool) -> bool {
	st.presented, st.output = false, 0
	st.surface = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
	if st.surface == nil { return false }
	wl.proxy_add_listener(st.surface, &surface_listener, st)   // (also its user data: st)
	if wlc.fractional_manager != nil && wlc.viewporter != nil {
		st.viewport = wl.proxy_marshal_flags(wlc.viewporter, WP_VIEWPORTER_GET_VIEWPORT, &wp_viewport_iface, wl.proxy_get_version(wlc.viewporter), 0, nil, st.surface)
		st.fractional = wl.proxy_marshal_flags(wlc.fractional_manager, WP_FRACTIONAL_MANAGER_GET, &wp_fractional_iface, wl.proxy_get_version(wlc.fractional_manager), 0, nil, st.surface)
		if st.fractional != nil { wl.proxy_add_listener(st.fractional, &fractional_listener, st) }
	}
	wl_size_from_logical(w, st)
	// (an overlay is on one output, whose integer scale wl_open_overlay put in dpi_scale)
	buffer_scale := st.overlay ? i32(max(w.dpi_scale, 1)) : wlc.output_scale
	if buffer_scale > 1 && st.viewport == nil {
		wl.proxy_marshal_flags(st.surface, WL_SURFACE_SET_BUFFER_SCALE, nil, wl.proxy_get_version(st.surface), 0, buffer_scale)
	}
	wl_input_region_apply(st)
	if role {
		if st.overlay { wl_layer_make(st) } else { wl_role_make(w, st) }
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	return true
}

// The surface and its scale objects go (wl_surface_make makes them again), and a request of the focus for it.
@(private)
wl_surface_destroy :: proc(st: ^Wl_Window_State) {
	wl_activation_drop(st)
	wl_outside_bands_destroy(st)
	if st.win != nil { st.win.outside_band = 0 }
	if st.fractional != nil { wl.proxy_marshal_flags(st.fractional, WP_FRACTIONAL_DESTROY, nil, wl.proxy_get_version(st.fractional), WL_MARSHAL_FLAG_DESTROY) }
	if st.viewport != nil { wl.proxy_marshal_flags(st.viewport, WP_VIEWPORT_DESTROY, nil, wl.proxy_get_version(st.viewport), WL_MARSHAL_FLAG_DESTROY) }
	if st.surface != nil { wl.proxy_marshal_flags(st.surface, WL_SURFACE_DESTROY, nil, wl.proxy_get_version(st.surface), WL_MARSHAL_FLAG_DESTROY) }
	if st.frame_cb != nil { wl.proxy_destroy(st.frame_cb) }
	st.fractional, st.viewport, st.surface, st.frame_cb = nil, nil, nil, nil
}

// Where the compositor shows the surface: the output it entered last is the window's (window_output_name).
@(private)
Wl_Surface_Listener :: struct {
	enter:                      proc "c" (data: rawptr, s: Wl_Proxy, output: Wl_Proxy),
	leave:                      proc "c" (data: rawptr, s: Wl_Proxy, output: Wl_Proxy),
	preferred_buffer_scale:     proc "c" (data: rawptr, s: Wl_Proxy, factor: i32),
	preferred_buffer_transform: proc "c" (data: rawptr, s: Wl_Proxy, transform: u32),
}
@(private) surface_listener := Wl_Surface_Listener{wl_surface_enter, wl_surface_leave, wl_surface_buffer_scale, wl_surface_buffer_transform}

@(private)
wl_surface_enter :: proc "c" (data: rawptr, s: Wl_Proxy, output: Wl_Proxy) {
	st := (^Wl_Window_State)(data)
	for o in wlc.outputs { if o.proxy == output { st.output = o.name } }
}
@(private)
wl_surface_leave :: proc "c" (data: rawptr, s: Wl_Proxy, output: Wl_Proxy) {
	st := (^Wl_Window_State)(data)
	for o in wlc.outputs { if o.proxy == output && st.output == o.name { st.output = 0 } }
}
// (the scale comes from wp_fractional_scale; the transform is the output's)
@(private) wl_surface_buffer_scale :: proc "c" (data: rawptr, s: Wl_Proxy, factor: i32) {}
@(private) wl_surface_buffer_transform :: proc "c" (data: rawptr, s: Wl_Proxy, transform: u32) {}

// The name of the output the window is on ("" when the compositor has not said).
@(private)
wl_window_output_name :: proc(w: ^Window) -> string {
	st := wl_state(w)
	if st == nil || st.output == 0 { return "" }
	for o in wlc.outputs { if o.name == st.output { return o.output_name } }
	return ""
}

// The compositor's word that it shows a window's picture: wl_surface.frame, asked with the picture (wl_frame_shown_ask),
// done when the compositor draws it. A window it does not show (covered by another, minimized, on another workspace)
// gets no word until it shows it again.
@(private) Wl_Callback_Listener :: struct { done: proc "c" (data: rawptr, cb: Wl_Proxy, time: u32) }
@(private) frame_shown_listener := Wl_Callback_Listener{wl_frame_shown_done}

@(private)
wl_frame_shown_done :: proc "c" (data: rawptr, cb: Wl_Proxy, time: u32) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	wl.proxy_destroy(cb)
	if st.frame_cb != cb { return }
	st.frame_cb = nil
	// (a picture that waited for this: a repaint makes it. None waited: the word only wakes the loop, which finds nothing
	// due and sleeps. A repaint at each word drew a window at rest again at every refresh, for ever)
	if st.frame_held && st.win != nil { st.win.paint_requested = true }
	st.frame_held = false
	if st.win != nil { wl_activation_flush(st.win, st) }   // (shown: the compositor knows the window now)
}

// A frame drew no picture: the last one was not shown yet. The word, when it comes, asks for a repaint.
@(private)
wl_frame_shown_held :: proc(w: ^Window) {
	st := wl_state(w)
	if st != nil && st.frame_cb != nil { st.frame_held = true }
}

// Asks the word for the window's next commit: call it just before the picture is presented (the present commits it).
@(private)
wl_frame_shown_ask :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil || st.surface == nil { return }
	// (the picture before this one was committed: the window is mapped)
	if st.presented { wl_activation_flush(w, st) }
	st.presented = true
	st.drawn = w.size
	if st.frame_cb != nil { return }
	st.frame_asked = time.tick_now()
	st.frame_cb = wl.proxy_marshal_flags(st.surface, WL_SURFACE_FRAME, wl.callback_interface, wl.proxy_get_version(st.surface), 0, nil)
	if st.frame_cb != nil { wl.proxy_add_listener(st.frame_cb, &frame_shown_listener, st) }
}

// The word asked is not waited for: no picture went with it (its request stays on the surface, its answer goes to a
// proxy that is gone).
@(private)
wl_frame_shown_forget :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil || st.frame_cb == nil { return }
	wl.proxy_destroy(st.frame_cb)
	st.frame_cb = nil
}

// How long the word asked has been waited for, in ms (-1: none is asked).
@(private)
wl_frame_shown_waited_ms :: proc(w: ^Window) -> int {
	st := wl_state(w)
	if st == nil || st.frame_cb == nil { return -1 }
	return int(time.duration_milliseconds(time.tick_since(st.frame_asked)))
}

@(private)
wl_frame_shown_pending :: proc(w: ^Window) -> bool {
	st := wl_state(w)
	return st != nil && st.frame_cb != nil
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
	// (before the first commit: the first configure says it, and the first frame has its size)
	#partial switch st.wanted {
	case .Maximized:  wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_MAXIMIZED, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
	case .Fullscreen: wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, nil, wl.proxy_get_version(st.xdg_toplevel), 0, nil)
	}
	st.wanted = .Normal

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
	if st.layer_surface != nil {
		wl.proxy_marshal_flags(st.layer_surface, ZWLR_LAYER_SURFACE_DESTROY, nil, wl.proxy_get_version(st.layer_surface), WL_MARSHAL_FLAG_DESTROY)
		st.layer_surface = nil
	}
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
	delete(st.activate_token)
	delete(st.input_rects)
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
	if st.overlay {
		// (shown from its opening; after a hide, a new surface and layer surface)
		if st.surface != nil { return }
		if !wl_surface_make(w, st, role = true) { return }
		w.shown_again += 1
		wl_first_configure_wait(st)
		w.show = .Normal
		w.paint_requested = true
		return
	}
	if st.surface == nil || st.xdg_toplevel == nil {
		st.toplevel = .Normal
		if st.surface == nil {
			// hidden (wl_hide): a new surface and role. The renderer makes its surface on the new one
			// (Window.shown_again: host_frame, render.surface_remake).
			if !wl_surface_make(w, st, role = true) { return }
			w.shown_again += 1
		} else {
			// the first show: the role on the surface the window was opened with (no frame came before it: a hidden
			// window gets none, and a surface that had a buffer could not take the role)
			wl_role_make(w, st)
			wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
		}
		wl_first_configure_wait(st)
		// a minimize asked before the show: the role exists and is configured, the next frame maps it minimized (as GTK's
		// minimize of an unmapped window). No configure state says minimized: w.show stays the toplevel's.
		if st.minimize_wanted {
			st.minimize_wanted = false
			wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_MINIMIZED, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
			wl.display_flush(wlc.display)
		}
		w.show = st.toplevel
		w.paint_requested = true
		return
	}
	wl.proxy_marshal_flags(st.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(st.surface), 0)
	wl.display_flush(wlc.display)
	w.show = st.toplevel
}

// A buffer before the first configure is acked is a protocol error, and a compositor may send that configure after a
// roundtrip (Hyprland lays the window out first): wait for it. The next frame's buffer maps the window.
@(private)
wl_first_configure_wait :: proc(st: ^Wl_Window_State) {
	deadline := time.tick_add(time.tick_now(), WL_FIRST_CONFIGURE_WAIT_MS * time.Millisecond)
	for !st.acked && time.tick_diff(time.tick_now(), deadline) > 0 {
		wl.display_roundtrip(wlc.display)
		if !st.acked { poll_fd_wait(wlc.fd, WL_FIRST_CONFIGURE_POLL_MS) }
	}
}

// Asks the compositor to give the window the focus (xdg_activation_v1): a token for the surface, then `activate` with
// it when it comes. The token carries the seat's last input serial this connection saw. A program shown by a command
// (a shortcut of the compositor runs `app show`) has had no input of its own: the serial is then 0, and the compositor
// decides (ShojiWM and Hyprland accept a token of the seat; sway follows focus_on_window_activation).
@(private)
wl_activate :: proc(w: ^Window) {
	st := wl_state(w)
	if st == nil || st.surface == nil || wlc.activation == nil { return }
	if !st.presented { st.activate_pending = true; return }
	wl_activation_drop(st)   // (one request at a time: the newest)
	token := wl.proxy_marshal_flags(wlc.activation, XDG_ACTIVATION_GET_TOKEN, &xdg_activation_token_iface, wl.proxy_get_version(wlc.activation), 0, nil)
	if token == nil { return }
	st.activation_token = token
	wl.proxy_add_listener(token, &activation_token_listener, st)
	if wlc.seat != nil {
		serial := max(wlc.kbd_serial, wlc.button_serial, wlc.enter_serial)
		wl.proxy_marshal_flags(token, XDG_ACTIVATION_TOKEN_SET_SERIAL, nil, wl.proxy_get_version(token), 0, serial, wlc.seat)
	}
	wl.proxy_marshal_flags(token, XDG_ACTIVATION_TOKEN_SET_SURFACE, nil, wl.proxy_get_version(token), 0, st.surface)
	wl.proxy_marshal_flags(token, XDG_ACTIVATION_TOKEN_COMMIT, nil, wl.proxy_get_version(token), 0)
	wl.display_flush(wlc.display)
}

// Asks the focus with a token another program got for us (a notification server, for the click on a notification).
@(private)
wl_activate_token :: proc(w: ^Window, token: string) {
	st := wl_state(w)
	if st == nil || st.surface == nil || wlc.activation == nil { return }
	if !st.presented {
		delete(st.activate_token)
		st.activate_token = strings.clone(token)
		return
	}
	ctoken := strings.clone_to_cstring(token, context.temp_allocator)
	wl.proxy_marshal_flags(wlc.activation, XDG_ACTIVATION_ACTIVATE, nil, wl.proxy_get_version(wlc.activation), 0, ctoken, st.surface)
	wl.display_flush(wlc.display)
}

// The activation asked before the window's first picture, sent now that the compositor shows it.
@(private)
wl_activation_flush :: proc(w: ^Window, st: ^Wl_Window_State) {
	if st.activate_token != "" {
		token := st.activate_token
		st.activate_token, st.activate_pending = "", false
		wl_activate_token(w, token)
		delete(token)
	} else if st.activate_pending {
		st.activate_pending = false
		wl_activate(w)
	}
}

@(private)
wl_activation_drop :: proc(st: ^Wl_Window_State) {
	if st.activation_token == nil { return }
	wl.proxy_marshal_flags(st.activation_token, XDG_ACTIVATION_TOKEN_DESTROY, nil, wl.proxy_get_version(st.activation_token), WL_MARSHAL_FLAG_DESTROY)
	st.activation_token = nil
}

@(private)
Activation_Token_Listener :: struct { done: proc "c" (data: rawptr, t: Wl_Proxy, token: cstring) }
@(private) activation_token_listener := Activation_Token_Listener{activation_token_done}

// (The token of a surface that went is destroyed with it: its `done` never comes here.)
@(private)
activation_token_done :: proc "c" (data: rawptr, t: Wl_Proxy, token: cstring) {
	context = wl_ctx_real()
	st := (^Wl_Window_State)(data)
	if st.activation_token != t { return }
	if st.surface != nil { wl.proxy_marshal_flags(wlc.activation, XDG_ACTIVATION_ACTIVATE, nil, wl.proxy_get_version(wlc.activation), 0, token, st.surface) }
	wl_activation_drop(st)
	wl.display_flush(wlc.display)
}
@(private)
wl_minimize :: proc(w: ^Window) {
	st := wl_state(w)
	if st.xdg_toplevel == nil { st.minimize_wanted = true; return }   // (the next show asks it)
	wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_MINIMIZED, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
	wl.display_flush(wlc.display)
}
@(private)
wl_set_maximized :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	if st.xdg_toplevel == nil {   // (the next role asks it)
		if on { st.wanted = .Maximized } else if st.wanted == .Maximized { st.wanted = .Normal }
		return
	}
	op: u32 = on ? XDG_TOPLEVEL_SET_MAXIMIZED : XDG_TOPLEVEL_UNSET_MAXIMIZED
	wl.proxy_marshal_flags(st.xdg_toplevel, op, nil, wl.proxy_get_version(st.xdg_toplevel), 0)
	wl.display_flush(wlc.display)
}
@(private)
wl_set_fullscreen :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	if st.xdg_toplevel == nil {   // (the next role asks it)
		if on { st.wanted = .Fullscreen } else if st.wanted == .Fullscreen { st.wanted = .Normal }
		return
	}
	if on { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_SET_FULLSCREEN, nil, wl.proxy_get_version(st.xdg_toplevel), 0, nil) }
	else  { wl.proxy_marshal_flags(st.xdg_toplevel, XDG_TOPLEVEL_UNSET_FULLSCREEN, nil, wl.proxy_get_version(st.xdg_toplevel), 0) }
	wl.display_flush(wlc.display)
}
@(private)
wl_set_decorations :: proc(w: ^Window, on: bool) {
	st := wl_state(w)
	wl_outside_bands_update(w, st)   // (w.integrated changed: the bands follow it)
	if st.decoration == nil { return }
	mode: u32 = on ? ZXDG_TOPLEVEL_DECORATION_MODE_SERVER_SIDE : ZXDG_TOPLEVEL_DECORATION_MODE_CLIENT_SIDE
	wl.proxy_marshal_flags(st.decoration, ZXDG_TOPLEVEL_DECORATION_SET_MODE, nil, wl.proxy_get_version(st.decoration), 0, mode)
	wl.display_flush(wlc.display)
}
// Whether the compositor decorates this window when asked (zxdg_decoration_manager_v1: KDE has it, GNOME not).
@(private) wl_server_decorations :: proc(w: ^Window) -> bool { return wl_state(w).decoration != nil }
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
		if wl_wait_over(w) || clipboard_sequence() != clip_was { return }
		wl.display_flush(wlc.display)
		left := -1
		if timeout_ms > 0 {
			// (rounded up: a part of a millisecond left is a millisecond of sleep, not a return that the caller's loop
			// turns into a spin until its deadline)
			rest := time.tick_diff(time.tick_now(), deadline)
			if rest <= 0 { return }
			left = int((rest + time.Millisecond - 1) / time.Millisecond)
		}
		r := poll_sources(w, wl_fd(w), wl_poll_timeout(left))
		if !r.conn || r.other { return }   // (the time, a key's repeat, or another source)
	}
}

// Whether the wait of `w` is over. A loop sleeps for all the windows of its thread at once, on one of them (host.hosts_wait
// waits on the first shown), and one connection brings the events of all: a configure of another shown window (the size
// a tiling compositor gives it, at its mapping or later) asks that window's repaint, which must end the wait too. Else the
// window kept its last size until something came for the one waited on. (Its input stays out: a window the loop does
// not frame could hold some for ever; a hidden window's repaint waits for its show, as wait_is_over says.)
@(private)
wl_wait_over :: proc(w: ^Window) -> bool {
	if wait_is_over(w) { return true }
	for x in wlc.windows { if x != w && x.paint_requested && x.show != .Hidden { return true } }
	return false
}

// Whether another window of the thread has a step of a resize to show now: a size its last picture does not have, and the
// compositor showed that picture (a new one may go). It ends the slot wait of `w` (wait_slot): the windows that are not paced
// make their frames in the paced one's, and a step waiting for its slot is late on the border the compositor moves (it shows
// the last picture stretched to the new size meanwhile). On Windows the system's loop of the window being sized draws it.
@(private)
wl_step_waits :: proc(w: ^Window) -> bool {
	for x in wlc.windows {
		// (as host_steps: a window not shown draws no step, and would end every wait)
		if x == w || x.show == .Hidden || x.show == .Minimized || x.in_poll { continue }
		st := wl_state(x)
		if st != nil && st.surface != nil && st.presented && st.frame_cb == nil && x.size != st.drawn { return true }
	}
	return false
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
	// (a picture is on the surface: the window is mapped, as a present makes it; an activation asked waits for that)
	st.presented = true
	wl_activation_flush(w, st)
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

// send_hotkey on Wayland: a virtual keyboard of the seat (zwp_virtual_keyboard_v1), a keymap that has the key alone (the
// modifiers go by the `modifiers` request, in the masks of xkb's "complete" compatibility: Shift 1, Control 4, Mod1 8,
// Mod4 64), the key pressed and released, the keyboard destroyed. False when the compositor has no such protocol.
@(private)
wl_send_hotkey :: proc(w: ^Window, hk: Hotkey) -> bool {
	if wlc.virtual_keyboards == nil || wlc.seat == nil { return false }
	sym := keysym_of(hk)
	if sym == "" { return false }
	keymap := fmt.tprintf("xkb_keymap {{\nxkb_keycodes \"papier\" {{ minimum = 8; maximum = 9; <K1> = 9; }};\nxkb_types \"papier\" {{ include \"complete\" }};\nxkb_compatibility \"papier\" {{ include \"complete\" }};\nxkb_symbols \"papier\" {{ key <K1> {{ [ %s ] }}; }};\n}};\n", sym)
	fd := memfd_create("gui_toolkit_keymap", 0)
	if fd < 0 { return false }
	defer posix.close(posix.FD(fd))
	data := transmute([]u8)keymap
	if posix.write(posix.FD(fd), raw_data(data), uint(len(data))) != len(data) { return false }
	zero := u8(0)   // (the size counts the terminating NUL, as the protocol's keymap is a C string)
	posix.write(posix.FD(fd), &zero, 1)

	kb := wl.proxy_marshal_flags(wlc.virtual_keyboards, VK_MANAGER_CREATE, &vk_iface, 1, 0, wlc.seat, nil)
	if kb == nil { return false }
	XKB_V1 :: 1
	wl.proxy_marshal_flags(kb, VK_KEYMAP, nil, 1, 0, u32(XKB_V1), i32(fd), u32(len(data) + 1))
	mods: u32
	if .Shift in hk.mods { mods |= 1 }
	if .Ctrl in hk.mods  { mods |= 4 }
	if .Alt in hk.mods   { mods |= 8 }
	if hk.super          { mods |= 64 }
	now := u32(time.to_unix_nanoseconds(time.now()) / 1e6)
	EVDEV_KEY :: 1   // (<K1> = 9: an xkb keycode is the evdev one plus 8)
	wl.proxy_marshal_flags(kb, VK_MODIFIERS, nil, 1, 0, mods, u32(0), u32(0), u32(0))
	wl.proxy_marshal_flags(kb, VK_KEY, nil, 1, 0, now, u32(EVDEV_KEY), u32(1))
	wl.proxy_marshal_flags(kb, VK_KEY, nil, 1, 0, now + 1, u32(EVDEV_KEY), u32(0))
	wl.proxy_marshal_flags(kb, VK_MODIFIERS, nil, 1, 0, u32(0), u32(0), u32(0), u32(0))
	wl.proxy_marshal_flags(kb, VK_DESTROY, nil, 1, WL_MARSHAL_FLAG_DESTROY)
	return wl.display_roundtrip(wlc.display) >= 0
}
