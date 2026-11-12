#+build linux
package capture

// X11, over XCB (libxcb by dlopen, on a connection of the session's own). The pictures are GetImage of the root window
// (Z pixmap, 32 bits a pixel: B, G, R, X on a little-endian server); no MIT-SHM yet, a whole 4K screen is one 33 MB reply.
// The outputs come from RandR 1.5's GetMonitors (libxcb-randr, optional: without it the root is the one output). The
// windows come from _NET_CLIENT_LIST_STACKING (bottom to top: read reversed), named by _NET_WM_NAME (else WM_NAME) and
// WM_CLASS; a window's rect is its frame: its position on the root (TranslateCoordinates) grown by _NET_FRAME_EXTENTS
// (the window manager's decorations) and shrunk by _GTK_FRAME_EXTENTS (a client-side shadow). A window's picture is the
// root cut to that rect: what covers the window shows in it. X11 has no logical pixels: scale 1 everywhere. A stream
// (the end of this file) reads its rectangle at its pace and gives what changed.

import "base:runtime"
import "core:strings"
import "core:sys/posix"
import "core:time"

@(private = "file") Xcb_Connection :: distinct rawptr
@(private = "file") Xcb_Cookie :: struct { sequence: u32 }

@(private = "file")
Xcb_Setup :: struct {
	status: u8, pad0: u8, protocol_major_version: u16, protocol_minor_version: u16, length: u16,
	release_number: u32, resource_id_base: u32, resource_id_mask: u32, motion_buffer_size: u32,
	vendor_len: u16, maximum_request_length: u16, roots_len: u8, pixmap_formats_len: u8,
	image_byte_order: u8, bitmap_format_bit_order: u8, bitmap_format_scanline_unit: u8,
	bitmap_format_scanline_pad: u8, min_keycode: u8, max_keycode: u8, pad1: [4]u8,
}

@(private = "file")
Xcb_Screen :: struct {
	root: u32, default_colormap: u32, white_pixel: u32, black_pixel: u32,
	current_input_masks: u32, width_in_pixels: u16, height_in_pixels: u16, width_in_millimeters: u16,
	height_in_millimeters: u16, min_installed_maps: u16, max_installed_maps: u16, root_visual: u32,
	backing_stores: u8, save_unders: u8, root_depth: u8, allowed_depths_len: u8,
}

@(private = "file") Xcb_Screen_Iterator :: struct { data: ^Xcb_Screen, rem: i32, index: i32 }
// xcb_query_extension_reply_t, of which only `present` is read.
@(private = "file") Xcb_Extension_Reply :: struct { response_type, pad0: u8, sequence: u16, length: u32, present, major_opcode, first_event, first_error: u8 }

@(private = "file") XCB_IMAGE_FORMAT_Z_PIXMAP :: 2
@(private = "file") XCB_ATOM_ATOM :: 4
@(private = "file") XCB_ATOM_CARDINAL :: 6
@(private = "file") XCB_ATOM_STRING :: 31
@(private = "file") XCB_ATOM_WINDOW :: 33
@(private = "file") XCB_ATOM_WM_NAME :: 39
@(private = "file") XCB_ATOM_WM_CLASS :: 67
@(private = "file") XCB_GET_PROPERTY_TYPE_ANY :: 0
@(private = "file") IMAGE_BYTE_ORDER_LSB_FIRST :: 0
@(private = "file") PROPERTY_MAX_WORDS :: 1 << 16   // a property read: 256 KB, more than any list of windows or title
@(private = "file") RANDR_MAJOR :: 1
@(private = "file") RANDR_MINOR :: 5                // GetMonitors
@(private = "file") ALL_DESKTOPS :: 0xFFFFFFFF      // _NET_WM_DESKTOP of a window shown on every desktop
// The replies' layouts (xproto.h, randr.h): where the read fields are.
@(private = "file") GEOMETRY_WIDTH_AT :: 16
@(private = "file") TRANSLATE_X_AT :: 12
@(private = "file") IMAGE_DEPTH_AT :: 1
@(private = "file") MONITORS_COUNT_AT :: 12
@(private = "file") MONITORS_FIRST_AT :: 32
@(private = "file") MONITOR_BYTES :: 24
@(private = "file") POINTER_SAME_SCREEN_AT :: 1   // xcb_query_pointer_reply_t
@(private = "file") POINTER_ROOT_X_AT :: 16

