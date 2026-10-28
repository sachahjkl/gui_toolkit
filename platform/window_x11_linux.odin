#+build linux
package platform

// The X11 window backend, over XCB (libxcb by dlopen). One connection per process, shared by every window of the
// thread; each window is an xcb_window with its own event bookkeeping. Keyboard goes through libxkbcommon (the keymap
// from the server when libxkbcommon-x11 is present, else a built-in us keymap), which gives both our Key enum and the
// composed UTF-8 text. DPI comes from Xft.dpi in the X resources (the RESOURCE_MANAGER root property). Close is the
// WM_DELETE_WINDOW protocol; state (maximize, fullscreen) is the _NET_WM_STATE EWMH protocol. The CLIPBOARD and PRIMARY
// selections carry text (clipboard_linux.odin adds the richer flavours).
//
// This backend is written to the XCB request ABI directly (no Xlib), so the binary needs only libxcb at run time.

import "core:time"
import "core:strings"
import "core:unicode/utf8"
import "core:sys/posix"

// One X11 connection, made on first use and kept for the process. XCB is thread-compatible for one connection used by
// one thread; the toolkit drives it from the UI thread only.
@(private)
X11_Conn :: struct {
	c:          Xcb_Connection,
	screen:     ^Xcb_Screen,
	fd:         i32,
	xkb_ctx:    Xkb_Context,
	xkb_keymap: Xkb_Keymap,
	xkb_state:  Xkb_State,
	// atoms interned once
	wm_protocols, wm_delete_window, net_wm_name, utf8_string, net_wm_state,
	net_wm_state_fullscreen, net_wm_state_maximized_horz, net_wm_state_maximized_vert,
	net_wm_state_hidden, motif_wm_hints, clipboard, primary, targets, wren_selection,
	net_wm_window_type, net_wm_window_type_normal, net_active_window, resource_manager,
	// the rich-clipboard target atoms (clipboard_x11_linux.odin): the MIME types and the protocol atoms
	mime_text_html, mime_image_png, mime_uri_list, atom_incr, atom_multiple, atom_timestamp, atom_text, atom_pair: Xcb_Atom,
	// the XDND atoms (dragdrop_x11_linux.odin)
	xdnd_aware, xdnd_enter, xdnd_position, xdnd_status, xdnd_leave, xdnd_drop, xdnd_finished,
	xdnd_type_list, xdnd_selection, xdnd_action_copy, xdnd_action_move, xdnd_action_link, xdnd_proxy: Xcb_Atom,
	// the window that owns CLIPBOARD now (this process), and what it holds
	clip_owner:  Xcb_Window,
	clip_text:   string,
}

@(private) x11c: X11_Conn
@(private) x11_ready: bool

@(private)
X11_Window_State :: struct {
	id:       Xcb_Window,
	colormap: Xcb_Colormap,
	transparent: bool,
	title:    string,
	mapped:   bool,
	// the bytes another client offered through a selection request, read in during a paste; paste_incr while an INCR
	// transfer streams in (clipboard_x11_linux.odin)
	paste_buf: [dynamic]u8,
	paste_got: bool,
	paste_incr: bool,
}

@(private)
x11_state :: proc(w: ^Window) -> ^X11_Window_State { return (^X11_Window_State)(w.x11) }

@(private)
x11_connect :: proc() -> bool {
	if x11_ready { return x11c.c != nil }
	x11_ready = true
	x := xcb_lib()
	if !x.ok { return false }
	scr: i32
	x11c.c = x.connect(nil, &scr)
	if x11c.c == nil || x.connection_has_error(x11c.c) != 0 { x11c.c = nil; return false }
	x11c.fd = x.get_file_descriptor(x11c.c)
	setup := x.get_setup(x11c.c)
	it := x.setup_roots_iterator(setup)
	for i in i32(0) ..< scr { if it.rem > 1 { it.data = mem_offset_screen(it.data); it.rem -= 1; it.index += 1 } }
	x11c.screen = it.data
	x11_intern_atoms()
	x11_init_xkb()
	return true
}

