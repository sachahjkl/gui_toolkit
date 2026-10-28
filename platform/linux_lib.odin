#+build linux
package platform

// Run-time loading of the Linux windowing libraries, by dlopen so that a binary built with this toolkit starts on a
// system that is missing one of them and says which (never a hard link: a desktop without Wayland still has X11, a
// server login has neither). Each library is opened once, its symbols bound into a struct of function pointers, and
// `ok` tells whether it is usable. The window backend (window_wl_linux.odin / window_x11_linux.odin) is chosen at
// open_window from what loaded: Wayland when $WAYLAND_DISPLAY is set and libwayland-client is present, else X11 when
// libxcb is present.
//
// Only the C ABI of each library is bound here; the protocol marshalling (Wayland's wl_proxy_marshal_flags, XCB's
// request cookies) lives in the backend files. libxkbcommon turns the raw keycodes and the keymap into our Key enum
// and composed text on both backends; libdecor draws client-side window decorations on a Wayland compositor that does
// not decorate windows itself (GNOME), falling back to a plain undecorated surface when it too is missing.

import "core:sys/posix"
import "core:sync"

@(private) Lib :: posix.Symbol_Table

@(private)
lib_open :: proc(names: []cstring) -> Lib {
	for n in names {
		if h := posix.dlopen(n, posix.RTLD_LOCAL + {.NOW, .GLOBAL}); h != nil { return h }
	}
	return nil
}

@(private)
lib_sym :: proc(h: Lib, name: cstring) -> rawptr { return posix.dlsym(h, name) }

////////////////////////////////
// libwayland-client

@(private)
Wl_Interface :: struct {
	name:         cstring,
	version:      i32,
	method_count: i32,
	methods:      rawptr,   // const struct wl_message *
	event_count:  i32,
	events:       rawptr,
}

@(private)
Wl_Message :: struct {
	name:      cstring,
	signature: cstring,
	types:     [^]^Wl_Interface,
}

// A wl_proxy is opaque; wl_display is a proxy too. We only ever hold them as pointers.
@(private) Wl_Proxy :: distinct rawptr
@(private) Wl_Display :: distinct rawptr
@(private) Wl_Array :: struct { size: uint, alloc: uint, data: rawptr }
@(private) Wl_Fixed :: distinct i32

@(private) wl_fixed_to_f64 :: proc "contextless" (f: Wl_Fixed) -> f64 { return f64(i32(f)) / 256 }
@(private) wl_fixed_to_int :: proc "contextless" (f: Wl_Fixed) -> int { return int(i32(f) / 256) }

// wl_proxy_marshal_flags' flag: the request destroys the proxy.
@(private) WL_MARSHAL_FLAG_DESTROY :: 1 << 0