@(private = "file")
Xcb_Lib :: struct {
	handle, randr_handle: posix.Symbol_Table,
	connect:               proc "c" (display: cstring, screen: ^i32) -> Xcb_Connection,
	disconnect:            proc "c" (c: Xcb_Connection),
	connection_has_error:  proc "c" (c: Xcb_Connection) -> i32,
	get_setup:             proc "c" (c: Xcb_Connection) -> ^Xcb_Setup,
	setup_roots_iterator:  proc "c" (s: ^Xcb_Setup) -> Xcb_Screen_Iterator,
	screen_next:           proc "c" (it: ^Xcb_Screen_Iterator),
	get_extension_data:    proc "c" (c: Xcb_Connection, id: rawptr) -> ^Xcb_Extension_Reply,
	intern_atom:           proc "c" (c: Xcb_Connection, only_if_exists: u8, len: u16, name: cstring) -> Xcb_Cookie,
	intern_atom_reply:     proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	get_property:          proc "c" (c: Xcb_Connection, del: u8, wid: u32, prop, type: u32, offset, len: u32) -> Xcb_Cookie,
	get_property_reply:    proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	get_property_value:    proc "c" (reply: rawptr) -> rawptr,
	get_property_value_length: proc "c" (reply: rawptr) -> i32,
	get_geometry:          proc "c" (c: Xcb_Connection, drawable: u32) -> Xcb_Cookie,
	get_geometry_reply:    proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	translate_coordinates: proc "c" (c: Xcb_Connection, src, dst: u32, x, y: i16) -> Xcb_Cookie,
	translate_coordinates_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	get_image:             proc "c" (c: Xcb_Connection, format: u8, drawable: u32, x, y: i16, w, h: u16, plane_mask: u32) -> Xcb_Cookie,
	get_image_reply:       proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	get_image_data:        proc "c" (reply: rawptr) -> [^]u8,
	get_image_data_length: proc "c" (reply: rawptr) -> i32,
	get_atom_name:         proc "c" (c: Xcb_Connection, atom: u32) -> Xcb_Cookie,
	get_atom_name_reply:   proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	get_atom_name_name:    proc "c" (reply: rawptr) -> [^]u8,
	get_atom_name_name_length: proc "c" (reply: rawptr) -> i32,
	query_pointer:         proc "c" (c: Xcb_Connection, window: u32) -> Xcb_Cookie,
	query_pointer_reply:   proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	// libxcb-randr (optional)
	randr_id:              rawptr,
	randr_query_version:   proc "c" (c: Xcb_Connection, major, minor: u32) -> Xcb_Cookie,
	randr_query_version_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	randr_get_monitors:    proc "c" (c: Xcb_Connection, window: u32, get_active: u8) -> Xcb_Cookie,
	randr_get_monitors_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
}

@(private = "file")
X11_Atoms :: struct {
	client_list_stacking, wm_name_utf8, utf8_string, frame_extents, gtk_frame_extents: u32,
	wm_state, wm_state_hidden, wm_desktop, current_desktop: u32,
}

@(private)
X11_State :: struct {
	allocator: runtime.Allocator,
	lib:       Xcb_Lib,
	c:         Xcb_Connection,
	screen:    ^Xcb_Screen,
	lsb_first: bool,
	has_randr: bool,
	atoms:     X11_Atoms,
}

