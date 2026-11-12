#+build linux
package platform

// The X11 window backend, over XCB (libxcb by dlopen). One connection per thread that opens windows, shared by its
// windows; each window is an xcb_window with its own event bookkeeping. Keyboard goes through libxkbcommon (the keymap
// from the server when libxkbcommon-x11 is present, else a built-in us keymap), which gives both our Key enum and the
// composed UTF-8 text. DPI comes from Xft.dpi in the X resources (the RESOURCE_MANAGER root property). Close is the
// WM_DELETE_WINDOW protocol; state (maximize, fullscreen) is the _NET_WM_STATE EWMH protocol. The CLIPBOARD and PRIMARY
// selections carry text (clipboard_linux.odin adds the richer flavours).
//
// This backend is written to the XCB request ABI directly (no Xlib), so the binary needs only libxcb at run time.

import "base:runtime"
import "core:time"
import "core:strings"
import "core:unicode/utf8"
import "core:sys/posix"

// One X11 connection per thread that opens windows, made on its first window and kept. XCB is thread-compatible for one
// connection used by one thread.
@(private)
X11_Conn :: struct {
	c:          Xcb_Connection,
	screen:     ^Xcb_Screen,
	fd:         i32,
	xkb_ctx:    Xkb_Context,
	xkb_keymap: Xkb_Keymap,
	xkb_state:  Xkb_State,
	xkb_event:  u8,          // the XKB extension's first event, 0 without it
	// atoms interned once
	wm_protocols, wm_delete_window, net_wm_name, utf8_string, net_wm_state,
	net_wm_state_fullscreen, net_wm_state_maximized_horz, net_wm_state_maximized_vert,
	net_wm_state_hidden, net_wm_moveresize, motif_wm_hints, clipboard, primary, targets, wren_selection, request_selection,
	net_wm_window_type, net_wm_window_type_normal, net_active_window, resource_manager, net_frame_extents,
	// the rich-clipboard target atoms (clipboard_x11_linux.odin): the MIME types and the protocol atoms
	mime_text_html, mime_image_png, mime_uri_list, mime_gnome_files, mime_kde_cut, atom_incr, atom_multiple, atom_timestamp, atom_text, atom_pair: Xcb_Atom,
	// the XDND atoms (dragdrop_x11_linux.odin)
	xdnd_aware, xdnd_enter, xdnd_position, xdnd_status, xdnd_leave, xdnd_drop, xdnd_finished,
	xdnd_type_list, xdnd_selection, xdnd_action_copy, xdnd_action_move, xdnd_action_link, xdnd_proxy, xdnd_action_list: Xcb_Atom,
	// the window that owns CLIPBOARD now (this process), and what it holds
	clip_owner:  Xcb_Window,
	clip_text:   string,
	windows:     [dynamic]^Window,   // this process's windows: an event goes to the one it names
	xfixes_event, randr_event: u8,   // the extension's first event (x11_ext_linux.odin), 0 without it
	incr_sends:  [dynamic]X11_Incr_Send,   // INCR transfers we are sending (clipboard_x11_linux.odin)
	foreign_formats: X11_Foreign_Formats,      // what another client's CLIPBOARD offers, as last read
	dnd_target:  X11_Dnd_Target,           // drag and drop (dragdrop_x11_linux.odin)
	dnd_source:  X11_Dnd_Source,
	link:        Display_Link,
}

// This thread's connection: each thread that opens windows has its own (its events, its windows, its selections), as its
// windows' calls run on it.
@(private, thread_local) x11c: X11_Conn

@(private)
X11_Window_State :: struct {
	id:       Xcb_Window,
	colormap: Xcb_Colormap,
	transparent: bool,
	title:    string,
	map_phase: X11_Map_Phase,
	withdrawn: bool,                  // hide_window took it off the screen (show_window maps it again)
	first_state: [dynamic]Xcb_Atom,   // what _NET_WM_STATE asks for before the first map
	// the reads of a selection (clipboard_x11_linux.odin): the waiting one of x11_selection_read, and clipboard_request's
	paste:     X11_Selection_Read,
	request:   X11_Selection_Read,
}

// A read of a selection: what was asked, how far it is, the bytes that came. `property` is where the owner puts them: each
// read has its own, so that one never takes the other's answer.
@(private)
X11_Selection_Read :: struct {
	phase:     X11_Paste_Phase,
	selection, target, property: Xcb_Atom,
	buf:       [dynamic]u8,
}

// Where a window is with the server. Unmapped: an iconified window, under a window manager that does not say
// _NET_WM_STATE_HIDDEN. (Before the first map a state is a property the window manager reads, after it a request to it.)
@(private) X11_Map_Phase :: enum u8 { Never, Asked, Mapped, Unmapped }

// A read of a selection: asked, the owner streaming it in (INCR), answered. Idle: nothing is asked, what comes is late.
@(private) X11_Paste_Phase :: enum u8 { Idle, Waiting, Receiving, Done }

@(private)
x11_state :: proc(w: ^Window) -> ^X11_Window_State { return (^X11_Window_State)(w.x11) }