@(private)
Wayland_Lib :: struct {
	handle: Lib,
	ok:     bool,
	// display and event-queue plumbing
	display_connect:        proc "c" (name: cstring) -> Wl_Display,
	display_disconnect:     proc "c" (d: Wl_Display),
	display_get_fd:         proc "c" (d: Wl_Display) -> i32,
	display_dispatch:       proc "c" (d: Wl_Display) -> i32,
	display_dispatch_pending: proc "c" (d: Wl_Display) -> i32,
	display_prepare_read:   proc "c" (d: Wl_Display) -> i32,
	display_read_events:    proc "c" (d: Wl_Display) -> i32,
	display_cancel_read:    proc "c" (d: Wl_Display),
	display_flush:          proc "c" (d: Wl_Display) -> i32,
	display_roundtrip:      proc "c" (d: Wl_Display) -> i32,
	// proxy marshalling: this single entry point makes every request (wayland-client 1.20+)
	proxy_marshal_flags:    proc "c" (p: Wl_Proxy, opcode: u32, interface: ^Wl_Interface, version: u32, flags: u32, #c_vararg args: ..any) -> Wl_Proxy,
	proxy_add_listener:     proc "c" (p: Wl_Proxy, implementation: rawptr, data: rawptr) -> i32,
	proxy_destroy:          proc "c" (p: Wl_Proxy),
	proxy_get_version:      proc "c" (p: Wl_Proxy) -> u32,
	proxy_set_user_data:    proc "c" (p: Wl_Proxy, data: rawptr),
	proxy_get_user_data:    proc "c" (p: Wl_Proxy) -> rawptr,
	// the interface symbols we marshal against (globals exported by the library)
	registry_interface:     ^Wl_Interface,
	compositor_interface:   ^Wl_Interface,
	surface_interface:      ^Wl_Interface,
	seat_interface:         ^Wl_Interface,
	pointer_interface:      ^Wl_Interface,
	keyboard_interface:     ^Wl_Interface,
	touch_interface:        ^Wl_Interface,
	output_interface:       ^Wl_Interface,
	shm_interface:          ^Wl_Interface,
	shm_pool_interface:     ^Wl_Interface,
	buffer_interface:       ^Wl_Interface,
	data_device_manager_interface: ^Wl_Interface,
	data_device_interface:  ^Wl_Interface,
	data_source_interface:  ^Wl_Interface,
	data_offer_interface:   ^Wl_Interface,
	callback_interface:     ^Wl_Interface,
	region_interface:       ^Wl_Interface,
}

@(private) wl: Wayland_Lib
@(private) wl_once: sync.Once

@(private)
wayland_lib :: proc() -> ^Wayland_Lib {
	sync.once_do(&wl_once, proc() {
		h := lib_open({"libwayland-client.so.0", "libwayland-client.so"})
		if h == nil { return }
		wl.handle = h
		wl.display_connect        = auto_cast lib_sym(h, "wl_display_connect")
		wl.display_disconnect     = auto_cast lib_sym(h, "wl_display_disconnect")
		wl.display_get_fd         = auto_cast lib_sym(h, "wl_display_get_fd")
		wl.display_dispatch       = auto_cast lib_sym(h, "wl_display_dispatch")
		wl.display_dispatch_pending = auto_cast lib_sym(h, "wl_display_dispatch_pending")
		wl.display_prepare_read   = auto_cast lib_sym(h, "wl_display_prepare_read")
		wl.display_read_events    = auto_cast lib_sym(h, "wl_display_read_events")
		wl.display_cancel_read    = auto_cast lib_sym(h, "wl_display_cancel_read")
		wl.display_flush          = auto_cast lib_sym(h, "wl_display_flush")
		wl.display_roundtrip      = auto_cast lib_sym(h, "wl_display_roundtrip")
		wl.proxy_marshal_flags    = auto_cast lib_sym(h, "wl_proxy_marshal_flags")
		wl.proxy_add_listener     = auto_cast lib_sym(h, "wl_proxy_add_listener")
		wl.proxy_destroy          = auto_cast lib_sym(h, "wl_proxy_destroy")
		wl.proxy_get_version      = auto_cast lib_sym(h, "wl_proxy_get_version")
		wl.proxy_set_user_data    = auto_cast lib_sym(h, "wl_proxy_set_user_data")
		wl.proxy_get_user_data    = auto_cast lib_sym(h, "wl_proxy_get_user_data")
		wl.registry_interface            = auto_cast lib_sym(h, "wl_registry_interface")
		wl.compositor_interface          = auto_cast lib_sym(h, "wl_compositor_interface")
		wl.surface_interface             = auto_cast lib_sym(h, "wl_surface_interface")
		wl.seat_interface                = auto_cast lib_sym(h, "wl_seat_interface")
		wl.pointer_interface             = auto_cast lib_sym(h, "wl_pointer_interface")
		wl.keyboard_interface            = auto_cast lib_sym(h, "wl_keyboard_interface")
		wl.touch_interface               = auto_cast lib_sym(h, "wl_touch_interface")
		wl.output_interface              = auto_cast lib_sym(h, "wl_output_interface")
		wl.shm_interface                 = auto_cast lib_sym(h, "wl_shm_interface")
		wl.shm_pool_interface            = auto_cast lib_sym(h, "wl_shm_pool_interface")
		wl.buffer_interface              = auto_cast lib_sym(h, "wl_buffer_interface")
		wl.data_device_manager_interface = auto_cast lib_sym(h, "wl_data_device_manager_interface")
		wl.data_device_interface         = auto_cast lib_sym(h, "wl_data_device_interface")
		wl.data_source_interface         = auto_cast lib_sym(h, "wl_data_source_interface")
		wl.data_offer_interface          = auto_cast lib_sym(h, "wl_data_offer_interface")
		wl.callback_interface            = auto_cast lib_sym(h, "wl_callback_interface")
		wl.region_interface              = auto_cast lib_sym(h, "wl_region_interface")
		wl.ok = wl.display_connect != nil && wl.proxy_marshal_flags != nil && wl.proxy_add_listener != nil &&
			wl.registry_interface != nil && wl.compositor_interface != nil && wl.surface_interface != nil
	})
	return &wl
}

////////////////////////////////
// libxkbcommon: keycodes and the keymap to our Key enum and composed text (both backends)

@(private) Xkb_Context :: distinct rawptr
@(private) Xkb_Keymap :: distinct rawptr
@(private) Xkb_State :: distinct rawptr
@(private) Xkb_Keysym :: distinct u32

@(private) XKB_CONTEXT_NO_FLAGS :: 0
@(private) XKB_KEYMAP_COMPILE_NO_FLAGS :: 0
@(private) XKB_STATE_MODS_DEPRESSED :: 1 << 0
@(private) XKB_STATE_MODS_LATCHED :: 1 << 1
@(private) XKB_STATE_MODS_LOCKED :: 1 << 2
@(private) XKB_STATE_MODS_EFFECTIVE :: (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3)
@(private) XKB_KEY_DOWN :: 1

@(private)
Xkb_Lib :: struct {
	handle: Lib,
	ok:     bool,
	context_new:       proc "c" (flags: i32) -> Xkb_Context,
	context_unref:     proc "c" (ctx: Xkb_Context),
	keymap_new_from_string: proc "c" (ctx: Xkb_Context, s: cstring, format: i32, flags: i32) -> Xkb_Keymap,
	keymap_new_from_names: proc "c" (ctx: Xkb_Context, names: rawptr, flags: i32) -> Xkb_Keymap,
	keymap_unref:      proc "c" (m: Xkb_Keymap),
	state_new:         proc "c" (m: Xkb_Keymap) -> Xkb_State,
	state_unref:       proc "c" (s: Xkb_State),
	state_update_mask: proc "c" (s: Xkb_State, depressed, latched, locked, dg, lg, eg: u32) -> i32,
	state_key_get_one_sym: proc "c" (s: Xkb_State, key: u32) -> Xkb_Keysym,
	state_key_get_utf8: proc "c" (s: Xkb_State, key: u32, buf: [^]u8, size: uint) -> i32,
	state_mod_name_is_active: proc "c" (s: Xkb_State, name: cstring, type: u32) -> i32,
	keysym_to_utf32:   proc "c" (sym: Xkb_Keysym) -> u32,
	// the x11 helper (separate .so): make a keymap from the server, so XKB drives X11 too
	x11_handle:        Lib,
	x11_setup_xkb_extension: proc "c" (conn: rawptr, maj, min: u16, flags: i32, maj_out, min_out, base_ev, base_err: ^i32) -> i32,
	x11_get_core_keyboard_device_id: proc "c" (conn: rawptr) -> i32,
	x11_keymap_new_from_device: proc "c" (ctx: Xkb_Context, conn: rawptr, device_id: i32, flags: i32) -> Xkb_Keymap,
	x11_state_new_from_device: proc "c" (m: Xkb_Keymap, conn: rawptr, device_id: i32) -> Xkb_State,
}

@(private) xkb: Xkb_Lib
@(private) xkb_once: sync.Once

@(private)
xkb_lib :: proc() -> ^Xkb_Lib {
	sync.once_do(&xkb_once, proc() {
		h := lib_open({"libxkbcommon.so.0", "libxkbcommon.so"})
		if h == nil { return }
		xkb.handle = h
		xkb.context_new        = auto_cast lib_sym(h, "xkb_context_new")
		xkb.context_unref      = auto_cast lib_sym(h, "xkb_context_unref")
		xkb.keymap_new_from_string = auto_cast lib_sym(h, "xkb_keymap_new_from_string")
		xkb.keymap_new_from_names = auto_cast lib_sym(h, "xkb_keymap_new_from_names")
		xkb.keymap_unref       = auto_cast lib_sym(h, "xkb_keymap_unref")
		xkb.state_new          = auto_cast lib_sym(h, "xkb_state_new")
		xkb.state_unref        = auto_cast lib_sym(h, "xkb_state_unref")
		xkb.state_update_mask  = auto_cast lib_sym(h, "xkb_state_update_mask")
		xkb.state_key_get_one_sym = auto_cast lib_sym(h, "xkb_state_key_get_one_sym")
		xkb.state_key_get_utf8 = auto_cast lib_sym(h, "xkb_state_key_get_utf8")
		xkb.state_mod_name_is_active = auto_cast lib_sym(h, "xkb_state_mod_name_is_active")
		xkb.keysym_to_utf32    = auto_cast lib_sym(h, "xkb_keysym_to_utf32")
		xkb.ok = xkb.context_new != nil && xkb.keymap_new_from_string != nil && xkb.state_new != nil &&
			xkb.state_key_get_one_sym != nil
		// the x11 companion is optional (X11 falls back to a built-in keymap when absent)
		if xh := lib_open({"libxkbcommon-x11.so.0", "libxkbcommon-x11.so"}); xh != nil {
			xkb.x11_handle = xh
			xkb.x11_setup_xkb_extension = auto_cast lib_sym(xh, "xkb_x11_setup_xkb_extension")
			xkb.x11_get_core_keyboard_device_id = auto_cast lib_sym(xh, "xkb_x11_get_core_keyboard_device_id")
			xkb.x11_keymap_new_from_device = auto_cast lib_sym(xh, "xkb_x11_keymap_new_from_device")
			xkb.x11_state_new_from_device = auto_cast lib_sym(xh, "xkb_x11_state_new_from_device")
		}
	})
	return &xkb
}

////////////////////////////////
// libxcb and the few XCB extension libraries (X11 backend)

@(private) Xcb_Connection :: distinct rawptr
@(private) Xcb_Window :: distinct u32
@(private) Xcb_Atom :: distinct u32
@(private) Xcb_Colormap :: distinct u32
@(private) Xcb_Void_Cookie :: struct { sequence: u32 }
@(private) Xcb_Intern_Atom_Cookie :: struct { sequence: u32 }
@(private) Xcb_Generic_Event :: struct { response_type: u8, pad0: u8, sequence: u16, pad: [7]u32, full_sequence: u32 }
@(private) Xcb_Generic_Error :: struct { response_type: u8, error_code: u8, sequence: u16, resource_id: u32, minor_code: u16, major_code: u8, pad0: u8, pad: [5]u32, full_sequence: u32 }

@(private)
Xcb_Setup :: struct {
	status: u8, pad0: u8, protocol_major_version: u16, protocol_minor_version: u16, length: u16,
	release_number: u32, resource_id_base: u32, resource_id_mask: u32, motion_buffer_size: u32,
	vendor_len: u16, maximum_request_length: u16, roots_len: u8, pixmap_formats_len: u8,
	image_byte_order: u8, bitmap_format_bit_order: u8, bitmap_format_scanline_unit: u8,
	bitmap_format_scanline_pad: u8, min_keycode: u8, max_keycode: u8, pad1: [4]u8,
}

@(private)
Xcb_Screen :: struct {
	root: Xcb_Window, default_colormap: Xcb_Colormap, white_pixel: u32, black_pixel: u32,
	current_input_masks: u32, width_in_pixels: u16, height_in_pixels: u16, width_in_millimeters: u16,
	height_in_millimeters: u16, min_installed_maps: u16, max_installed_maps: u16, root_visual: u32,
	backing_stores: u8, save_unders: u8, root_depth: u8, allowed_depths_len: u8,
}

@(private)
Xcb_Screen_Iterator :: struct { data: ^Xcb_Screen, rem: i32, index: i32 }

@(private)
Xcb_Lib :: struct {
	handle: Lib,
	ok:     bool,
	connect:            proc "c" (display: cstring, screen: ^i32) -> Xcb_Connection,
	disconnect:         proc "c" (c: Xcb_Connection),
	connection_has_error: proc "c" (c: Xcb_Connection) -> i32,
	get_file_descriptor: proc "c" (c: Xcb_Connection) -> i32,
	get_setup:          proc "c" (c: Xcb_Connection) -> ^Xcb_Setup,
	setup_roots_iterator: proc "c" (s: ^Xcb_Setup) -> Xcb_Screen_Iterator,
	generate_id:        proc "c" (c: Xcb_Connection) -> u32,
	flush:              proc "c" (c: Xcb_Connection) -> i32,
	poll_for_event:     proc "c" (c: Xcb_Connection) -> ^Xcb_Generic_Event,
	wait_for_event:     proc "c" (c: Xcb_Connection) -> ^Xcb_Generic_Event,
	create_window:      proc "c" (c: Xcb_Connection, depth: u8, wid: Xcb_Window, parent: Xcb_Window, x, y: i16, w, h, border: u16, class: u16, visual: u32, value_mask: u32, value_list: rawptr) -> Xcb_Void_Cookie,
	destroy_window:     proc "c" (c: Xcb_Connection, wid: Xcb_Window) -> Xcb_Void_Cookie,
	map_window:         proc "c" (c: Xcb_Connection, wid: Xcb_Window) -> Xcb_Void_Cookie,
	unmap_window:       proc "c" (c: Xcb_Connection, wid: Xcb_Window) -> Xcb_Void_Cookie,
	configure_window:   proc "c" (c: Xcb_Connection, wid: Xcb_Window, mask: u16, values: rawptr) -> Xcb_Void_Cookie,
	change_property:    proc "c" (c: Xcb_Connection, mode: u8, wid: Xcb_Window, prop: Xcb_Atom, type: Xcb_Atom, format: u8, len: u32, data: rawptr) -> Xcb_Void_Cookie,
	delete_property:    proc "c" (c: Xcb_Connection, wid: Xcb_Window, prop: Xcb_Atom) -> Xcb_Void_Cookie,
	intern_atom:        proc "c" (c: Xcb_Connection, only_if_exists: u8, len: u16, name: cstring) -> Xcb_Intern_Atom_Cookie,
	intern_atom_reply:  proc "c" (c: Xcb_Connection, cookie: Xcb_Intern_Atom_Cookie, e: ^^Xcb_Generic_Error) -> rawptr,
	get_property:       proc "c" (c: Xcb_Connection, del: u8, wid: Xcb_Window, prop, type: Xcb_Atom, offset, len: u32) -> Xcb_Intern_Atom_Cookie,
	get_property_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Intern_Atom_Cookie, e: ^^Xcb_Generic_Error) -> rawptr,
	get_property_value: proc "c" (reply: rawptr) -> rawptr,
	get_property_value_length: proc "c" (reply: rawptr) -> i32,
	send_event:         proc "c" (c: Xcb_Connection, propagate: u8, dest: Xcb_Window, mask: u32, ev: rawptr) -> Xcb_Void_Cookie,
	set_input_focus:    proc "c" (c: Xcb_Connection, revert: u8, focus: Xcb_Window, time: u32) -> Xcb_Void_Cookie,
	create_colormap:    proc "c" (c: Xcb_Connection, alloc: u8, mid: Xcb_Colormap, window: Xcb_Window, visual: u32) -> Xcb_Void_Cookie,
	// extension helpers (own .so files, optional)
	ewmh_handle:        Lib,
	keysyms_handle:     Lib,
}