@(private)
x11_open :: proc(allocator: runtime.Allocator) -> (st: ^X11_State, ok: bool) {
	st = new(X11_State, allocator)
	st.allocator = allocator
	if !x11_lib_load(&st.lib) { x11_close(st); return nil, false }
	l := &st.lib
	screen_index: i32
	st.c = l.connect(nil, &screen_index)
	if st.c == nil || l.connection_has_error(st.c) != 0 { x11_close(st); return nil, false }
	setup := l.get_setup(st.c)
	it := l.setup_roots_iterator(setup)
	for _ in 0 ..< screen_index {
		if it.rem <= 1 { break }
		l.screen_next(&it)
	}
	st.screen = it.data
	if st.screen == nil { x11_close(st); return nil, false }
	st.lsb_first = setup.image_byte_order == IMAGE_BYTE_ORDER_LSB_FIRST
	a := &st.atoms
	a.client_list_stacking = x11_atom(st, "_NET_CLIENT_LIST_STACKING")
	a.wm_name_utf8 = x11_atom(st, "_NET_WM_NAME")
	a.utf8_string = x11_atom(st, "UTF8_STRING")
	a.frame_extents = x11_atom(st, "_NET_FRAME_EXTENTS")
	a.gtk_frame_extents = x11_atom(st, "_GTK_FRAME_EXTENTS")
	a.wm_state = x11_atom(st, "_NET_WM_STATE")
	a.wm_state_hidden = x11_atom(st, "_NET_WM_STATE_HIDDEN")
	a.wm_desktop = x11_atom(st, "_NET_WM_DESKTOP")
	a.current_desktop = x11_atom(st, "_NET_CURRENT_DESKTOP")
	st.has_randr = x11_randr_init(st)
	return st, true
}

@(private)
x11_close :: proc(st: ^X11_State) {
	if st == nil { return }
	if st.c != nil { st.lib.disconnect(st.c) }
	if st.lib.randr_handle != nil { posix.dlclose(st.lib.randr_handle) }
	if st.lib.handle != nil { posix.dlclose(st.lib.handle) }
	free(st, st.allocator)
}

@(private = "file")
x11_lib_load :: proc(l: ^Xcb_Lib) -> bool {
	h := posix.dlopen("libxcb.so.1", {.NOW})
	if h == nil { h = posix.dlopen("libxcb.so", {.NOW}) }
	if h == nil { return false }
	l.handle = h
	l.connect                 = auto_cast posix.dlsym(h, "xcb_connect")
	l.disconnect              = auto_cast posix.dlsym(h, "xcb_disconnect")
	l.connection_has_error    = auto_cast posix.dlsym(h, "xcb_connection_has_error")
	l.get_setup               = auto_cast posix.dlsym(h, "xcb_get_setup")
	l.setup_roots_iterator    = auto_cast posix.dlsym(h, "xcb_setup_roots_iterator")
	l.screen_next             = auto_cast posix.dlsym(h, "xcb_screen_next")
	l.get_extension_data      = auto_cast posix.dlsym(h, "xcb_get_extension_data")
	l.intern_atom             = auto_cast posix.dlsym(h, "xcb_intern_atom")
	l.intern_atom_reply       = auto_cast posix.dlsym(h, "xcb_intern_atom_reply")
	l.get_property            = auto_cast posix.dlsym(h, "xcb_get_property")
	l.get_property_reply      = auto_cast posix.dlsym(h, "xcb_get_property_reply")
	l.get_property_value      = auto_cast posix.dlsym(h, "xcb_get_property_value")
	l.get_property_value_length = auto_cast posix.dlsym(h, "xcb_get_property_value_length")
	l.get_geometry            = auto_cast posix.dlsym(h, "xcb_get_geometry")
	l.get_geometry_reply      = auto_cast posix.dlsym(h, "xcb_get_geometry_reply")
	l.translate_coordinates   = auto_cast posix.dlsym(h, "xcb_translate_coordinates")
	l.translate_coordinates_reply = auto_cast posix.dlsym(h, "xcb_translate_coordinates_reply")
	l.get_image               = auto_cast posix.dlsym(h, "xcb_get_image")
	l.get_image_reply         = auto_cast posix.dlsym(h, "xcb_get_image_reply")
	l.get_image_data          = auto_cast posix.dlsym(h, "xcb_get_image_data")
	l.get_image_data_length   = auto_cast posix.dlsym(h, "xcb_get_image_data_length")
	l.get_atom_name           = auto_cast posix.dlsym(h, "xcb_get_atom_name")
	l.get_atom_name_reply     = auto_cast posix.dlsym(h, "xcb_get_atom_name_reply")
	l.get_atom_name_name      = auto_cast posix.dlsym(h, "xcb_get_atom_name_name")
	l.get_atom_name_name_length = auto_cast posix.dlsym(h, "xcb_get_atom_name_name_length")
	l.query_pointer           = auto_cast posix.dlsym(h, "xcb_query_pointer")
	l.query_pointer_reply     = auto_cast posix.dlsym(h, "xcb_query_pointer_reply")
	return l.connect != nil && l.disconnect != nil && l.connection_has_error != nil && l.get_setup != nil &&
		l.setup_roots_iterator != nil && l.screen_next != nil && l.intern_atom != nil && l.intern_atom_reply != nil &&
		l.get_property != nil && l.get_property_reply != nil && l.get_property_value != nil && l.get_property_value_length != nil &&
		l.get_geometry != nil && l.get_geometry_reply != nil && l.translate_coordinates != nil && l.translate_coordinates_reply != nil &&
		l.get_image != nil && l.get_image_reply != nil && l.get_image_data != nil && l.get_image_data_length != nil
}