@(private)
x11_connect :: proc() -> bool {
	if x11c.link != .Untried { return x11c.link == .Connected }
	x11c.link = .Failed
	x := xcb_lib()
	if !x.ok { return false }
	scr: i32
	x11c.windows.allocator = runtime.heap_allocator()   // (outlives whatever allocator the first window was made under)
	x11c.c = x.connect(nil, &scr)
	if x11c.c == nil || x.connection_has_error(x11c.c) != 0 { x11c.c = nil; return false }
	x11c.link = .Connected
	x11c.fd = x.get_file_descriptor(x11c.c)
	setup := x.get_setup(x11c.c)
	it := x.setup_roots_iterator(setup)
	for _ in i32(0) ..< scr { if it.rem > 1 { it.data = mem_offset_screen(it.data); it.rem -= 1; it.index += 1 } }
	x11c.screen = it.data
	x11_intern_atoms()
	x11_extensions_init()
	x11_init_xkb()
	x11_change_window_attrs_event_mask(x11c.screen.root, XCB_EVENT_MASK_PROPERTY_CHANGE)   // (Xft.dpi: RESOURCE_MANAGER)
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
	x11c.net_wm_moveresize = x11_atom("_NET_WM_MOVERESIZE")
	x11c.motif_wm_hints = x11_atom("_MOTIF_WM_HINTS")
	x11c.clipboard = x11_atom("CLIPBOARD")
	x11c.primary = x11_atom("PRIMARY")
	x11c.targets = x11_atom("TARGETS")
	x11c.wren_selection = x11_atom("GUI_TOOLKIT_SELECTION")
	x11c.request_selection = x11_atom("GUI_TOOLKIT_REQUEST")
	x11c.net_wm_window_type = x11_atom("_NET_WM_WINDOW_TYPE")
	x11c.net_wm_window_type_normal = x11_atom("_NET_WM_WINDOW_TYPE_NORMAL")
	x11c.net_active_window = x11_atom("_NET_ACTIVE_WINDOW")
	x11c.resource_manager = x11_atom("RESOURCE_MANAGER")
	x11c.net_frame_extents = x11_atom("_NET_FRAME_EXTENTS")
	x11c.mime_text_html = x11_atom("text/html")
	x11c.mime_image_png = x11_atom("image/png")
	x11c.mime_uri_list = x11_atom("text/uri-list")
	x11c.mime_gnome_files = x11_atom(CLIPBOARD_GNOME_FILES_MIME)
	x11c.mime_kde_cut = x11_atom(CLIPBOARD_KDE_CUT_MIME)
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
		if k.x11_setup_xkb_extension(rawptr(x11c.c), 1, 0, 0, &maj, &min, &bev, &ber) != 0 {
			x11c.xkb_event = u8(bev)
			if k.x11_select_events != nil {
				k.x11_select_events(x11c.c, XCB_XKB_ID_USE_CORE_KBD, X11_XKB_WATCHED, 0, X11_XKB_WATCHED, X11_XKB_MAP_ALL, X11_XKB_MAP_ALL, nil)
			}
			if k.x11_per_client_flags != nil && k.x11_per_client_flags_reply != nil {
				// a held key repeats as presses alone: without this the server sends a release before each
				cookie := k.x11_per_client_flags(x11c.c, XCB_XKB_ID_USE_CORE_KBD, X11_XKB_DETECTABLE_AUTO_REPEAT, X11_XKB_DETECTABLE_AUTO_REPEAT, 0, 0, 0)
				if reply := k.x11_per_client_flags_reply(x11c.c, cookie, nil); reply != nil { posix.free(reply) }
			}
		}
		x11_xkb_load()
	}
	if x11c.xkb_keymap == nil && k.keymap_new_from_names != nil {
		// a built-in us keymap when the x11 companion is missing
		x11c.xkb_keymap = k.keymap_new_from_names(x11c.xkb_ctx, nil, XKB_KEYMAP_COMPILE_NO_FLAGS)
		if x11c.xkb_keymap != nil { x11c.xkb_state = k.state_new(x11c.xkb_keymap) }
	}
}

// The server's keymap, in place of the one held; that one stays when the server's cannot be had.
@(private)
x11_xkb_load :: proc() {
	k := xkb_lib()
	if k.x11_handle == nil || k.x11_keymap_new_from_device == nil { return }
	dev := k.x11_get_core_keyboard_device_id(rawptr(x11c.c))
	if dev < 0 { return }
	keymap := k.x11_keymap_new_from_device(x11c.xkb_ctx, rawptr(x11c.c), dev, XKB_KEYMAP_COMPILE_NO_FLAGS)
	if keymap == nil { return }
	state := k.x11_state_new_from_device(keymap, rawptr(x11c.c), dev)
	if state == nil { k.keymap_unref(keymap); return }
	if x11c.xkb_state != nil { k.state_unref(x11c.xkb_state) }
	if x11c.xkb_keymap != nil { k.keymap_unref(x11c.xkb_keymap) }
	x11c.xkb_keymap, x11c.xkb_state = keymap, state
}

@(private = "file") XCB_XKB_ID_USE_CORE_KBD :: 0x100
@(private = "file") X11_XKB_WATCHED :: 1 << 0 | 1 << 1    // XKB events: NewKeyboardNotify, MapNotify
@(private = "file") X11_XKB_MAP_ALL :: 0xff               // every part of a map
@(private = "file") X11_XKB_DETECTABLE_AUTO_REPEAT :: 1   // of the client's flags
@(private = "file") X11_XKB_NEW_KEYBOARD_NOTIFY :: 0      // xkbType, in the second byte of an XKB event
@(private = "file") X11_XKB_MAP_NOTIFY :: 1
@(private = "file") X11_MAPPING_POINTER :: 2              // MappingNotify's request: modifiers, keyboard, pointer
@(private = "file") X11_STATE_MODS_MASK :: 0xff           // the state of a key event: its modifiers
@(private = "file") X11_STATE_GROUP_SHIFT :: 13           // and its group
@(private = "file") X11_STATE_GROUP_MASK :: 3
@(private = "file") XCB_MAPPING_NOTIFY :: 34