@(private) xcb: Xcb_Lib
@(private) xcb_once: sync.Once

@(private)
xcb_lib :: proc() -> ^Xcb_Lib {
	sync.once_do(&xcb_once, proc() {
		h := lib_open({"libxcb.so.1", "libxcb.so"})
		if h == nil { return }
		xcb.handle = h
		xcb.connect            = auto_cast lib_sym(h, "xcb_connect")
		xcb.disconnect         = auto_cast lib_sym(h, "xcb_disconnect")
		xcb.connection_has_error = auto_cast lib_sym(h, "xcb_connection_has_error")
		xcb.get_file_descriptor = auto_cast lib_sym(h, "xcb_get_file_descriptor")
		xcb.get_setup          = auto_cast lib_sym(h, "xcb_get_setup")
		xcb.setup_roots_iterator = auto_cast lib_sym(h, "xcb_setup_roots_iterator")
		xcb.generate_id        = auto_cast lib_sym(h, "xcb_generate_id")
		xcb.flush              = auto_cast lib_sym(h, "xcb_flush")
		xcb.poll_for_event     = auto_cast lib_sym(h, "xcb_poll_for_event")
		xcb.wait_for_event     = auto_cast lib_sym(h, "xcb_wait_for_event")
		xcb.create_window      = auto_cast lib_sym(h, "xcb_create_window")
		xcb.destroy_window     = auto_cast lib_sym(h, "xcb_destroy_window")
		xcb.map_window         = auto_cast lib_sym(h, "xcb_map_window")
		xcb.unmap_window       = auto_cast lib_sym(h, "xcb_unmap_window")
		xcb.configure_window   = auto_cast lib_sym(h, "xcb_configure_window")
		xcb.change_property    = auto_cast lib_sym(h, "xcb_change_property")
		xcb.delete_property    = auto_cast lib_sym(h, "xcb_delete_property")
		xcb.intern_atom        = auto_cast lib_sym(h, "xcb_intern_atom")
		xcb.intern_atom_reply  = auto_cast lib_sym(h, "xcb_intern_atom_reply")
		xcb.get_property       = auto_cast lib_sym(h, "xcb_get_property")
		xcb.get_property_reply = auto_cast lib_sym(h, "xcb_get_property_reply")
		xcb.get_property_value = auto_cast lib_sym(h, "xcb_get_property_value")
		xcb.get_property_value_length = auto_cast lib_sym(h, "xcb_get_property_value_length")
		xcb.send_event         = auto_cast lib_sym(h, "xcb_send_event")
		xcb.set_input_focus    = auto_cast lib_sym(h, "xcb_set_input_focus")
		xcb.create_colormap    = auto_cast lib_sym(h, "xcb_create_colormap")
		xcb.ok = xcb.connect != nil && xcb.create_window != nil && xcb.map_window != nil &&
			xcb.poll_for_event != nil && xcb.get_setup != nil && xcb.intern_atom != nil
	})
	return &xcb
}

// Which backend open_window will drive, decided from the environment and from what loaded. Wayland is preferred when a
// Wayland compositor is reachable; X11 otherwise. `missing` names the library a backend needs when neither is usable.
@(private) Backend_Kind :: enum u8 { None, Wayland, X11 }

@(private)
choose_backend :: proc() -> (kind: Backend_Kind, missing: string) {
	wayland_display := posix.getenv("WAYLAND_DISPLAY")
	has_wayland := wayland_display != nil && string(wayland_display) != ""
	if has_wayland {
		if wayland_lib().ok { return .Wayland, "" }
		// a Wayland session but no libwayland-client: fall through to X11 if a server is reachable
	}
	display := posix.getenv("DISPLAY")
	if display != nil && string(display) != "" {
		if xcb_lib().ok { return .X11, "" }
		return .None, "libxcb"
	}
	if has_wayland { return .None, "libwayland-client" }
	return .None, "a display server (neither WAYLAND_DISPLAY nor DISPLAY is set)"
}