// RandR 1.5 bound and announced (the server answers GetMonitors only to a client that said it knows 1.5).
@(private = "file")
x11_randr_init :: proc(st: ^X11_State) -> bool {
	l := &st.lib
	h := posix.dlopen("libxcb-randr.so.0", {.NOW})
	if h == nil { h = posix.dlopen("libxcb-randr.so", {.NOW}) }
	if h == nil { return false }
	l.randr_handle = h
	l.randr_id                  = posix.dlsym(h, "xcb_randr_id")
	l.randr_query_version       = auto_cast posix.dlsym(h, "xcb_randr_query_version")
	l.randr_query_version_reply = auto_cast posix.dlsym(h, "xcb_randr_query_version_reply")
	l.randr_get_monitors        = auto_cast posix.dlsym(h, "xcb_randr_get_monitors")
	l.randr_get_monitors_reply  = auto_cast posix.dlsym(h, "xcb_randr_get_monitors_reply")
	if l.randr_id == nil || l.randr_query_version == nil || l.randr_query_version_reply == nil || l.randr_get_monitors == nil ||
		l.randr_get_monitors_reply == nil || l.get_extension_data == nil { return false }
	ext := l.get_extension_data(st.c, l.randr_id)
	if ext == nil || ext.present == 0 { return false }
	reply := l.randr_query_version_reply(st.c, l.randr_query_version(st.c, RANDR_MAJOR, RANDR_MINOR), nil)
	if reply == nil { return false }
	defer posix.free(reply)
	// xcb_randr_query_version_reply_t: major_version at 8, minor_version at 12
	b := ([^]u8)(reply)
	major, minor := get_u32_le(b[8:]), get_u32_le(b[12:])
	return major > RANDR_MAJOR || (major == RANDR_MAJOR && minor >= RANDR_MINOR)
}

// (the replies are in this machine's order: XCB swaps them)
@(private = "file")
get_u32_le :: proc(b: [^]u8) -> u32 { return (^u32)(b)^ }
@(private = "file")
get_i16 :: proc(b: [^]u8) -> i16 { return (^i16)(b)^ }
@(private = "file")
get_u16 :: proc(b: [^]u8) -> u16 { return (^u16)(b)^ }