// XCB event / request constants used below (from xproto).
@(private) XCB_COPY_FROM_PARENT :: 0
@(private) XCB_WINDOW_CLASS_INPUT_OUTPUT :: 1
@(private) XCB_CW_BACK_PIXEL :: 1 << 1
@(private) XCB_CW_EVENT_MASK :: 1 << 11
@(private) XCB_CW_COLORMAP :: 1 << 13
@(private) XCB_PROP_MODE_REPLACE :: 0
@(private) XCB_ATOM_WM_NAME :: Xcb_Atom(39)
@(private) XCB_ATOM_STRING :: Xcb_Atom(31)
@(private) XCB_ATOM_WM_CLASS :: Xcb_Atom(67)
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
@(private = "file") X11_NOTIFY_GRAB :: 1   // the mode of a focus event
@(private = "file") X11_NOTIFY_UNGRAB :: 2
@(private = "file") XCB_DESTROY_NOTIFY :: 17
@(private = "file") XCB_UNMAP_NOTIFY :: 18
@(private = "file") XCB_MAP_NOTIFY :: 19
@(private) X11_FORMAT_8 :: 8               // a property's or a client message's format: bits per item
@(private) X11_FORMAT_32 :: 32
@(private) X11_EVENT_BYTES :: 32
@(private) X11_CLIENT_MESSAGE_WORDS :: 5   // data32 of a client message
@(private) X11_RESPONSE_TYPE_MASK :: 0x7f  // without the bit that marks a sent event
@(private = "file") X11_BUTTON_WHEEL_UP :: 4
@(private = "file") X11_BUTTON_BACK :: 8
@(private = "file") X11_BUTTON_FORWARD :: 9
@(private = "file") X11_BUTTON_WHEEL_DOWN :: 5
@(private = "file") X11_BUTTON_WHEEL_LEFT :: 6
@(private = "file") X11_BUTTON_WHEEL_RIGHT :: 7
@(private = "file") MWM_HINTS_WORDS :: 5
@(private = "file") X11_RESOURCES_MAX_WORDS :: 1 << 16    // read of RESOURCE_MANAGER
@(private = "file") X11_SELECTION_PROP_MAX_WORDS :: 1 << 20   // one read of the scratch property (a chunk or a whole answer)
@(private) X11_TEXT_READ_WAIT_MS :: 500                   // silence of the owner that gives up a read of the text clipboard
@(private = "file") X11_WM_STATE_MAX_WORDS :: 32
@(private = "file") X11_FRAME_EXTENTS_WORDS :: 4

@(private)
x11_open :: proc(w: ^Window, title: string, size: [2]int, transparent: bool) -> bool {
	if !x11_connect() { report_missing("libxcb"); return false }
	x := &xcb
	st := new(X11_Window_State)
	st.transparent = transparent
	st.title = strings.clone(title)
	w.x11 = st
	append(&x11c.windows, w)
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
	// WM_CLASS: "<instance>\0<class>\0", both the program's id (what the desktop matches with its .desktop file)
	app := app_id_or_exe()
	class := strings.concatenate({app, "\x00", app, "\x00"}, context.temp_allocator)
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, X11_FORMAT_8, u32(len(class)), raw_data(class))
	// close through WM_DELETE_WINDOW
	dw := x11c.wm_delete_window
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, x11c.wm_protocols, XCB_ATOM_ATOM, X11_FORMAT_32, 1, &dw)
	// normal window type
	nt := x11c.net_wm_window_type_normal
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, id, x11c.net_wm_window_type, XCB_ATOM_ATOM, X11_FORMAT_32, 1, &nt)
	if w.integrated { x11_set_decorations(w, false) }
	x11_extensions_select(id)
	x.flush(x11c.c)
	return true
}

@(private)
x11_destroy :: proc(w: ^Window) {
	st := x11_state(w)
	if st == nil { return }
	for x, i in x11c.windows { if x == w { ordered_remove(&x11c.windows, i); break } }
	if x11c.dnd_target.window == w { x11c.dnd_target.window = nil }
	if x11c.clip_owner == st.id { x11c.clip_owner = 0; delete(x11c.clip_text); x11c.clip_text = "" }
	xcb.destroy_window(x11c.c, st.id)
	if st.colormap != 0 && xcb.free_colormap != nil { xcb.free_colormap(x11c.c, st.colormap) }   // (an overlay's)
	xcb.flush(x11c.c)
	delete(st.title)
	delete(st.paste.buf)
	delete(st.request.buf)
	delete(st.first_state)
	free(st)
	w.x11 = nil
}

@(private)
x11_set_title :: proc(w: ^Window, title: string) {
	st := x11_state(w)
	x := &xcb
	c := strings.clone_to_cstring(title, context.temp_allocator)
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, XCB_ATOM_WM_NAME, XCB_ATOM_STRING, X11_FORMAT_8, u32(len(title)), rawptr(c))
	x.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.net_wm_name, x11c.utf8_string, X11_FORMAT_8, u32(len(title)), rawptr(c))
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
	if st.withdrawn {
		st.withdrawn = false
		w.shown_again += 1
		w.show = .Normal
		w.paint_requested = true
	}
	xcb.map_window(x11c.c, st.id)
	if st.map_phase == .Never { st.map_phase = .Asked }
	xcb.flush(x11c.c)
}

// Off the screen until x11_show: unmapped, which a window manager reads as withdrawn (ICCCM), not minimized.
@(private)
x11_hide :: proc(w: ^Window) {
	st := x11_state(w)
	if st == nil || st.withdrawn { return }
	st.withdrawn = true
	w.show = .Hidden
	xcb.unmap_window(x11c.c, st.id)
	xcb.flush(x11c.c)
}