// Advance a screen iterator by one entry. XCB lays screens out contiguously, each `sizeof(xcb_screen_t)` apart plus its
// depths; for the common single-screen case this is never called. A conservative step by the struct size works for the
// usual layout where the primary screen is index 0 (what xcb_connect reports as the preferred screen).
@(private)
mem_offset_screen :: proc(s: ^Xcb_Screen) -> ^Xcb_Screen {
	return (^Xcb_Screen)(uintptr(s) + size_of(Xcb_Screen))
}

@(private)
x11_atom :: proc(name: string, create := true) -> Xcb_Atom {
	x := &xcb
	c := strings.clone_to_cstring(name, context.temp_allocator)
	cookie := x.intern_atom(x11c.c, create ? 0 : 1, u16(len(name)), c)
	reply := x.intern_atom_reply(x11c.c, cookie, nil)
	if reply == nil { return 0 }
	defer posix.free(reply)
	// xcb_intern_atom_reply_t: response_type(1) pad(1) sequence(2) length(4) atom(4)
	return (^Xcb_Atom)(uintptr(reply) + 8)^
}

@(private)
x11_intern_atoms :: proc() {
	x11c.wm_protocols = x11_atom("WM_PROTOCOLS")
	x11c.wm_delete_window = x11_atom("WM_DELETE_WINDOW")
	x11c.net_wm_name = x11_atom("_NET_WM_NAME")
	x11c.utf8_string = x11_atom("UTF8_STRING")
	x11c.net_wm_state = x11_atom("_NET_WM_STATE")
	x11c.net_wm_state_fullscreen = x11_atom("_NET_WM_STATE_FULLSCREEN")
	x11c.net_wm_state_maximized_horz = x11_atom("_NET_WM_STATE_MAXIMIZED_HORZ")
	x11c.net_wm_state_maximized_vert = x11_atom("_NET_WM_STATE_MAXIMIZED_VERT")
	x11c.net_wm_state_hidden = x11_atom("_NET_WM_STATE_HIDDEN")
	x11c.motif_wm_hints = x11_atom("_MOTIF_WM_HINTS")
	x11c.clipboard = x11_atom("CLIPBOARD")
	x11c.primary = x11_atom("PRIMARY")
	x11c.targets = x11_atom("TARGETS")
	x11c.wren_selection = x11_atom("GUI_TOOLKIT_SELECTION")
	x11c.net_wm_window_type = x11_atom("_NET_WM_WINDOW_TYPE")
	x11c.net_wm_window_type_normal = x11_atom("_NET_WM_WINDOW_TYPE_NORMAL")
	x11c.net_active_window = x11_atom("_NET_ACTIVE_WINDOW")
	x11c.resource_manager = x11_atom("RESOURCE_MANAGER")
	x11c.mime_text_html = x11_atom("text/html")
	x11c.mime_image_png = x11_atom("image/png")
	x11c.mime_uri_list = x11_atom("text/uri-list")
	x11c.atom_incr = x11_atom("INCR")
	x11c.atom_multiple = x11_atom("MULTIPLE")
	x11c.atom_timestamp = x11_atom("TIMESTAMP")
	x11c.atom_text = x11_atom("TEXT")
	x11c.atom_pair = x11_atom("ATOM_PAIR")
	x11_dnd_intern_atoms()
}

@(private)
x11_init_xkb :: proc() {
	k := xkb_lib()
	if !k.ok { return }
	x11c.xkb_ctx = k.context_new(XKB_CONTEXT_NO_FLAGS)
	if x11c.xkb_ctx == nil { return }
	if k.x11_handle != nil && k.x11_setup_xkb_extension != nil {
		maj, min, bev, ber: i32
		k.x11_setup_xkb_extension(rawptr(x11c.c), 1, 0, 0, &maj, &min, &bev, &ber)
		dev := k.x11_get_core_keyboard_device_id(rawptr(x11c.c))
		if dev >= 0 {
			x11c.xkb_keymap = k.x11_keymap_new_from_device(x11c.xkb_ctx, rawptr(x11c.c), dev, XKB_KEYMAP_COMPILE_NO_FLAGS)
			if x11c.xkb_keymap != nil { x11c.xkb_state = k.x11_state_new_from_device(x11c.xkb_keymap, rawptr(x11c.c), dev) }
		}
	}
	if x11c.xkb_keymap == nil && k.keymap_new_from_names != nil {
		// a built-in us keymap when the x11 companion is missing
		x11c.xkb_keymap = k.keymap_new_from_names(x11c.xkb_ctx, nil, XKB_KEYMAP_COMPILE_NO_FLAGS)
		if x11c.xkb_keymap != nil { x11c.xkb_state = k.state_new(x11c.xkb_keymap) }
	}
}