@(private = "file")
x11_atom :: proc(st: ^X11_State, name: string) -> u32 {
	l := &st.lib
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	reply := l.intern_atom_reply(st.c, l.intern_atom(st.c, 0, u16(len(name)), cname), nil)
	if reply == nil { return 0 }
	defer posix.free(reply)
	return get_u32_le(([^]u8)(reply)[8:])   // xcb_intern_atom_reply_t: atom at 8
}

// A property's bytes (temporary allocator); nil when the window has none of that type.
@(private = "file")
x11_property :: proc(st: ^X11_State, window, prop, type: u32) -> []u8 {
	if prop == 0 { return nil }
	l := &st.lib
	reply := l.get_property_reply(st.c, l.get_property(st.c, 0, window, prop, type, 0, PROPERTY_MAX_WORDS), nil)
	if reply == nil { return nil }
	defer posix.free(reply)
	n := l.get_property_value_length(reply)
	if n <= 0 { return nil }
	out := make([]u8, int(n), context.temp_allocator)
	copy(out, ([^]u8)(l.get_property_value(reply))[:n])
	return out
}

@(private = "file")
x11_words :: proc(b: []u8) -> []u32 {
	if len(b) < 4 { return nil }
	return ([^]u32)(raw_data(b))[:len(b) / 4]
}

@(private)
x11_outputs :: proc(st: ^X11_State, s: ^Session) {
	monitors := x11_monitors(st)
	for m in monitors {
		append(&s.outputs, Output{id = u64(m.atom), name = x11_atom_name(st, m.atom, s.allocator), rect = m.rect, scale = 1})
	}
	if len(monitors) > 0 { return }
	root := Rect{0, 0, i32(st.screen.width_in_pixels), i32(st.screen.height_in_pixels)}
	append(&s.outputs, Output{id = 0, name = strings.clone("screen", s.allocator), rect = root, scale = 1})
}

// RandR's monitors (temporary memory): none without RandR 1.5, and then the root is the one output, id 0.
@(private = "file")
X11_Monitor :: struct { atom: u32, rect: Rect }   // the atom of its name is its output's id

@(private = "file")
x11_monitors :: proc(st: ^X11_State) -> []X11_Monitor {
	list := make([dynamic]X11_Monitor, context.temp_allocator)
	if !st.has_randr { return list[:] }
	l := &st.lib
	reply := l.randr_get_monitors_reply(st.c, l.randr_get_monitors(st.c, st.screen.root, 1), nil)
	if reply == nil { return list[:] }
	defer posix.free(reply)
	b := ([^]u8)(reply)
	count := int(get_u32_le(b[MONITORS_COUNT_AT:]))
	at := MONITORS_FIRST_AT
	// xcb_randr_monitor_info_t: name 0, primary 4, automatic 5, nOutput 6, x 8, y 10, width 12, height 14, the
	// outputs after its 24 bytes
	for _ in 0 ..< count {
		m := b[at:]
		n_outputs := int(get_u16(m[6:]))
		r := Rect{i32(get_i16(m[8:])), i32(get_i16(m[10:])), i32(get_u16(m[12:])), i32(get_u16(m[14:]))}
		append(&list, X11_Monitor{get_u32_le(m), r})
		at += MONITOR_BYTES + 4 * n_outputs
	}
	return list[:]
}