@(private)
x11_raise :: proc(w: ^Window) {
	// EWMH _NET_ACTIVE_WINDOW: a ClientMessage to the root asking the window manager to activate this window (source 1 =
	// an application). Window managers that honour it raise and focus the window; those that do not leave it be.
	st := x11_state(w)
	if st == nil { return }
	x11_send_root_message(x11c.net_active_window, st.id, {1, 0, 0, 0, 0})
	xcb.flush(x11c.c)
}

@(private)
x11_minimize :: proc(w: ^Window) {
	// WM_CHANGE_STATE to IconicState (3): a ClientMessage to the root window
	st := x11_state(w)
	wm_change := x11_atom("WM_CHANGE_STATE")
	x11_send_root_message(wm_change, st.id, {3, 0, 0, 0, 0})
}

@(private)
x11_set_maximized :: proc(w: ^Window, on: bool) {
	x11_net_wm_state(w, on, x11c.net_wm_state_maximized_horz, x11c.net_wm_state_maximized_vert)
}

@(private)
x11_set_fullscreen :: proc(w: ^Window, on: bool) {
	x11_net_wm_state(w, on, x11c.net_wm_state_fullscreen, 0)
}

// A left press on the frame of an integrated title bar (frame_linux.odin): the window manager moves or resizes the
// window (_NET_WM_MOVERESIZE, after the press's implicit grab is let go), a double click on the caption maximizes it.
// X11 has no window menu: a right click stays the app's. True when it was the frame's.
@(private)
x11_frame_press :: proc(w: ^Window, btn: Mouse_Button, pos: [2]f32, root: [2]i16, time: u32) -> bool {
	if btn != .Left || x11c.net_wm_moveresize == 0 { return false }
	h := frame_hit(w, pos)
	if !hit_is_frame(h) { return false }
	if h == .Caption && caption_double_click(w, pos, time) { toggle_maximize(w); return true }
	// _NET_WM_MOVERESIZE_SIZE_TOPLEFT 0 .. _SIZE_LEFT 7 clockwise, _MOVE 8
	direction: u32
	#partial switch h {
	case .Top_Left:     direction = 0
	case .Top:          direction = 1
	case .Top_Right:    direction = 2
	case .Right:        direction = 3
	case .Bottom_Right: direction = 4
	case .Bottom:       direction = 5
	case .Bottom_Left:  direction = 6
	case .Left:         direction = 7
	case:               direction = 8
	}
	if xcb.ungrab_pointer != nil { xcb.ungrab_pointer(x11c.c, time) }
	// root x, root y, the direction, button 1, a normal application as the source
	x11_send_root_message(x11c.net_wm_moveresize, x11_state(w).id, {u32(i32(root.x)), u32(i32(root.y)), direction, 1, 1})
	return true
}

// _NET_WM_STATE change: a ClientMessage to the root as the EWMH spec requires (action 1 add, 0 remove). A window the
// window manager does not know yet says it in its property, read when it maps it.
@(private)
x11_net_wm_state :: proc(w: ^Window, add: bool, a1, a2: Xcb_Atom) {
	st := x11_state(w)
	if st.map_phase == .Never {
		for a in ([]Xcb_Atom{a1, a2}) {
			if a == 0 { continue }
			for x, i in st.first_state { if x == a { ordered_remove(&st.first_state, i); break } }
			if add { append(&st.first_state, a) }
		}
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.net_wm_state, XCB_ATOM_ATOM, X11_FORMAT_32, u32(len(st.first_state)), raw_data(st.first_state[:]))
		xcb.flush(x11c.c)
		return
	}
	data := [X11_CLIENT_MESSAGE_WORDS]u32{add ? 1 : 0, u32(a1), u32(a2), 1, 0}
	x11_send_root_message(x11c.net_wm_state, st.id, data)
}

@(private)
x11_send_root_message :: proc(type: Xcb_Atom, id: Xcb_Window, data: [X11_CLIENT_MESSAGE_WORDS]u32) {
	ev: [X11_EVENT_BYTES]u8
	ev[0] = XCB_CLIENT_MESSAGE
	ev[1] = X11_FORMAT_32
	put_u32(ev[4:], u32(id))
	put_u32(ev[8:], u32(type))
	for i in 0 ..< X11_CLIENT_MESSAGE_WORDS { put_u32(ev[12 + i * 4:], data[i]) }
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
	hints := [MWM_HINTS_WORDS]u32{1 << 1, 0, on ? 1 : 0, 0, 0}
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.motif_wm_hints, x11c.motif_wm_hints, X11_FORMAT_32, MWM_HINTS_WORDS, &hints[0])
	xcb.flush(x11c.c)
}

@(private) x11_transparent :: proc(w: ^Window) -> bool { return x11_state(w).transparent }
@(private) x11_fd :: proc(w: ^Window) -> i32 { return x11c.link == .Connected ? x11c.fd : -1 }

@(private) XCB_CONFIG_WINDOW_X :: 1 << 0
@(private) XCB_CONFIG_WINDOW_Y :: 1 << 1

@(private)
x11_move :: proc(w: ^Window, x, y: int) {
	st := x11_state(w)
	values := [2]i32{i32(x), i32(y)}
	xcb.configure_window(x11c.c, st.id, XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, &values[0])
	xcb.flush(x11c.c)
}

// Where the client area starts on the screen.
@(private)
x11_client_origin :: proc(w: ^Window) -> [2]int {
	st := x11_state(w)
	if st == nil { return {} }
	p, _, _ := x11_translate(st.id, x11c.screen.root, 0, 0)
	return p
}