// XCB event / request constants used below (from xproto).
@(private) XCB_COPY_FROM_PARENT :: 0
@(private) XCB_WINDOW_CLASS_INPUT_OUTPUT :: 1
@(private) XCB_CW_BACK_PIXEL :: 1 << 1
@(private) XCB_CW_EVENT_MASK :: 1 << 11
@(private) XCB_CW_COLORMAP :: 1 << 13
@(private) XCB_PROP_MODE_REPLACE :: 0
@(private) XCB_ATOM_WM_NAME :: Xcb_Atom(39)
@(private) XCB_ATOM_STRING :: Xcb_Atom(31)
@(private) XCB_ATOM_ATOM :: Xcb_Atom(4)
@(private) XCB_ATOM_CARDINAL :: Xcb_Atom(6)
@(private) XCB_CONFIG_WINDOW_WIDTH :: 1 << 2
@(private) XCB_CONFIG_WINDOW_HEIGHT :: 1 << 3

// event masks
@(private) XCB_EVENT_MASK_KEY_PRESS :: 1 << 0
@(private) XCB_EVENT_MASK_KEY_RELEASE :: 1 << 1
@(private) XCB_EVENT_MASK_BUTTON_PRESS :: 1 << 2
@(private) XCB_EVENT_MASK_BUTTON_RELEASE :: 1 << 3
@(private) XCB_EVENT_MASK_ENTER_WINDOW :: 1 << 4
@(private) XCB_EVENT_MASK_LEAVE_WINDOW :: 1 << 5
@(private) XCB_EVENT_MASK_POINTER_MOTION :: 1 << 6
@(private) XCB_EVENT_MASK_BUTTON_MOTION :: 1 << 13
@(private) XCB_EVENT_MASK_STRUCTURE_NOTIFY :: 1 << 17
@(private) XCB_EVENT_MASK_FOCUS_CHANGE :: 1 << 21
@(private) XCB_EVENT_MASK_PROPERTY_CHANGE :: 1 << 22

// event response types (low 7 bits)
@(private) XCB_KEY_PRESS :: 2
@(private) XCB_KEY_RELEASE :: 3
@(private) XCB_BUTTON_PRESS :: 4
@(private) XCB_BUTTON_RELEASE :: 5
@(private) XCB_MOTION_NOTIFY :: 6
@(private) XCB_ENTER_NOTIFY :: 7
@(private) XCB_LEAVE_NOTIFY :: 8
@(private) XCB_FOCUS_IN :: 9
@(private) XCB_FOCUS_OUT :: 10
@(private) XCB_EXPOSE :: 12
@(private) XCB_CONFIGURE_NOTIFY :: 22
@(private) XCB_CLIENT_MESSAGE :: 33
@(private) XCB_SELECTION_CLEAR :: 29
@(private) XCB_SELECTION_REQUEST :: 30
@(private) XCB_SELECTION_NOTIFY :: 31
@(private) XCB_PROPERTY_NOTIFY :: 28