// QueryPointer on the root: the pointer on the root's screen, in its pixels (X11's are logical ones, scale 1).
@(private)
x11_pointer :: proc(st: ^X11_State) -> (at: [2]i32, output: u64, ok: bool) {
	l := &st.lib
	if l.query_pointer == nil || l.query_pointer_reply == nil { return }
	reply := l.query_pointer_reply(st.c, l.query_pointer(st.c, st.screen.root), nil)
	if reply == nil { return }
	b := ([^]u8)(reply)
	same_screen := b[POINTER_SAME_SCREEN_AT] != 0
	at = {i32(get_i16(b[POINTER_ROOT_X_AT:])), i32(get_i16(b[POINTER_ROOT_X_AT + 2:]))}
	posix.free(reply)
	if !same_screen { return {}, 0, false }
	monitors := x11_monitors(st)
	for m in monitors {
		r := m.rect
		if at.x >= r.x && at.x < r.x + r.w && at.y >= r.y && at.y < r.y + r.h { return at, u64(m.atom), true }
	}
	// (no RandR: the root is the one output x11_outputs gives, id 0; with it, a point on no monitor is on no output)
	if len(monitors) > 0 { return {}, 0, false }
	return at, 0, true
}

@(private = "file")
x11_atom_name :: proc(st: ^X11_State, atom: u32, allocator: runtime.Allocator) -> string {
	l := &st.lib
	if l.get_atom_name == nil || l.get_atom_name_reply == nil || l.get_atom_name_name == nil || l.get_atom_name_name_length == nil { return "" }
	reply := l.get_atom_name_reply(st.c, l.get_atom_name(st.c, atom), nil)
	if reply == nil { return "" }
	defer posix.free(reply)
	n := l.get_atom_name_name_length(reply)
	return strings.clone(string(l.get_atom_name_name(reply)[:n]), allocator)
}

// The windows, front to back.
@(private)
x11_windows :: proc(st: ^X11_State, s: ^Session) {
	a := &st.atoms
	root := st.screen.root
	list := x11_words(x11_property(st, root, a.client_list_stacking, XCB_ATOM_WINDOW))
	current := u32(ALL_DESKTOPS)
	if d := x11_words(x11_property(st, root, a.current_desktop, XCB_ATOM_CARDINAL)); len(d) > 0 { current = d[0] }
	#reverse for id in list {
		w := Window{id = u64(id)}
		title := x11_property(st, id, a.wm_name_utf8, a.utf8_string)
		if len(title) == 0 { title = x11_property(st, id, XCB_ATOM_WM_NAME, XCB_ATOM_STRING) }
		w.title = strings.clone(string(title), s.allocator)
		// WM_CLASS: the instance, a NUL, the class, a NUL
		class := string(x11_property(st, id, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING))
		if i := strings.index_byte(class, 0); i >= 0 { class = strings.trim_right(class[i + 1:], "\x00") }
		w.app_id = strings.clone(class, s.allocator)
		for state in x11_words(x11_property(st, id, a.wm_state, XCB_ATOM_ATOM)) {
			if state == a.wm_state_hidden && state != 0 { w.minimized = true }
		}
		desktop := u32(ALL_DESKTOPS)
		if d := x11_words(x11_property(st, id, a.wm_desktop, XCB_ATOM_CARDINAL)); len(d) > 0 { desktop = d[0] }
		on_screen := desktop == ALL_DESKTOPS || current == ALL_DESKTOPS || desktop == current
		if r, ok := x11_frame_rect(st, id); ok {
			w.rect = r
			// (a window on another desktop is unmapped: its rect is not where it shows)
			w.has_rect = on_screen
		}
		append(&s.windows, w)
	}
}