// Whether the window manager draws a frame around the window: _NET_FRAME_EXTENTS says how wide (all zero: none).
@(private)
x11_read_frame_extents :: proc(w: ^Window) {
	st := x11_state(w)
	if st == nil { return }
	w.system_frame = false
	reply := xcb.get_property_reply(x11c.c, xcb.get_property(x11c.c, 0, st.id, x11c.net_frame_extents, XCB_ATOM_CARDINAL, 0, X11_FRAME_EXTENTS_WORDS), nil)
	if reply == nil { return }
	defer posix.free(reply)
	if xcb.get_property_value_length(reply) < X11_FRAME_EXTENTS_WORDS * size_of(u32) { return }
	e := ([^]u32)(xcb.get_property_value(reply))
	w.system_frame = e[0] > 0 || e[1] > 0 || e[2] > 0 || e[3] > 0
}

// The window's outer rectangle: its corner is the frame's (what a move sets, under a window manager), the frame read from
// _NET_FRAME_EXTENTS (left, right, top, bottom); its size is the client area's, what x11_set_size takes.
@(private)
x11_outer_rect :: proc(w: ^Window) -> [4]int {
	p := x11_client_origin(w)
	if st := x11_state(w); st != nil {
		reply := xcb.get_property_reply(x11c.c, xcb.get_property(x11c.c, 0, st.id, x11c.net_frame_extents, XCB_ATOM_CARDINAL, 0, X11_FRAME_EXTENTS_WORDS), nil)
		if reply != nil {
			defer posix.free(reply)
			if xcb.get_property_value_length(reply) >= X11_FRAME_EXTENTS_WORDS * size_of(u32) {
				e := ([^]u32)(xcb.get_property_value(reply))
				p.x -= int(e[0])
				p.y -= int(e[2])
			}
		}
	}
	return {p.x, p.y, w.size.x, w.size.y}
}

// DPI from Xft.dpi in the X resources, else 96. Read fresh (cheap) only when stale.
@(private)
x11_dpi_scale :: proc() -> f32 {
	dpi := x11_xft_dpi()
	return dpi > 0 ? f32(dpi) / DPI_BASE : 1
}

@(private)
x11_xft_dpi :: proc() -> int {
	x := &xcb
	// RESOURCE_MANAGER on the root is a text blob of X resources; find "Xft.dpi:"
	cookie := x.get_property(x11c.c, 0, x11c.screen.root, x11c.resource_manager, XCB_ATOM_STRING, 0, X11_RESOURCES_MAX_WORDS)
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
	// first what xcb has read already (behind the reply of a request): poll(2) on the socket would not see it
	any := x11_drain(w)
	if wait && !any && len(w.events) == 0 && len(w.injected) == 0 {
		x.flush(x11c.c)
		poll_sources(w, x11_fd(w), timeout_ms > 0 ? timeout_ms : -1)
		x11_drain(w)
	}
	dbus_pump()
	x11_incr_give_up()
	x.flush(x11c.c)
}

// Handles every event there is, without waiting; whether there was one.
@(private)
x11_drain :: proc(w: ^Window) -> (any: bool) {
	for {
		ev := xcb.poll_for_event(x11c.c)
		if ev == nil { break }
		any = true
		x11_handle_event(w, ev)
		posix.free(ev)
	}
	x11_check_link()
	return
}

// A connection in error has no more events, and its socket reads as ready for good.
@(private)
x11_check_link :: proc() {
	if x11c.link != .Connected || xcb.connection_has_error(x11c.c) == 0 { return }
	x11c.link = .Lost
	display_lost(x11c.windows[:])
}

@(private)
x11_wait :: proc(w: ^Window, timeout_ms: int) {
	x11_drain(w)   // (what xcb has read already: poll(2) would not see it; kept for the next poll_events)
	if wait_is_over(w) { return }
	xcb.flush(x11c.c)
	poll_sources(w, x11_fd(w), timeout_ms > 0 ? timeout_ms : -1)
}

// Takes only keyboard and pointer events now (wait_handle), queuing them time-stamped; leaves the rest for poll_events.
@(private)
x11_take_input :: proc(w: ^Window) {
	// XCB has no per-category peek, so take everything and let poll_events return it next; the time stamp is set here.
	xcb.flush(x11c.c)
	x11_drain(w)
}

@(private)
x11_push :: proc(w: ^Window, e: Event) {
	e := e
	e.stamp = time.tick_now()
	append(&w.events, e)
}

// The window an event is for: one connection brings the events of all of them, whichever window polls. nil: a window that
// is gone, its last notices still on their way (a destroyed window's UnmapNotify is nobody else's). A PropertyNotify may
// be another client's window, the one an INCR transfer goes to.
@(private)
x11_event_target :: proc(polling: ^Window, raw: ^Xcb_Generic_Event) -> ^Window {
	b := ([^]u8)(raw)
	id: Xcb_Window
	unknown: ^Window
	switch raw.response_type & X11_RESPONSE_TYPE_MASK {
	case XCB_KEY_PRESS, XCB_KEY_RELEASE, XCB_BUTTON_PRESS, XCB_BUTTON_RELEASE, XCB_MOTION_NOTIFY, XCB_ENTER_NOTIFY, XCB_LEAVE_NOTIFY:
		id = Xcb_Window(get_u32(b[12:]))
	case XCB_FOCUS_IN, XCB_FOCUS_OUT, XCB_EXPOSE, XCB_CONFIGURE_NOTIFY, XCB_MAP_NOTIFY, XCB_UNMAP_NOTIFY, XCB_CLIENT_MESSAGE:
		id = Xcb_Window(get_u32(b[4:]))
	case XCB_PROPERTY_NOTIFY:
		id = Xcb_Window(get_u32(b[4:]))
		unknown = polling
	case XCB_SELECTION_REQUEST, XCB_SELECTION_CLEAR, XCB_SELECTION_NOTIFY:
		id = Xcb_Window(get_u32(b[8:]))
	case:
		return polling
	}
	for x in x11c.windows { if x11_state(x).id == id { return x } }
	return unknown
}