@(private)
x11_open :: proc(w: ^Window, title: string, size: [2]int, transparent: bool) -> bool {
	if !x11_connect() { report_missing("libxcb"); return false }
	x := &xcb
	st := new(X11_Window_State)
	st.transparent = transparent
	st.title = strings.clone(title)
	w.x11 = st
	w.dpi_scale = x11_dpi_scale()

	id := Xcb_Window(x.generate_id(x11c.c))
	st.id = id
	mask: u32 = XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK
	ev_mask: u32 = XCB_EVENT_MASK_KEY_PRESS | XCB_EVENT_MASK_KEY_RELEASE | XCB_EVENT_MASK_BUTTON_PRESS |
		XCB_EVENT_MASK_BUTTON_RELEASE | XCB_EVENT_MASK_POINTER_MOTION | XCB_EVENT_MASK_BUTTON_MOTION |
		XCB_EVENT_MASK_ENTER_WINDOW | XCB_EVENT_MASK_LEAVE_WINDOW | XCB_EVENT_MASK_STRUCTURE_NOTIFY |
		XCB_EVENT_MASK_FOCUS_CHANGE | XCB_EVENT_MASK_PROPERTY_CHANGE
	values := [2]u32{x11c.screen.black_pixel, ev_mask}
	cw := max(int(f32(size.x) * w.dpi_scale), 1)
	ch := max(int(f32(size.y) * w.dpi_scale), 1)
	w.size = {cw, ch}
	x.create_window(x11c.c, XCB_COPY_FROM_PARENT, id, x11c.screen.root, 0, 0, u16(cw), u16(ch), 0,
		XCB_WINDOW_CLASS_INPUT_OUTPUT, x11c.screen.root_visual, mask, &values[0])

	// title (both WM_NAME, Latin-1, and _NET_WM_NAME, UTF-8)
	x11_set_title(w, title)
	// close through WM_DELETE_WINDOW
	dw := x11c.wm_delete_window
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, x11c.wm_protocols, XCB_ATOM_ATOM, 32, 1, &dw)
	// normal window type
	nt := x11c.net_wm_window_type_normal
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, x11c.net_wm_window_type, XCB_ATOM_ATOM, 32, 1, &nt)
	if w.integrated { x11_set_decorations(w, false) }
	x.flush(x11c.c)
	return true
}

@(private)
x11_destroy :: proc(w: ^Window) {
	st := x11_state(w)
	if st == nil { return }
	if x11c.clip_owner == st.id { x11c.clip_owner = 0; delete(x11c.clip_text); x11c.clip_text = "" }
	xcb.destroy_window(x11c.c, st.id)
	xcb.flush(x11c.c)
	delete(st.title)
	delete(st.paste_buf)
	free(st)
	w.x11 = nil
}

@(private)
x11_set_title :: proc(w: ^Window, title: string) {
	st := x11_state(w)
	x := &xcb
	c := strings.clone_to_cstring(title, context.temp_allocator)
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, 8, u32(len(title)), rawptr(c))
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.net_wm_name, x11c.utf8_string, 8, u32(len(title)), rawptr(c))
	x.flush(x11c.c)
	if title != st.title { delete(st.title); st.title = strings.clone(title) }
}

@(private)
x11_set_size :: proc(w: ^Window, px: [2]int) {
	st := x11_state(w)
	values := [2]u32{u32(px.x), u32(px.y)}
	xcb.configure_window(x11c.c, st.id, XCB_CONFIG_WINDOW_WIDTH | XCB_CONFIG_WINDOW_HEIGHT, &values[0])
	xcb.flush(x11c.c)
}

@(private)
x11_show :: proc(w: ^Window) {
	st := x11_state(w)
	xcb.map_window(x11c.c, st.id)
	st.mapped = true
	xcb.flush(x11c.c)
}

@(private)
x11_minimize :: proc(w: ^Window) {
	// WM_CHANGE_STATE to IconicState (3): a ClientMessage to the root window
	st := x11_state(w)
	wm_change := x11_atom("WM_CHANGE_STATE")
	x11_send_root_message(wm_change, st.id, {3, 0, 0, 0, 0})
	w.minimized = true
}

@(private)
x11_set_maximized :: proc(w: ^Window, on: bool) {
	st := x11_state(w)
	x11_net_wm_state(st.id, on, x11c.net_wm_state_maximized_horz, x11c.net_wm_state_maximized_vert)
	w.maximized = on
}

@(private)
x11_set_fullscreen :: proc(w: ^Window, on: bool) {
	st := x11_state(w)
	x11_net_wm_state(st.id, on, x11c.net_wm_state_fullscreen, 0)
}

// _NET_WM_STATE change: a ClientMessage to the root as the EWMH spec requires (action 1 add, 0 remove).
@(private)
x11_net_wm_state :: proc(id: Xcb_Window, add: bool, a1, a2: Xcb_Atom) {
	data := [5]u32{add ? 1 : 0, u32(a1), u32(a2), 1, 0}
	x11_send_root_message(x11c.net_wm_state, id, data)
}