@(private)
x11_frame_rect :: proc(st: ^X11_State, id: u32) -> (r: Rect, ok: bool) {
	l := &st.lib
	geo := l.get_geometry_reply(st.c, l.get_geometry(st.c, id), nil)
	if geo == nil { return }
	gb := ([^]u8)(geo)
	w, h := i32(get_u16(gb[GEOMETRY_WIDTH_AT:])), i32(get_u16(gb[GEOMETRY_WIDTH_AT + 2:]))
	posix.free(geo)
	tr := l.translate_coordinates_reply(st.c, l.translate_coordinates(st.c, id, st.screen.root, 0, 0), nil)
	if tr == nil { return }
	tb := ([^]u8)(tr)
	x, y := i32(get_i16(tb[TRANSLATE_X_AT:])), i32(get_i16(tb[TRANSLATE_X_AT + 2:]))
	posix.free(tr)
	r = {x, y, w, h}
	// left, right, top, bottom
	if e := x11_words(x11_property(st, id, st.atoms.frame_extents, XCB_ATOM_CARDINAL)); len(e) >= 4 {
		r = {r.x - i32(e[0]), r.y - i32(e[2]), r.w + i32(e[0] + e[1]), r.h + i32(e[2] + e[3])}
	}
	if e := x11_words(x11_property(st, id, st.atoms.gtk_frame_extents, XCB_ATOM_CARDINAL)); len(e) >= 4 {
		r = {r.x + i32(e[0]), r.y + i32(e[2]), r.w - i32(e[0] + e[1]), r.h - i32(e[2] + e[3])}
	}
	return r, r.w > 0 && r.h > 0
}

// `r` of the root (clipped to it), as a frame at scale 1.
@(private)
x11_grab :: proc(st: ^X11_State, r: Rect, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	l := &st.lib
	x0, y0 := max(r.x, 0), max(r.y, 0)
	x1 := min(r.x + r.w, i32(st.screen.width_in_pixels))
	y1 := min(r.y + r.h, i32(st.screen.height_in_pixels))
	if x1 <= x0 || y1 <= y0 { return {}, .Failed }
	if st.screen.root_depth != 24 && st.screen.root_depth != 32 { return {}, .Unsupported }
	if !st.lsb_first { return {}, .Unsupported }   // (a big-endian server: X, R, G, B)
	w, h := x1 - x0, y1 - y0
	reply := l.get_image_reply(st.c, l.get_image(st.c, XCB_IMAGE_FORMAT_Z_PIXMAP, st.screen.root, i16(x0), i16(y0), u16(w), u16(h), ~u32(0)), nil)
	if reply == nil { return {}, .Failed }
	defer posix.free(reply)
	n := int(l.get_image_data_length(reply))
	if n < int(w) * int(h) * 4 { return {}, .Failed }
	data := l.get_image_data(reply)[:n]
	f = frame_from_buffer(data, w, h, w * 4, .BGRA, .Normal, false, true, allocator)
	f.origin = {x0, y0}
	return f, .None
}

@(private)
x11_desktop :: proc(st: ^X11_State, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	return x11_grab(st, {0, 0, i32(st.screen.width_in_pixels), i32(st.screen.height_in_pixels)}, allocator)
}

////////////////////////////////
// streams

// A stream on X11 reads its rectangle of the root at the stream's pace and gives a frame when the pixels differ from
// the last ones (no XDamage yet: a still screen costs a read and a comparison per interval). A region is read as it is,
// not cut from its output. A window is the root at its frame: its position followed, its size the one it had at the
// start. The pointer is never in the picture (GetImage leaves it out).
@(private)
X11_Stream :: struct {
	rect:   Rect,   // what is read of the root
	window: u32,
	follow: bool,   // a window: its position read again before each frame
}

@(private)
x11_stream_open :: proc(st: ^X11_State, s: ^Session, stream: ^Stream) -> Error {
	if st.screen.root_depth != 24 && st.screen.root_depth != 32 { return .Unsupported }
	if !st.lsb_first { return .Unsupported }
	xs := X11_Stream{}
	switch v in stream.source {
	case Stream_Output:
		found := false
		for o in outputs(s) {
			if o.id != v.id { continue }
			xs.rect, found = o.rect, true
		}
		if !found { return .Gone }
	case Stream_Region:
		xs.rect = v.rect
		stream.cropping = false   // (read as it is: nothing to cut)
	case Stream_Window:
		r, ok := x11_frame_rect(st, u32(v.id))
		if !ok { return .Gone }
		xs.rect, xs.window, xs.follow = r, u32(v.id), true
	case:
		return .Failed
	}
	xs.rect = x11_rect_on_root(st, xs.rect)
	if xs.rect.w <= 0 || xs.rect.h <= 0 { return .Failed }
	impl := new(X11_Stream, stream.allocator)
	impl^ = xs
	stream.impl = impl
	stream.cursor = false
	return .None
}