// Whether a window is one of this connection's.
@(private)
x11_is_ours :: proc(id: Xcb_Window) -> bool {
	for x in x11c.windows { if x11_state(x).id == id { return true } }
	return false
}

// Whether a keycode gives Escape now.
@(private)
x11_key_is_escape :: proc(keycode: u8) -> bool {
	k := xkb_lib()
	return k.ok && x11c.xkb_state != nil && key_from_keysym(k.state_key_get_one_sym(x11c.xkb_state, u32(keycode))) == .Escape
}

@(private)
x11_handle_event :: proc(polling: ^Window, raw: ^Xcb_Generic_Event) {
	b := ([^]u8)(raw)
	type := raw.response_type & X11_RESPONSE_TYPE_MASK
	if type == XCB_DESTROY_NOTIFY {   // (xcb_destroy_notify_event_t: window at [8])
		x11_dnd_source_gone(Xcb_Window(get_u32(b[8:])))
		x11_incr_give_up(Xcb_Window(get_u32(b[8:])))
		return
	}
	w := x11_event_target(polling, raw)
	if w == nil { return }
	st := x11_state(w)
	if x11c.xkb_event != 0 && type == x11c.xkb_event {
		if b[1] == X11_XKB_NEW_KEYBOARD_NOTIFY || b[1] == X11_XKB_MAP_NOTIFY { x11_xkb_load() }
		return
	}
	if type == XCB_MAPPING_NOTIFY {
		if b[4] != X11_MAPPING_POINTER { x11_xkb_load() }   // (xcb_mapping_notify_event_t: request at [4])
		return
	}
	if x11c.xfixes_event != 0 && type == x11c.xfixes_event {
		// xcb_xfixes_selection_notify_event_t: owner at [8], selection at [12]. This program's own writes count themselves
		if Xcb_Atom(get_u32(b[12:])) == x11c.clipboard && !x11_is_ours(Xcb_Window(get_u32(b[8:]))) { clip_note_changed() }
		return
	}
	if x11c.randr_event != 0 && type == x11c.randr_event {
		for x in x11c.windows { x.display_stale = true }
		return
	}
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
		case 1, 2, 3, X11_BUTTON_BACK, X11_BUTTON_FORWARD:
			btn: Mouse_Button
			switch detail {
			case 1:                  btn = .Left
			case 2:                  btn = .Middle
			case 3:                  btn = .Right
			case X11_BUTTON_BACK:    btn = .Back
			case X11_BUTTON_FORWARD: btn = .Forward
			}
			// (event time at [4], root x and y at [16] and [18])
			time := u32(b[4]) | u32(b[5]) << 8 | u32(b[6]) << 16 | u32(b[7]) << 24
			root := [2]i16{i16(u16(b[16]) | u16(b[17]) << 8), i16(u16(b[18]) | u16(b[19]) << 8)}
			// (no window manager gives an override-redirect window the keyboard: a click on an overlay takes it)
			if press && w.overlay { x11_overlay_focus(w, time) }
			if press && x11_frame_press(w, btn, pos, root, time) {
				x11_push(w, {kind = .Frame_Press, button = btn, pos = pos, mods = mods, buttons = w.buttons_down})
				break
			}
			if button_changes(w, btn, press) {
				x11_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = btn, pos = pos, mods = mods, buttons = w.buttons_down})
			}
		case X11_BUTTON_WHEEL_UP, X11_BUTTON_WHEEL_DOWN, X11_BUTTON_WHEEL_LEFT, X11_BUTTON_WHEEL_RIGHT:
			if press {
				e := Event{kind = .Scroll, pos = pos, mods = mods}
				switch detail {
				case X11_BUTTON_WHEEL_UP: e.delta.y = 1     // wheel up: content moves up (page down), as Win32 (+y = down)
				case X11_BUTTON_WHEEL_DOWN: e.delta.y = -1
				case X11_BUTTON_WHEEL_LEFT: e.delta.x = -1
				case X11_BUTTON_WHEEL_RIGHT: e.delta.x = 1
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
		frame_hover_at(w, {f32(ex), f32(ey)})
		x11_push(w, {kind = .Mouse_Move, pos = {f32(ex), f32(ey)}, mods = x11_mods(state), buttons = w.buttons_down})
	case XCB_MAP_NOTIFY:
		st.map_phase = .Mapped
		x11_read_wm_state(w)
	case XCB_UNMAP_NOTIFY:
		st.map_phase = .Unmapped
		x11_read_wm_state(w)
		// (a grab cannot take a held button from the window, but its going off the screen ends the button's own grab)
		buttons_released(w, {}, {})
	case XCB_ENTER_NOTIFY:
	case XCB_LEAVE_NOTIFY:
		// (under the button's own grab the pointer is still the window's, as under a capture on Windows: the end of the grab
		// says it left, with its own LeaveNotify)
		if w.buttons_down == {} { x11_push(w, {kind = .Mouse_Leave}) }
	case XCB_FOCUS_IN, XCB_FOCUS_OUT:
		// xcb_focus_in_event_t: mode at [8]. A keyboard grab (a menu of the window manager, our own drag) moves no focus
		if mode := b[8]; mode != X11_NOTIFY_GRAB && mode != X11_NOTIFY_UNGRAB { window_focus(w, type == XCB_FOCUS_IN, {}) }
	case XCB_EXPOSE:
		w.paint_requested = true
	case XCB_CONFIGURE_NOTIFY:
		nw := int(u16(b[20]) | u16(b[21]) << 8)
		nh := int(u16(b[22]) | u16(b[23]) << 8)
		if nw > 0 && nh > 0 && (nw != w.size.x || nh != w.size.y) {
			w.size = {nw, nh}
			w.paint_requested = true
		}
		w.display_stale = true   // (it may have moved to another monitor)
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
		// xcb_selection_clear_event_t: selection at [12] (losing PRIMARY or XdndSelection is not losing the clipboard)
		if Xcb_Atom(get_u32(b[12:])) == x11c.clipboard && x11c.clip_owner == st.id {
			x11c.clip_owner = 0
			if x11c.xfixes_event == 0 { clip_note_changed() }
		}
	case XCB_PROPERTY_NOTIFY:
		// xcb_property_notify_event_t: window[4], atom[8], time[12], state[16] (0 NewValue, 1 Deleted)
		pwin := Xcb_Window(get_u32(b[4:]))
		patom := Xcb_Atom(get_u32(b[8:]))
		pstate := b[16]
		if pwin == x11c.screen.root {
			if patom == x11c.resource_manager { x11_dpi_changed() }
		} else if pwin == st.id && patom == x11c.net_wm_state {
			x11_read_wm_state(w)
		} else if pwin == st.id && patom == x11c.net_frame_extents {
			x11_read_frame_extents(w)
		} else if pstate == 1 {   // Deleted: a requestor consumed an INCR chunk, send the next
			x11_incr_on_property_delete(pwin, patom)
		} else if pwin == st.id {
			x11_incr_receive_chunk(st, &st.paste, patom)
			if x11_incr_receive_chunk(st, &st.request, patom) { clip_reads_pump(w) }
		}
	}
}