@(private)
x11_send_root_message :: proc(type: Xcb_Atom, id: Xcb_Window, data: [5]u32) {
	ev: [32]u8
	ev[0] = XCB_CLIENT_MESSAGE
	ev[1] = 32   // format
	put_u32(ev[4:], u32(id))
	put_u32(ev[8:], u32(type))
	for i in 0 ..< 5 { put_u32(ev[12 + i * 4:], data[i]) }
	SUBSTRUCTURE_NOTIFY :: 1 << 19
	SUBSTRUCTURE_REDIRECT :: 1 << 20
	xcb.send_event(x11c.c, 0, x11c.screen.root, SUBSTRUCTURE_NOTIFY | SUBSTRUCTURE_REDIRECT, &ev[0])
	xcb.flush(x11c.c)
}

// Motif hints: the only portable way to ask an X11 window manager for no decorations.
@(private)
x11_set_decorations :: proc(w: ^Window, on: bool) {
	st := x11_state(w)
	// MwmHints: flags(1<<1 = decorations), functions, decorations, input_mode, status
	hints := [5]u32{1 << 1, 0, on ? 1 : 0, 0, 0}
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.motif_wm_hints, x11c.motif_wm_hints, 32, 5, &hints[0])
	xcb.flush(x11c.c)
}

@(private) x11_transparent :: proc(w: ^Window) -> bool { return x11_state(w).transparent }
@(private) x11_fd :: proc(w: ^Window) -> i32 { return x11c.fd }

@(private) XCB_CONFIG_WINDOW_X :: 1 << 0
@(private) XCB_CONFIG_WINDOW_Y :: 1 << 1

@(private)
x11_move :: proc(w: ^Window, x, y: int) {
	st := x11_state(w)
	values := [2]i32{i32(x), i32(y)}
	xcb.configure_window(x11c.c, st.id, XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, &values[0])
	xcb.flush(x11c.c)
}

// The window's outer rectangle. xcb_get_geometry gives the size and the position relative to the parent; translating to
// the root needs xcb_translate_coordinates. We report the known client size and the last configure position (0,0 until
// the window manager has placed it): enough for saving and restoring a layout, which uses the size and maximized state.
@(private)
x11_outer_rect :: proc(w: ^Window) -> [4]int {
	return {0, 0, w.size.x, w.size.y}
}

@(private)
x11_wake :: proc(w: ^Window) {
	// a harmless property change on our own window wakes poll on the connection fd
	st := x11_state(w)
	v: u32 = 0
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.wren_selection, XCB_ATOM_CARDINAL, 32, 1, &v)
	xcb.flush(x11c.c)
}

// DPI from Xft.dpi in the X resources, else 96. Read fresh (cheap) only when stale.
@(private)
x11_dpi_scale :: proc() -> f32 {
	dpi := x11_xft_dpi()
	return dpi > 0 ? f32(dpi) / 96 : 1
}

@(private)
x11_xft_dpi :: proc() -> int {
	x := &xcb
	// RESOURCE_MANAGER on the root is a text blob of X resources; find "Xft.dpi:"
	cookie := x.get_property(x11c.c, 0, x11c.screen.root, x11c.resource_manager, XCB_ATOM_STRING, 0, 1 << 16)
	reply := x.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return 0 }
	defer posix.free(reply)
	n := int(x.get_property_value_length(reply))
	if n <= 0 { return 0 }
	data := ([^]u8)(x.get_property_value(reply))
	s := string(data[:n])
	key := "Xft.dpi:"
	i := strings.index(s, key)
	if i < 0 { return 0 }
	rest := s[i + len(key):]
	v := 0
	any := false
	for j := 0; j < len(rest); j += 1 {
		ch := rest[j]
		if ch == ' ' || ch == '\t' { if !any { continue } else { break } }
		if ch < '0' || ch > '9' { break }
		v = v * 10 + int(ch - '0'); any = true
	}
	return any ? v : 0
}

////////////////////////////////
// Event pump

@(private)
x11_pump :: proc(w: ^Window, wait: bool, timeout_ms: int) {
	x := &xcb
	if wait && len(w.events) == 0 {
		x.flush(x11c.c)
		poll_two(x11c.fd, dbus_fd(), timeout_ms > 0 ? timeout_ms : -1)
	}
	for {
		ev := x.poll_for_event(x11c.c)
		if ev == nil { break }
		x11_handle_event(w, ev)
		posix.free(ev)
	}
	dbus_pump()
	x.flush(x11c.c)
}