@(private)
x11_stream_close :: proc(stream: ^Stream) {
	if stream.impl != nil { free(stream.impl, stream.allocator) }
	stream.impl = nil
}

@(private)
x11_stream_next :: proc(st: ^X11_State, stream: ^Stream, timeout: time.Duration) -> (f: Stream_Frame, ok: bool, err: Error) {
	xs := (^X11_Stream)(stream.impl)
	deadline := monotonic_ns() + i64(timeout)
	for {
		now := monotonic_ns()
		due := stream_pacer_due(&stream.pacer)
		if now < due {
			if now >= deadline { return {}, false, .None }
			time.sleep(time.Duration(min(due, deadline) - now))
			continue
		}
		if xs.follow {
			r, found := x11_frame_rect(st, xs.window)
			if !found { return {}, false, .Gone }
			// (the size stays the first one: an encoder's frames all have one size)
			xs.rect = x11_rect_on_root(st, {r.x, r.y, xs.rect.w, xs.rect.h})
		}
		dst := frame_ring_take(&stream.ring, int(xs.rect.w) * int(xs.rect.h) * 4)
		if !x11_read_into(st, xs.rect, dst) { return {}, false, .Failed }
		previous := stream.ring.buffers[stream.ring.next][:]
		if stream.frames > 0 && len(previous) == len(dst) && x11_same(previous, dst) {
			// Nothing changed: the buffer is taken again next time (the frame given last stays as it is), and the next
			// read waits an interval.
			frame_ring_return(&stream.ring)
			stream_pacer_poll(&stream.pacer, now)
			continue
		}
		frame := Frame{pixels = dst, width = xs.rect.w, height = xs.rect.h, stride = xs.rect.w * 4, scale = 1, origin = {xs.rect.x, xs.rect.y}}
		f, ok = stream_frame_finish(stream, frame, now)
		return f, ok, .None
	}
}

// `r` moved (not shrunk, unless it is larger than the root) to lie inside the root: a stream's size does not change.
@(private = "file")
x11_rect_on_root :: proc(st: ^X11_State, r: Rect) -> Rect {
	rw, rh := i32(st.screen.width_in_pixels), i32(st.screen.height_in_pixels)
	out := Rect{r.x, r.y, min(r.w, rw), min(r.h, rh)}
	out.x = clamp(out.x, 0, rw - out.w)
	out.y = clamp(out.y, 0, rh - out.h)
	return out
}

// `r` of the root (inside it) read into `dst` (r.w * r.h * 4 bytes), upright, opaque.
@(private = "file")
x11_read_into :: proc(st: ^X11_State, r: Rect, dst: []u8) -> bool {
	l := &st.lib
	reply := l.get_image_reply(st.c, l.get_image(st.c, XCB_IMAGE_FORMAT_Z_PIXMAP, st.screen.root, i16(r.x), i16(r.y), u16(r.w), u16(r.h), ~u32(0)), nil)
	if reply == nil { return false }
	defer posix.free(reply)
	n := int(l.get_image_data_length(reply))
	if n < int(r.w) * int(r.h) * 4 || len(dst) < int(r.w) * int(r.h) * 4 { return false }
	frame_from_buffer_into(dst, l.get_image_data(reply)[:n], r.w, r.h, r.w * 4, .BGRA, .Normal, false, true)
	return true
}

@(private = "file")
x11_same :: proc(a, b: []u8) -> bool {
	return len(a) == len(b) && runtime.memory_compare(raw_data(a), raw_data(b), len(a)) == 0
}