// What the window manager says of the window (_NET_WM_STATE): the user can minimize, maximize or restore it at any time.
@(private)
x11_read_wm_state :: proc(w: ^Window) {
	st := x11_state(w)
	cookie := xcb.get_property(x11c.c, 0, st.id, x11c.net_wm_state, XCB_ATOM_ATOM, 0, X11_WM_STATE_MAX_WORDS)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return }
	defer posix.free(reply)
	if st.map_phase == .Never || st.map_phase == .Asked { return }   // (still Hidden: what it says now is only what was asked)
	atoms := ([^]Xcb_Atom)(xcb.get_property_value(reply))
	horz, vert, hidden, full: bool
	for i in 0 ..< int(xcb.get_property_value_length(reply)) / size_of(Xcb_Atom) {
		switch atoms[i] {
		case x11c.net_wm_state_maximized_horz: horz = true
		case x11c.net_wm_state_maximized_vert: vert = true
		case x11c.net_wm_state_hidden:         hidden = true
		case x11c.net_wm_state_fullscreen:     full = true
		}
	}
	switch {
	case st.withdrawn:                        w.show = .Hidden   // (the program hid it: x11_hide)
	case hidden || st.map_phase == .Unmapped: w.show = .Minimized   // (a window manager without _NET_WM_STATE_HIDDEN unmaps it)
	case full:                                w.show = .Fullscreen
	case horz && vert:                        w.show = .Maximized
	case:                                     w.show = .Normal
	}
}

// Xft.dpi changed (RESOURCE_MANAGER): the windows' scale follows, as a monitor's change on the other systems.
@(private = "file")
x11_dpi_changed :: proc() {
	k := x11_dpi_scale()
	for x in x11c.windows {
		if x.dpi_scale == k { continue }
		x.dpi_scale = k
		x.display_stale = true
		x.paint_requested = true
		apply_cursor(x)
	}
}

// Where a point is in another window, and the child of `dst` under it (0: none). xcb_translate_coordinates.
@(private)
x11_translate :: proc(src, dst: Xcb_Window, x, y: int) -> (p: [2]int, child: Xcb_Window, ok: bool) {
	if xcb.translate_coordinates == nil || xcb.translate_coordinates_reply == nil { return }
	reply := xcb.translate_coordinates_reply(x11c.c, xcb.translate_coordinates(x11c.c, src, dst, i16(x), i16(y)), nil)
	if reply == nil { return }
	defer posix.free(reply)
	// xcb_translate_coordinates_reply_t: child at [8], dst_x at [12], dst_y at [14]
	b := ([^]u8)(reply)
	child = Xcb_Window(get_u32(b[8:]))
	p = {int(i16(u16(b[12]) | u16(b[13]) << 8)), int(i16(u16(b[14]) | u16(b[15]) << 8))}
	return p, child, true
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
		// the modifiers and the group of the event are the ones it was typed with, whatever came since
		k.state_update_mask(x11c.xkb_state, u32(state) & X11_STATE_MODS_MASK, 0, 0, 0, 0, u32(state) >> X11_STATE_GROUP_SHIFT & X11_STATE_GROUP_MASK)
		key = key_from_xkb(x11c.xkb_keymap, x11c.xkb_state, keycode)
		if press {
			buf: [8]u8
			n := k.state_key_get_utf8(x11c.xkb_state, keycode, &buf[0], size_of(buf))
			if n > 0 {
				s := string(buf[:n])
				if r, sz := utf8.decode_rune(s); sz > 0 && r >= RUNE_FIRST_PRINTABLE && r != RUNE_DEL { text = r }
			}
		}
	}
	mods := x11_mods(state)
	if key != .None {
		repeat := press && key in w.keys_down
		if key_changes(w, key, press) { x11_push(w, {kind = press ? .Key_Press : .Key_Release, key = key, mods = mods, repeat = repeat}) }
	}
	if press && text != 0 && .Ctrl not_in mods && .Alt not_in mods {
		x11_push(w, {kind = .Text, text = text, mods = mods})
	}
}