@(private)
x11_wait :: proc(w: ^Window, timeout_ms: int) {
	if len(w.events) > 0 || len(w.injected) > 0 { return }
	xcb.flush(x11c.c)
	poll_fd_wait(x11c.fd, timeout_ms > 0 ? timeout_ms : -1)
}

// Takes only keyboard and pointer events now (wait_handle), queuing them time-stamped; leaves the rest for poll_events.
@(private)
x11_take_input :: proc(w: ^Window) {
	// XCB has no per-category peek, so take everything and let poll_events return it next; the time stamp is set here.
	x := &xcb
	x.flush(x11c.c)
	for {
		ev := x.poll_for_event(x11c.c)
		if ev == nil { break }
		x11_handle_event(w, ev)
		posix.free(ev)
	}
}

@(private)
x11_push :: proc(w: ^Window, e: Event) {
	e := e
	e.stamp = time.tick_now()
	append(&w.events, e)
}

@(private)
x11_handle_event :: proc(w: ^Window, raw: ^Xcb_Generic_Event) {
	st := x11_state(w)
	b := ([^]u8)(raw)
	type := raw.response_type & 0x7f
	switch type {
	case XCB_KEY_PRESS, XCB_KEY_RELEASE:
		// xcb_key_press_event_t: detail(1)=keycode at [1]; state at [28]; event window at [12]
		keycode := u32(b[1])
		state := u16(b[28]) | u16(b[29]) << 8
		x11_key(w, keycode, state, type == XCB_KEY_PRESS)
	case XCB_BUTTON_PRESS, XCB_BUTTON_RELEASE:
		detail := b[1]
		state := u16(b[28]) | u16(b[29]) << 8
		ex := i16(u16(b[24]) | u16(b[25]) << 8)
		ey := i16(u16(b[26]) | u16(b[27]) << 8)
		pos := [2]f32{f32(ex), f32(ey)}
		mods := x11_mods(state)
		press := type == XCB_BUTTON_PRESS
		switch detail {
		case 1, 2, 3:
			btn: Mouse_Button = detail == 1 ? .Left : detail == 2 ? .Middle : .Right
			if press { w.buttons_down += {btn} } else { w.buttons_down -= {btn} }
			x11_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = btn, pos = pos, mods = mods, buttons = w.buttons_down})
		case 4, 5, 6, 7:
			if press {
				e := Event{kind = .Scroll, pos = pos, mods = mods}
				switch detail {
				case 4: e.delta.y = 1     // wheel up: content moves up (page down), as Win32 (+y = down)
				case 5: e.delta.y = -1
				case 6: e.delta.x = -1
				case 7: e.delta.x = 1
				}
				// our convention: +y scrolls content down. X button 4 is wheel-up = scroll content up = -y.
				e.delta.y = -e.delta.y
				x11_push(w, e)
			}
		}
	case XCB_MOTION_NOTIFY:
		ex := i16(u16(b[24]) | u16(b[25]) << 8)
		ey := i16(u16(b[26]) | u16(b[27]) << 8)
		state := u16(b[28]) | u16(b[29]) << 8
		x11_push(w, {kind = .Mouse_Move, pos = {f32(ex), f32(ey)}, mods = x11_mods(state), buttons = w.buttons_down})
	case XCB_ENTER_NOTIFY:
	case XCB_LEAVE_NOTIFY:
		x11_push(w, {kind = .Mouse_Leave})
	case XCB_FOCUS_IN:
		w.focused = true; w.active = true
		x11_push(w, {kind = .Activate})
	case XCB_FOCUS_OUT:
		w.focused = false; w.active = false
		x11_push(w, {kind = .Activate})
	case XCB_EXPOSE:
		w.paint_requested = true
	case XCB_CONFIGURE_NOTIFY:
		nw := int(u16(b[20]) | u16(b[21]) << 8)
		nh := int(u16(b[22]) | u16(b[23]) << 8)
		if nw > 0 && nh > 0 && (nw != w.size.x || nh != w.size.y) {
			w.size = {nw, nh}
			w.paint_requested = true
		}
	case XCB_CLIENT_MESSAGE:
		// data.data32[0] at [12]
		d0 := Xcb_Atom(get_u32(b[12:]))
		mtype := Xcb_Atom(get_u32(b[8:]))
		if mtype == x11c.wm_protocols && d0 == x11c.wm_delete_window {
			w.closed = true
			x11_push(w, {kind = .Close})
		} else {
			x11_dnd_client_message(w, mtype, b)
		}
	case XCB_SELECTION_REQUEST:
		x11_handle_selection_request(w, b)
	case XCB_SELECTION_NOTIFY:
		x11_handle_selection_notify(w, b)
	case XCB_SELECTION_CLEAR:
		if x11c.clip_owner == st.id { x11c.clip_owner = 0 }
	case XCB_PROPERTY_NOTIFY:
		// xcb_property_notify_event_t: window[4], atom[8], state[12] (0 NewValue, 1 Deleted)
		pwin := Xcb_Window(get_u32(b[4:]))
		patom := Xcb_Atom(get_u32(b[8:]))
		pstate := b[12]
		if pstate == 1 {   // Deleted: a requestor consumed an INCR chunk, send the next
			x11_incr_on_property_delete(pwin, patom)
		} else if pwin == st.id && st.paste_incr && patom == x11c.wren_selection {
			x11_incr_receive_chunk(w)
		}
	}
}