////////////////////////////////
// Text clipboard (CLIPBOARD selection)

// xcb_set_selection_owner.
@(private)
x11_set_selection_owner :: proc(selection: Xcb_Atom, owner: Xcb_Window) {
	if xcb.set_selection_owner != nil { xcb.set_selection_owner(x11c.c, owner, selection, 0) }
}

@(private)
x11_convert_selection :: proc(requestor: Xcb_Window, selection, target, property: Xcb_Atom) {
	if xcb.convert_selection != nil { xcb.convert_selection(x11c.c, requestor, selection, target, property, 0) }
}

// Answer a SelectionRequest: another client wants a flavour of our CLIPBOARD / PRIMARY. The rich logic (TARGETS,
// MULTIPLE, the MIME targets, INCR for big data) is in clipboard_x11_linux.odin.
@(private)
x11_handle_selection_request :: proc(w: ^Window, b: [^]u8) {
	// xcb_selection_request_event_t: selection at [16]
	if x11c.dnd_source.phase != .Idle && Xcb_Atom(get_u32(b[16:])) == x11c.xdnd_selection { x11_dnd_serve_source_request(b); return }
	x11_serve_selection_request(w, b)
}

@(private)
x11_handle_selection_notify :: proc(w: ^Window, b: [^]u8) {
	st := x11_state(w)
	x11_read_notify(st, &st.paste, b)
	if x11_read_notify(st, &st.request, b) { clip_reads_pump(w) }
}

// A SelectionNotify for read `r`: its answer, or the owner's refusal. Whether it was `r`'s. (A refusal names no property:
// it ends both reads when both asked the same.) A read that gave up may hear from its owner when the next one runs.
@(private = "file")
x11_read_notify :: proc(st: ^X11_Window_State, r: ^X11_Selection_Read, b: [^]u8) -> bool {
	// xcb_selection_notify_event_t: requestor at [8], selection, target, property
	if r.phase != .Waiting || Xcb_Atom(get_u32(b[12:])) != r.selection || Xcb_Atom(get_u32(b[16:])) != r.target { return false }
	property := Xcb_Atom(get_u32(b[20:]))
	if property == 0 { r.phase = .Done; return true }
	if property != r.property { return false }
	// read the property without deleting it first, so we can tell an INCR hand-off (type = INCR) from real data
	cookie := xcb.get_property(x11c.c, 0, st.id, property, 0, 0, X11_SELECTION_PROP_MAX_WORDS)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { r.phase = .Done; return true }
	// xcb_get_property_reply_t: type at [8]
	ptype := Xcb_Atom(get_u32(([^]u8)(reply)[8:]))
	n := int(xcb.get_property_value_length(reply))
	if ptype == x11c.atom_incr {
		// the real data streams in: delete the property to ask for the first chunk, then read on each PropertyNotify
		posix.free(reply)
		r.phase = .Receiving
		clear(&r.buf)
		xcb.delete_property(x11c.c, st.id, property)
		xcb.flush(x11c.c)
		return true
	}
	if n > 0 {
		data := ([^]u8)(xcb.get_property_value(reply))
		clear(&r.buf)
		append(&r.buf, ..data[:n])
	}
	posix.free(reply)
	xcb.delete_property(x11c.c, st.id, property)   // (the answer is read: nothing of it stays on the window)
	xcb.flush(x11c.c)
	r.phase = .Done
	return true
}

// One INCR chunk arrived on read `r`'s property (PropertyNotify NewValue while Receiving): append it, delete the property
// to ask for the next. A zero-length chunk ends the transfer. Whether it was `r`'s.
@(private)
x11_incr_receive_chunk :: proc(st: ^X11_Window_State, r: ^X11_Selection_Read, property: Xcb_Atom) -> bool {
	if r.phase != .Receiving || property != r.property { return false }
	cookie := xcb.get_property(x11c.c, 0, st.id, r.property, 0, 0, X11_SELECTION_PROP_MAX_WORDS)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return true }
	n := int(xcb.get_property_value_length(reply))
	if n > 0 {
		data := ([^]u8)(xcb.get_property_value(reply))
		append(&r.buf, ..data[:n])
	} else {
		r.phase = .Done   // the empty terminator
	}
	posix.free(reply)
	xcb.delete_property(x11c.c, st.id, r.property)   // (ask for the next chunk; after the last, nothing stays)
	xcb.flush(x11c.c)
	return true
}

@(private)
x11_clipboard_get_text :: proc(w: ^Window, allocator := context.allocator) -> string {
	st := x11_state(w)
	if x11c.clip_owner == st.id { return strings.clone(x11c.clip_text, allocator) }   // our own text
	return strings.clone(string(x11_selection_read(w, x11c.clipboard, "text/plain", context.temp_allocator, X11_TEXT_READ_WAIT_MS)), allocator)
}

@(private)
put_u32 :: proc(b: []u8, v: u32) { b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
@(private)
get_u32 :: proc(b: [^]u8) -> u32 { return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24 }

// Frees what xcb allocated (a reply).
@(private)
free_c :: proc(p: rawptr) { posix.free(p) }