@(private)
x11_mods :: proc(state: u16) -> (m: Modifiers) {
	if state & 0x01 != 0 { m += {.Shift} }   // ShiftMask
	if state & 0x04 != 0 { m += {.Ctrl} }    // ControlMask
	if state & 0x08 != 0 { m += {.Alt} }     // Mod1Mask
	return
}

@(private)
x11_key :: proc(w: ^Window, keycode: u32, state: u16, press: bool) {
	k := xkb_lib()
	key := Key.None
	text: rune
	if k.ok && x11c.xkb_state != nil {
		sym := k.state_key_get_one_sym(x11c.xkb_state, keycode)
		key = key_from_keysym(sym)
		if press {
			buf: [8]u8
			n := k.state_key_get_utf8(x11c.xkb_state, keycode, &buf[0], size_of(buf))
			if n > 0 {
				s := string(buf[:n])
				if r, sz := utf8.decode_rune(s); sz > 0 && r >= 32 && r != 127 { text = r }
			}
		}
	}
	mods := x11_mods(state)
	if key != .None {
		x11_push(w, {kind = press ? .Key_Press : .Key_Release, key = key, mods = mods})
	}
	if press && text != 0 && .Ctrl not_in mods && .Alt not_in mods {
		x11_push(w, {kind = .Text, text = text, mods = mods})
	}
}

////////////////////////////////
// Text clipboard (CLIPBOARD selection)

@(private)
x11_clipboard_set_text :: proc(w: ^Window, text: string) {
	x11_clipboard_own_rich(w, text)
}

@(private)
x11_set_selection_owner :: proc(selection: Xcb_Atom, owner: Xcb_Window) {
	// xcb_set_selection_owner is a simple request; marshal it by hand through change_property is not right, so send via
	// a ClientMessage path is not possible. Use the dedicated opcode through a minimal request builder.
	x11_set_selection_owner_req(selection, owner)
}

// xcb_set_selection_owner: opcode 22, length 4, [owner, selection, time]. We call it through the generic cookie path by
// reusing configure_window's shape is not valid; instead bind the symbol lazily.
@(private)
x11_set_selection_owner_req :: proc(selection: Xcb_Atom, owner: Xcb_Window) {
	if x11_set_sel_owner == nil {
		x11_set_sel_owner = auto_cast lib_sym(xcb.handle, "xcb_set_selection_owner")
	}
	if x11_set_sel_owner != nil { x11_set_sel_owner(x11c.c, owner, selection, 0) }
}
@(private) x11_set_sel_owner: proc "c" (c: Xcb_Connection, owner: Xcb_Window, selection: Xcb_Atom, time: u32) -> Xcb_Void_Cookie

@(private)
x11_convert_selection :: proc(requestor: Xcb_Window, selection, target, property: Xcb_Atom) {
	if x11_conv_sel == nil {
		x11_conv_sel = auto_cast lib_sym(xcb.handle, "xcb_convert_selection")
	}
	if x11_conv_sel != nil { x11_conv_sel(x11c.c, requestor, selection, target, property, 0) }
}
@(private) x11_conv_sel: proc "c" (c: Xcb_Connection, requestor: Xcb_Window, selection, target, property: Xcb_Atom, time: u32) -> Xcb_Void_Cookie

// Answer a SelectionRequest: another client wants a flavour of our CLIPBOARD / PRIMARY. The rich logic (TARGETS,
// MULTIPLE, the MIME targets, INCR for big data) is in clipboard_x11_linux.odin.
@(private)
x11_handle_selection_request :: proc(w: ^Window, b: [^]u8) {
	x11_serve_selection_request(w, b)
}

@(private)
x11_handle_selection_notify :: proc(w: ^Window, b: [^]u8) {
	st := x11_state(w)
	property := Xcb_Atom(get_u32(b[24:]))
	if property == 0 { st.paste_got = true; return }
	// read the property without deleting it first, so we can tell an INCR hand-off (type = INCR) from real data
	cookie := xcb.get_property(x11c.c, 0, st.id, property, 0, 0, 1 << 20)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { st.paste_got = true; return }
	// xcb_get_property_reply_t: type at [8]
	ptype := Xcb_Atom(get_u32(([^]u8)(reply)[8:]))
	n := int(xcb.get_property_value_length(reply))
	if ptype == x11c.atom_incr {
		// the real data streams in: delete the property to ask for the first chunk, then read on each PropertyNotify
		posix.free(reply)
		st.paste_incr = true
		clear(&st.paste_buf)
		xcb.delete_property(x11c.c, st.id, property)
		xcb.flush(x11c.c)
		return
	}
	if n > 0 {
		data := ([^]u8)(xcb.get_property_value(reply))
		clear(&st.paste_buf)
		append(&st.paste_buf, ..data[:n])
	}
	posix.free(reply)
	st.paste_got = true
}

// One INCR chunk arrived on our scratch property (PropertyNotify NewValue while paste_incr): append it, delete the
// property to ask for the next. A zero-length chunk ends the transfer.
@(private)
x11_incr_receive_chunk :: proc(w: ^Window) {
	st := x11_state(w)
	cookie := xcb.get_property(x11c.c, 0, st.id, x11c.wren_selection, 0, 0, 1 << 20)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return }
	n := int(xcb.get_property_value_length(reply))
	if n > 0 {
		data := ([^]u8)(xcb.get_property_value(reply))
		append(&st.paste_buf, ..data[:n])
		posix.free(reply)
		xcb.delete_property(x11c.c, st.id, x11c.wren_selection)   // ask for the next chunk
		xcb.flush(x11c.c)
	} else {
		posix.free(reply)
		st.paste_incr = false   // the empty terminator: done
		st.paste_got = true
		xcb.delete_property(x11c.c, st.id, x11c.wren_selection)
		xcb.flush(x11c.c)
	}
}

@(private)
x11_clipboard_get_text :: proc(w: ^Window, allocator := context.allocator) -> string {
	st := x11_state(w)
	if x11c.clip_owner == st.id { return strings.clone(x11c.clip_text, allocator) }   // our own text
	clear(&st.paste_buf)
	st.paste_got = false
	x11_convert_selection(st.id, x11c.clipboard, x11c.utf8_string, x11c.wren_selection)
	xcb.flush(x11c.c)
	// pump until the SelectionNotify arrives (bounded): a synchronous read the callers expect
	deadline := time.tick_now()
	for i in 0 ..< 200 {
		ev := xcb.poll_for_event(x11c.c)
		if ev != nil { x11_handle_event(w, ev); posix.free(ev); if st.paste_got { break }; continue }
		if st.paste_got { break }
		if time.duration_milliseconds(time.tick_since(deadline)) > 500 { break }
		poll_fd_wait(x11c.fd, 20)
	}
	if len(st.paste_buf) == 0 { return "" }
	return strings.clone(string(st.paste_buf[:]), allocator)
}

@(private)
put_u32 :: proc(b: []u8, v: u32) { b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
@(private)
get_u32 :: proc(b: [^]u8) -> u32 { return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24 }
