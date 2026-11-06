#+build linux
package platform

// X11 drag and drop over XDND version 5 (dragdrop_linux.odin has the API). As a target: XdndAware marks the window,
// XdndEnter / XdndPosition / XdndDrop / XdndLeave client messages drive the Drop_* events, and the data is read with
// ConvertSelection on XdndSelection (the clipboard read path, clipboard_x11_linux.odin). As a source: drag_start owns
// XdndSelection, finds the window under the pointer, sends it XdndEnter / XdndPosition, reads XdndStatus for the effect
// and the accept, and on release sends XdndDrop (or XdndLeave), pumping the X connection until XdndFinished. The
// source draws its picture in a window of its own that follows the pointer, offers the formats of the app's own under
// their MIME types, and follows XdndProxy.
//
// The MIME targets are the same atoms as the clipboard (text/html, image/png, text/uri-list, UTF8_STRING).

import "core:strings"
import "core:time"
import "core:sys/posix"

@(private) XDND_VERSION :: 5
@(private = "file") XDND_VERSION_SHIFT :: 24      // in the second word of XdndEnter
@(private = "file") XDND_INLINE_TYPES :: 3        // what XdndEnter carries; more go in XdndTypeList
@(private = "file") XDND_TYPE_LIST_MAX_WORDS :: 1 << 10
@(private = "file") XDND_SOURCE_POLL_MS :: 15     // between two looks at the connection during a drag
@(private = "file") XDND_WINDOW_DEPTH_MAX :: 16   // bounds the walk down the window tree under the pointer
@(private = "file") X11_PUT_IMAGE_ROWS :: 64      // rows per request: a large picture passes the request limit of a server without BIG-REQUESTS
@(private = "file") XCB_IMAGE_FORMAT_Z_PIXMAP :: 2
@(private = "file") XCB_CW_BACK_PIXMAP :: 1 << 0
@(private = "file") XCB_CW_BORDER_PIXEL :: 1 << 3
@(private = "file") XCB_CW_OVERRIDE_REDIRECT :: 1 << 9
@(private = "file") XCB_VISUAL_CLASS_TRUE_COLOR :: 4
@(private = "file") X11_ARGB_DEPTH :: 32

@(private)
x11_dnd_intern_atoms :: proc() {
	x11c.xdnd_aware = x11_atom("XdndAware")
	x11c.xdnd_enter = x11_atom("XdndEnter")
	x11c.xdnd_position = x11_atom("XdndPosition")
	x11c.xdnd_status = x11_atom("XdndStatus")
	x11c.xdnd_leave = x11_atom("XdndLeave")
	x11c.xdnd_drop = x11_atom("XdndDrop")
	x11c.xdnd_finished = x11_atom("XdndFinished")
	x11c.xdnd_type_list = x11_atom("XdndTypeList")
	x11c.xdnd_selection = x11_atom("XdndSelection")
	x11c.xdnd_action_copy = x11_atom("XdndActionCopy")
	x11c.xdnd_action_move = x11_atom("XdndActionMove")
	x11c.xdnd_action_link = x11_atom("XdndActionLink")
	x11c.xdnd_proxy = x11_atom("XdndProxy")
	x11c.xdnd_action_list = x11_atom("XdndActionList")
}

// Mark the window as an XDND target (or not).
@(private)
x11_dnd_set_aware :: proc(w: ^Window, on: bool) {
	st := x11_state(w)
	if st == nil { return }
	if on {
		v := u32(XDND_VERSION)
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.xdnd_aware, XCB_ATOM_ATOM, X11_FORMAT_32, 1, &v)
	} else {
		xcb.delete_property(x11c.c, st.id, x11c.xdnd_aware)
	}
	xcb.flush(x11c.c)
}

////////////////////////////////
// target side

// The drag source we are receiving from now, and the position / accepted type between enter and drop.
@(private)
X11_Dnd_Target :: struct {
	source:   Xcb_Window,
	version:  int,
	types:    [dynamic]Xcb_Atom,
	accepted: Xcb_Atom,     // the type we will read on drop
	pos:      [2]f32,
	window:   ^Window,      // the window it is over (its source's death is told there)
}

@(private)
x11_dnd_client_message :: proc(w: ^Window, mtype: Xcb_Atom, b: [^]u8) {
	// client message data32: [12], [16], [20], [24], [28]
	d1 := get_u32(b[16:]); d2 := get_u32(b[20:]); d3 := get_u32(b[24:]); d4 := get_u32(b[28:])
	switch mtype {
	case x11c.xdnd_enter:
		drop_left(w, x11c.dnd_target.pos)   // (a source that went without a word)
		x11c.dnd_target.source = Xcb_Window(get_u32(b[12:]))
		x11c.dnd_target.version = int(d1 >> XDND_VERSION_SHIFT)
		x11c.dnd_target.window = w
		clear(&x11c.dnd_target.types)
		if d1 & 1 != 0 {
			// more than three types: read the XdndTypeList property on the source
			x11_dnd_read_type_list(x11c.dnd_target.source)
		} else {
			for a in ([]u32{d2, d3, d4}) { if a != 0 { append(&x11c.dnd_target.types, Xcb_Atom(a)) } }
		}
		x11c.dnd_target.accepted = x11_dnd_pick_type()
		// its end, if it dies without a word: nothing else tells (a window of ours keeps its mask)
		if !x11_is_ours(x11c.dnd_target.source) {
			x11_change_window_attrs_event_mask(x11c.dnd_target.source, XCB_EVENT_MASK_STRUCTURE_NOTIFY)
			xcb.flush(x11c.c)
		}
	case x11c.xdnd_position:
		rootx := i16(u16(d2 >> 16)); rooty := i16(u16(d2 & 0xffff))   // data32[2]
		p := x11_root_to_client(w, int(rootx), int(rooty))
		x11c.dnd_target.pos = p
		d := dnd_state(w)
		d.allowed = x11_source_actions(x11c.dnd_target.source, Xcb_Atom(d4))
		if !d.over {
			context.allocator = d.allocator
			drag_data_destroy(&d.data)
			d.over = true
			d.effect = nil
			deliver_drop(w, .Drop_Enter, p)
		} else {
			deliver_drop(w, .Drop_Over, p)
		}
		e := dnd_answer(w)
		if x11c.dnd_target.accepted == 0 { e = nil }
		x11_send_xdnd_status(w, x11c.dnd_target.source, e)
	case x11c.xdnd_leave:
		drop_left(w, x11c.dnd_target.pos)
		x11c.dnd_target.window = nil
	case x11c.xdnd_drop:
		d := dnd_state(w)
		// request the selection for the accepted type; the data arrives as a SelectionNotify we read synchronously
		if x11c.dnd_target.accepted != 0 {
			context.allocator = d.allocator
			drag_data_destroy(&d.data)
			d.data = x11_dnd_read_all(w)
		}
		d.over = false
		deliver_drop(w, .Drop, x11c.dnd_target.pos)
		e := dnd_answer(w)
		if x11c.dnd_target.accepted == 0 { e = nil }
		x11_send_xdnd_finished(w, x11c.dnd_target.source, e)
		x11c.dnd_target.window = nil
	}
}

// The drag's source died under a window (DestroyNotify of the window it named at XdndEnter).
@(private)
x11_dnd_source_gone :: proc(source: Xcb_Window) {
	t := &x11c.dnd_target
	if t.window == nil || t.source != source { return }
	drop_left(t.window, t.pos)
	t.window = nil
}

// What the source allows: its XdndActionList, else the action of its XdndPosition.
@(private = "file")
x11_source_actions :: proc(source: Xcb_Window, action: Xcb_Atom) -> (out: Drop_Effects) {
	reply := xcb.get_property_reply(x11c.c, xcb.get_property(x11c.c, 0, source, x11c.xdnd_action_list, XCB_ATOM_ATOM, 0, XDND_TYPE_LIST_MAX_WORDS), nil)
	if reply != nil {
		defer posix.free(reply)
		atoms := ([^]Xcb_Atom)(xcb.get_property_value(reply))
		for i in 0 ..< int(xcb.get_property_value_length(reply)) / size_of(Xcb_Atom) { out += x11_effect_of(atoms[i]) }
	}
	return out != {} ? out : x11_effect_of(action)
}

@(private = "file")
x11_effect_of :: proc(action: Xcb_Atom) -> Drop_Effects {
	switch action {
	case x11c.xdnd_action_copy: return {.Copy}
	case x11c.xdnd_action_move: return {.Move}
	case x11c.xdnd_action_link: return {.Link}
	}
	return {}
}

@(private)
x11_dnd_read_type_list :: proc(source: Xcb_Window) {
	cookie := xcb.get_property(x11c.c, 0, source, x11c.xdnd_type_list, XCB_ATOM_ATOM, 0, XDND_TYPE_LIST_MAX_WORDS)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return }
	defer posix.free(reply)
	n := int(xcb.get_property_value_length(reply)) / 4
	atoms := ([^]u32)(xcb.get_property_value(reply))
	for i in 0 ..< n { append(&x11c.dnd_target.types, Xcb_Atom(atoms[i])) }
}

// The type we will ask for, by preference: uri-list, html, png, text.
@(private)
x11_dnd_pick_type :: proc() -> Xcb_Atom {
	prefs := [?]Xcb_Atom{x11c.mime_uri_list, x11c.mime_text_html, x11c.mime_image_png, x11c.utf8_string, XCB_ATOM_STRING}
	for p in prefs { for t in x11c.dnd_target.types { if t == p { return p } } }
	return len(x11c.dnd_target.types) > 0 ? x11c.dnd_target.types[0] : 0
}

// Reads every advertised type we understand off XdndSelection into a Drag_Data.
@(private)
x11_dnd_read_all :: proc(w: ^Window, allocator := context.allocator) -> (out: Drag_Data) {
	context.allocator = allocator
	has :: proc(t: Xcb_Atom) -> bool { for x in x11c.dnd_target.types { if x == t { return true } }; return false }
	if has(x11c.mime_uri_list) {
		b := x11_selection_read(w, x11c.xdnd_selection, "text/uri-list", context.temp_allocator)
		for p in uri_list_to_paths(string(b), allocator) { append(&out.files, p) }
	}
	// the formats of the app's own (of any program): every other MIME type
	for t in x11c.dnd_target.types {
		if t == x11c.mime_uri_list || t == x11c.mime_text_html || t == x11c.mime_image_png || t == x11c.utf8_string || t == XCB_ATOM_STRING { continue }
		name := x11_atom_name(t)
		if strings.index_byte(name, '/') < 0 || strings.has_prefix(name, "text/plain") { continue }
		b := x11_selection_read(w, x11c.xdnd_selection, name, context.temp_allocator)
		if len(b) > 0 { append(&out.custom, Drag_Entry{clone_string(name), clone_string(string(b))}) }
	}
	if has(x11c.mime_text_html) {
		b := x11_selection_read(w, x11c.xdnd_selection, "text/html", context.temp_allocator)
		out.html = clone_string(string(b))
	}
	if has(x11c.utf8_string) || has(XCB_ATOM_STRING) {
		b := x11_selection_read(w, x11c.xdnd_selection, "text/plain", context.temp_allocator)
		out.text = clone_string(string(b))
	}
	if len(out.files) == 0 && has(x11c.mime_image_png) {
		b := x11_selection_read(w, x11c.xdnd_selection, "image/png", context.temp_allocator)
		if len(b) > 0 { out.image = make([]u8, len(b)); copy(out.image, b) }
	}
	return
}

// The atom of an effect (0: none).
@(private)
x11_action_atom :: proc(e: Maybe(Drop_Effect)) -> Xcb_Atom {
	v, ok := e.?
	if !ok { return 0 }
	switch v {
	case .Copy: return x11c.xdnd_action_copy
	case .Move: return x11c.xdnd_action_move
	case .Link: return x11c.xdnd_action_link
	}
	return 0
}

@(private)
x11_send_xdnd_status :: proc(w: ^Window, source: Xcb_Window, effect: Maybe(Drop_Effect)) {
	st := x11_state(w)
	data := [X11_CLIENT_MESSAGE_WORDS]u32{
		u32(st.id),
		effect != nil ? 1 : 0,     // bit 0: accept
		0, 0,                      // empty rectangle: send a status for every position
		u32(x11_action_atom(effect)),
	}
	x11_send_client_message(source, x11c.xdnd_status, data)
}

@(private)
x11_send_xdnd_finished :: proc(w: ^Window, source: Xcb_Window, effect: Maybe(Drop_Effect)) {
	st := x11_state(w)
	data := [X11_CLIENT_MESSAGE_WORDS]u32{u32(st.id), effect != nil ? 1 : 0, u32(x11_action_atom(effect)), 0, 0}
	x11_send_client_message(source, x11c.xdnd_finished, data)
}

////////////////////////////////
// source side

@(private)
X11_Dnd_Source :: struct {
	data:      Drag_Data,
	allowed:   Drop_Effects,
	targets:   [dynamic]Xcb_Atom,
	phase:     Drag_Phase,
	button:    u8,             // the core button whose release ends the drag
	window:    Xcb_Window,
	target:    Xcb_Window,     // the toplevel under the pointer we are talking to
	accepted:  bool,           // it says a drop there would be taken
	dest:      Xcb_Window,     // where the messages for it go: the target, or its XdndProxy
	action:    Xcb_Atom,       // the action asked of the target
	image:     X11_Drag_Image,
	answer:    Xcb_Atom,       // the action the target says it takes
}

// Runs an XDND drag from `w`. Owns XdndSelection and follows the pointer sending XdndEnter /
// Position to the target under it, until the button is released (XdndDrop) or the drag is cancelled (XdndLeave).
@(private)
x11_drag_start :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, image: Maybe(Drag_Image)) -> (effect: Maybe(Drop_Effect), ok: bool) {
	st := x11_state(w)
	if st == nil { return nil, false }
	// the drag follows the press that began it: a press already released has nothing to end it
	button := x11_core_button(w.buttons_down)
	if button == 0 { return nil, false }
	x11c.dnd_source = {}
	x11c.dnd_source.data = drag_data_clone(data)
	x11c.dnd_source.allowed = allowed
	x11c.dnd_source.window = st.id
	x11c.dnd_source.phase = .Tracking
	x11c.dnd_source.button = button
	x11c.dnd_source.action = x11_action_atom(drop_effect_for(allowed, {}))
	x11_dnd_build_targets(data)
	if img, has := image.?; has { x11_drag_image_make(w, img) }
	// own XdndSelection so the target can read our data (served by the same SelectionRequest handler)
	x11_dnd_own_selection(st.id)
	// publish the type list for more than three types, and what the target may do
	if len(x11c.dnd_source.targets) > XDND_INLINE_TYPES {
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.xdnd_type_list, XCB_ATOM_ATOM, X11_FORMAT_32, u32(len(x11c.dnd_source.targets)), raw_data(x11c.dnd_source.targets[:]))
	}
	actions := make([dynamic]Xcb_Atom, context.temp_allocator)
	for e in allowed { append(&actions, x11_action_atom(e)) }
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, st.id, x11c.xdnd_action_list, XCB_ATOM_ATOM, X11_FORMAT_32, u32(len(actions)), raw_data(actions[:]))
	x11_keyboard_grab(st.id, true)
	result := x11_dnd_source_loop(w)
	x11_keyboard_grab(st.id, false)
	x11_set_selection_owner(x11c.xdnd_selection, 0)   // (what asks for it now is told there is nothing)
	xcb.delete_property(x11c.c, st.id, x11c.xdnd_action_list)
	x11_drag_image_free()
	drag_data_destroy(&x11c.dnd_source.data)
	delete(x11c.dnd_source.targets)
	x11c.dnd_source.phase = .Idle
	return result, true
}

// The first of the buttons held, as the server numbers it (0: none).
@(private = "file")
x11_core_button :: proc(down: Mouse_Buttons) -> u8 {
	for b in down {
		switch b {
		case .Left:    return 1
		case .Middle:  return 2
		case .Right:   return 3
		case .Back:    return 8
		case .Forward: return 9
		}
	}
	return 0
}

// Escape reaches the drag wherever the focus is. (A refused grab: Escape then works only with the focus here.)
@(private = "file")
x11_keyboard_grab :: proc(id: Xcb_Window, on: bool) {
	if xcb.grab_keyboard == nil || xcb.grab_keyboard_reply == nil || xcb.ungrab_keyboard == nil { return }
	X11_GRAB_MODE_ASYNC :: 1
	if on {
		if reply := xcb.grab_keyboard_reply(x11c.c, xcb.grab_keyboard(x11c.c, 0, id, 0, X11_GRAB_MODE_ASYNC, X11_GRAB_MODE_ASYNC), nil); reply != nil { posix.free(reply) }
	} else {
		xcb.ungrab_keyboard(x11c.c, 0)
		xcb.flush(x11c.c)
	}
}

@(private)
x11_dnd_build_targets :: proc(d: Drag_Data) {
	x11c.dnd_source.targets = make([dynamic]Xcb_Atom)
	if len(d.files) > 0 || d.url != "" { append(&x11c.dnd_source.targets, x11c.mime_uri_list) }
	if d.text != "" || d.url != "" { append(&x11c.dnd_source.targets, x11c.utf8_string, XCB_ATOM_STRING) }
	if d.html != "" { append(&x11c.dnd_source.targets, x11c.mime_text_html) }
	if len(d.image) > 0 { append(&x11c.dnd_source.targets, x11c.mime_image_png) }
	for e in d.custom { append(&x11c.dnd_source.targets, x11_atom(e.mime)) }
}

@(private)
x11_dnd_own_selection :: proc(owner: Xcb_Window) {
	x11_set_selection_owner(x11c.xdnd_selection, owner)
	xcb.flush(x11c.c)
}

// The interactive source loop: pumps the X connection, tracks the pointer, and talks XDND to the toplevel under it.
// Returns the effect the target took. drag_start comes from a press and a move: the button's implicit grab brings the
// pointer's motion here wherever it goes, and the release, which goes on to the window as any other (the press would
// otherwise stay pressed).
@(private)
x11_dnd_source_loop :: proc(w: ^Window) -> Maybe(Drop_Effect) {
	s := &x11c.dnd_source
	heard := time.tick_now()   // the user or the target, last
	last_target: Xcb_Window = 0
	for drag_runs(s.phase) {
		ev := xcb.poll_for_event(x11c.c)
		if ev != nil {
			b := ([^]u8)(ev)
			type := ev.response_type & X11_RESPONSE_TYPE_MASK
			switch type {
			case XCB_MOTION_NOTIFY:
				if s.phase != .Tracking { break }
				heard = time.tick_now()
				rootx := int(i16(u16(b[20]) | u16(b[21]) << 8))
				rooty := int(i16(u16(b[22]) | u16(b[23]) << 8))
				x11_drag_image_move(rootx, rooty)
				tgt, dest := x11_window_at(rootx, rooty)
				if tgt != last_target {
					if last_target != 0 { x11_send_source_leave(last_target) }
					s.dest = dest
					if tgt != 0 { x11_send_source_enter(tgt) }
					last_target = tgt
					s.target = tgt
				}
				if tgt != 0 { x11_send_source_position(tgt, rootx, rooty) }
			case XCB_BUTTON_RELEASE:
				x11_handle_event(w, ev)
				if b[1] == s.button && s.phase == .Tracking {
					heard = time.tick_now()
					if s.target != 0 && s.accepted {
						x11_send_source_drop(s.target)
						s.phase = .Dropped   // XdndFinished ends it
					} else {
						s.phase = .Abandoned
					}
				}
			case XCB_KEY_PRESS:
				if x11_key_is_escape(b[1]) {
					if s.phase == .Tracking { s.phase = .Abandoned }
				} else {
					x11_handle_event(w, ev)
				}
			case XCB_CLIENT_MESSAGE:
				mtype := Xcb_Atom(get_u32(b[8:]))
				from := Xcb_Window(get_u32(b[12:]))   // (a late word of the target the pointer left says nothing of this one)
				if mtype == x11c.xdnd_status {
					if from == s.target {
						s.accepted = get_u32(b[16:]) & 1 != 0
						s.answer = Xcb_Atom(get_u32(b[28:]))
					}
				} else if mtype == x11c.xdnd_finished {
					if from == s.target {
						s.accepted = get_u32(b[16:]) & 1 != 0
						if a := Xcb_Atom(get_u32(b[20:])); a != 0 { s.answer = a }
						s.phase = .Finished
					}
				} else {
					x11_handle_event(w, ev)   // the drag over this app's own window: its drop target's messages
				}
			case:
				x11_handle_event(w, ev)   // keep the window responsive (repaints, requests for the selection)
			}
			posix.free(ev)
		}
		if drag_runs(s.phase) && time.duration_milliseconds(time.tick_since(heard)) > drag_limit_ms(s.phase, w) {
			if s.phase == .Dropped { s.target = 0 }   // (it had its XdndDrop: no leave comes after)
			s.phase = .Abandoned
		}
		if ev == nil {
			x11_check_link()
			if x11c.link != .Connected { s.phase = .Abandoned; break }
			poll_fd_wait(x11c.fd, XDND_SOURCE_POLL_MS)
		}
	}
	if s.phase == .Abandoned {
		if s.target != 0 { x11_send_source_leave(s.target) }
		return nil
	}
	if !s.accepted { return nil }
	switch s.answer {
	case x11c.xdnd_action_move: return .Move
	case x11c.xdnd_action_link: return .Link
	}
	return .Copy
}

// Serves a SelectionRequest for XdndSelection while a drag is running: write the asked flavour of the drag data.
@(private)
x11_dnd_serve_source_request :: proc(b: [^]u8) {
	// xcb_selection_request_event_t: time at [4], owner at [8], then these
	requestor := Xcb_Window(get_u32(b[12:]))
	selection := Xcb_Atom(get_u32(b[16:]))
	target := Xcb_Atom(get_u32(b[20:]))
	property := Xcb_Atom(get_u32(b[24:]))
	if property == 0 { property = target }
	data := x11_dnd_src_bytes(target)
	ok := data != nil
	if ok {
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, target, X11_FORMAT_8, u32(len(data)), len(data) > 0 ? raw_data(data) : nil)
	}
	ev: [X11_EVENT_BYTES]u8
	ev[0] = XCB_SELECTION_NOTIFY
	put_u32(ev[8:], u32(requestor))
	put_u32(ev[12:], u32(selection))
	put_u32(ev[16:], u32(target))
	put_u32(ev[20:], u32(ok ? property : 0))
	xcb.send_event(x11c.c, 0, requestor, 0, &ev[0])
	xcb.flush(x11c.c)
}

@(private)
x11_dnd_src_bytes :: proc(target: Xcb_Atom) -> []u8 {
	d := &x11c.dnd_source.data
	switch target {
	case x11c.utf8_string, XCB_ATOM_STRING, x11c.atom_text:
		return transmute([]u8)d.text
	case x11c.mime_text_html:
		return transmute([]u8)d.html
	case x11c.mime_image_png:
		return d.image
	case x11c.mime_uri_list:
		b := strings.builder_make(context.temp_allocator)
		for p in d.files { strings.write_string(&b, file_uri(p)); strings.write_string(&b, "\r\n") }
		if d.url != "" { strings.write_string(&b, d.url); strings.write_string(&b, "\r\n") }
		return transmute([]u8)strings.to_string(b)
	}
	for e in d.custom { if x11_atom(e.mime) == target { return transmute([]u8)e.data } }
	return nil
}

@(private)
x11_send_source_enter :: proc(target: Xcb_Window) {
	flags: u32 = u32(XDND_VERSION) << XDND_VERSION_SHIFT
	t := x11c.dnd_source.targets
	if len(t) > XDND_INLINE_TYPES { flags |= 1 }
	data := [X11_CLIENT_MESSAGE_WORDS]u32{
		u32(x11c.dnd_source.window), flags,
		len(t) > 0 ? u32(t[0]) : 0, len(t) > 1 ? u32(t[1]) : 0, len(t) > 2 ? u32(t[2]) : 0,
	}
	x11_send_client_message(x11c.dnd_source.dest, x11c.xdnd_enter, data, target)
}

@(private)
x11_send_source_position :: proc(target: Xcb_Window, rootx, rooty: int) {
	data := [X11_CLIENT_MESSAGE_WORDS]u32{u32(x11c.dnd_source.window), 0, u32(u16(rootx)) << 16 | u32(u16(rooty)), 0, u32(x11c.dnd_source.action)}
	x11_send_client_message(x11c.dnd_source.dest, x11c.xdnd_position, data, target)
}

@(private)
x11_send_source_leave :: proc(target: Xcb_Window) {
	data := [X11_CLIENT_MESSAGE_WORDS]u32{u32(x11c.dnd_source.window), 0, 0, 0, 0}
	x11_send_client_message(x11c.dnd_source.dest, x11c.xdnd_leave, data, target)
	x11c.dnd_source.accepted = false
}

@(private)
x11_send_source_drop :: proc(target: Xcb_Window) {
	data := [X11_CLIENT_MESSAGE_WORDS]u32{u32(x11c.dnd_source.window), 0, 0, 0, 0}
	x11_send_client_message(x11c.dnd_source.dest, x11c.xdnd_drop, data, target)
}

@(private)
x11_send_client_message :: proc(dest: Xcb_Window, mtype: Xcb_Atom, data: [X11_CLIENT_MESSAGE_WORDS]u32, window: Xcb_Window = 0) {
	ev: [X11_EVENT_BYTES]u8
	ev[0] = XCB_CLIENT_MESSAGE
	ev[1] = X11_FORMAT_32
	put_u32(ev[4:], u32(window != 0 ? window : dest))   // (through a proxy: sent to it, naming the target)
	put_u32(ev[8:], u32(mtype))
	for i in 0 ..< X11_CLIENT_MESSAGE_WORDS { put_u32(ev[12 + i * 4:], data[i]) }
	xcb.send_event(x11c.c, 0, dest, 0, &ev[0])
	xcb.flush(x11c.c)
}

// The XDND-aware window under a point of the root, down from the root through the children under the point, and where
// its messages go: itself, or the window its XdndProxy names when that one says so too and is aware. 0: none.
@(private)
x11_window_at :: proc(rootx, rooty: int) -> (target, dest: Xcb_Window) {
	cur := x11c.screen.root
	for _ in 0 ..< XDND_WINDOW_DEPTH_MAX {
		_, child, ok := x11_translate(x11c.screen.root, cur, rootx, rooty)
		if !ok || child == 0 { return 0, 0 }
		if proxy := x11_window_prop(child, x11c.xdnd_proxy); proxy != 0 && x11_window_prop(proxy, x11c.xdnd_proxy) == proxy && x11_is_xdnd_aware(proxy) {
			return child, proxy
		}
		if x11_is_xdnd_aware(child) { return child, child }
		cur = child
	}
	return 0, 0
}

// A window property holding a window (0: none).
@(private)
x11_window_prop :: proc(window: Xcb_Window, prop: Xcb_Atom) -> Xcb_Window {
	reply := xcb.get_property_reply(x11c.c, xcb.get_property(x11c.c, 0, window, prop, 0, 0, 1), nil)
	if reply == nil { return 0 }
	defer posix.free(reply)
	if xcb.get_property_value_length(reply) < size_of(u32) { return 0 }
	return (^Xcb_Window)(xcb.get_property_value(reply))^
}

// An atom's name (temporary allocator). xcb_get_atom_name.
@(private)
x11_atom_name :: proc(atom: Xcb_Atom) -> string {
	if xcb.get_atom_name == nil || xcb.get_atom_name_reply == nil || xcb.get_atom_name_name == nil || xcb.get_atom_name_name_length == nil { return "" }
	reply := xcb.get_atom_name_reply(x11c.c, xcb.get_atom_name(x11c.c, atom), nil)
	if reply == nil { return "" }
	defer posix.free(reply)
	return strings.clone(string(xcb.get_atom_name_name(reply)[:xcb.get_atom_name_name_length(reply)]), context.temp_allocator)
}

@(private)
x11_is_xdnd_aware :: proc(window: Xcb_Window) -> bool {
	cookie := xcb.get_property(x11c.c, 0, window, x11c.xdnd_aware, XCB_ATOM_ATOM, 0, 1)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return false }
	defer posix.free(reply)
	return xcb.get_property_value_length(reply) > 0
}

// A point of the root in the window's client pixels.
@(private)
x11_root_to_client :: proc(w: ^Window, rootx, rooty: int) -> [2]f32 {
	if p, _, ok := x11_translate(x11c.screen.root, x11_state(w).id, rootx, rooty); ok { return {f32(p.x), f32(p.y)} }
	return {f32(rootx), f32(rooty)}
}

////////////////////////////////
// the picture of a drag: X has no drag image of the system, the source shows a window of its own that follows the pointer

@(private)
X11_Drag_Image :: struct {
	window:  Xcb_Window,
	pixmap:  u32,
	colormap: Xcb_Colormap,   // made for its visual (0: the screen's)
	mapped:  bool,
	through: bool,     // the pointer passes through it (XFIXES); else it is kept beside the pointer
	size:    [2]int,
	offset:  [2]int,
}

// Bindings the rest of the backend does not need.
@(private = "file")
X11_Image_Lib :: struct {
	allowed_depths: proc "c" (s: ^Xcb_Screen) -> X11_Depth_Iterator,
	depth_next:     proc "c" (it: ^X11_Depth_Iterator),
	depth_visuals:  proc "c" (d: rawptr) -> [^]X11_Visual,
	depth_visuals_len: proc "c" (d: rawptr) -> i32,
	create_pixmap:  proc "c" (c: Xcb_Connection, depth: u8, pid: u32, drawable: Xcb_Window, w, h: u16) -> Xcb_Void_Cookie,
	free_pixmap:    proc "c" (c: Xcb_Connection, pid: u32) -> Xcb_Void_Cookie,
	create_gc:      proc "c" (c: Xcb_Connection, gc: u32, drawable: u32, mask: u32, values: rawptr) -> Xcb_Void_Cookie,
	free_gc:        proc "c" (c: Xcb_Connection, gc: u32) -> Xcb_Void_Cookie,
	put_image:      proc "c" (c: Xcb_Connection, format: u8, drawable: u32, gc: u32, w, h: u16, x, y: i16, left_pad, depth: u8, len: u32, data: rawptr) -> Xcb_Void_Cookie,
}
@(private = "file") X11_Depth_Iterator :: struct { data: rawptr, rem, index: i32 }
@(private = "file") X11_Visual :: struct { id: u32, class, bits: u8, entries: u16, r, g, b: u32, pad: [4]u8 }
// (of this thread: with its connection)
@(private = "file", thread_local) x11_image: X11_Image_Lib

// The first visual of 32 bits (a compositor blends its alpha), 0 when the screen has none.
@(private = "file")
x11_argb_visual :: proc() -> u32 {
	it := x11_image.allowed_depths(x11c.screen)
	for it.rem > 0 {
		if (^u8)(it.data)^ == X11_ARGB_DEPTH {
			visuals := x11_image.depth_visuals(it.data)
			for v in visuals[:x11_image.depth_visuals_len(it.data)] { if v.class == XCB_VISUAL_CLASS_TRUE_COLOR { return v.id } }
		}
		x11_image.depth_next(&it)
	}
	return 0
}

// Makes the window of the picture (premultiplied BGRA in a pixmap that is its background), not yet shown: it appears at
// the first move. d.image_* says what the system shows, as drag_image_held does on Windows.
@(private = "file")
x11_drag_image_make :: proc(w: ^Window, img: Drag_Image) {
	if !drag_image_valid(img) { return }
	h := xcb.handle
	x11_image.allowed_depths = auto_cast lib_sym(h, "xcb_screen_allowed_depths_iterator")
	x11_image.depth_next     = auto_cast lib_sym(h, "xcb_depth_next")
	x11_image.depth_visuals  = auto_cast lib_sym(h, "xcb_depth_visuals")
	x11_image.depth_visuals_len = auto_cast lib_sym(h, "xcb_depth_visuals_length")
	x11_image.create_pixmap  = auto_cast lib_sym(h, "xcb_create_pixmap")
	x11_image.free_pixmap    = auto_cast lib_sym(h, "xcb_free_pixmap")
	x11_image.create_gc      = auto_cast lib_sym(h, "xcb_create_gc")
	x11_image.free_gc        = auto_cast lib_sym(h, "xcb_free_gc")
	x11_image.put_image      = auto_cast lib_sym(h, "xcb_put_image")
	if x11_image.allowed_depths == nil || x11_image.depth_next == nil || x11_image.depth_visuals == nil || x11_image.create_pixmap == nil || x11_image.create_gc == nil || x11_image.put_image == nil { return }

	fit, px := drag_image_bgra(img)

	root := x11c.screen.root
	depth: u8 = x11c.screen.root_depth
	visual := x11c.screen.root_visual
	colormap := u32(x11c.screen.default_colormap)
	made_colormap: Xcb_Colormap
	if argb := x11_argb_visual(); argb != 0 {
		depth, visual = X11_ARGB_DEPTH, argb
		colormap = xcb.generate_id(x11c.c)
		made_colormap = Xcb_Colormap(colormap)
		xcb.create_colormap(x11c.c, 0, made_colormap, root, visual)
	}
	pixmap := xcb.generate_id(x11c.c)
	x11_image.create_pixmap(x11c.c, depth, pixmap, root, u16(fit.size.x), u16(fit.size.y))
	gc := xcb.generate_id(x11c.c)
	x11_image.create_gc(x11c.c, gc, pixmap, 0, nil)
	stride := fit.size.x * 4
	for y := 0; y < fit.size.y; y += X11_PUT_IMAGE_ROWS {
		rows := min(X11_PUT_IMAGE_ROWS, fit.size.y - y)
		x11_image.put_image(x11c.c, XCB_IMAGE_FORMAT_Z_PIXMAP, pixmap, gc, u16(fit.size.x), u16(rows), 0, i16(y), 0, depth, u32(rows * stride), raw_data(px[y * stride:]))
	}
	x11_image.free_gc(x11c.c, gc)

	id := Xcb_Window(xcb.generate_id(x11c.c))
	values := [4]u32{pixmap, 0, 1, colormap}   // in the order of their bits: background, border, override redirect, colormap
	xcb.create_window(x11c.c, depth, id, root, 0, 0, u16(fit.size.x), u16(fit.size.y), 0, XCB_WINDOW_CLASS_INPUT_OUTPUT, visual,
		XCB_CW_BACK_PIXMAP | XCB_CW_BORDER_PIXEL | XCB_CW_OVERRIDE_REDIRECT | XCB_CW_COLORMAP, &values[0])
	x11c.dnd_source.image = {window = id, pixmap = pixmap, colormap = made_colormap, through = x11_window_input_through(id), size = fit.size, offset = fit.offset}
	xcb.flush(x11c.c)
	d := dnd_state(w)
	d.image_held, d.image_size, d.image_offset = true, fit.size, fit.offset
}

// The picture with its hot spot under the pointer (or just beside it, when the pointer cannot pass through it).
@(private = "file")
x11_drag_image_move :: proc(rootx, rooty: int) {
	im := &x11c.dnd_source.image
	if im.window == 0 { return }
	x, y := rootx - im.offset.x, rooty - im.offset.y
	if !im.through && rootx >= x && rooty >= y && rootx < x + im.size.x && rooty < y + im.size.y { x, y = rootx + 1, rooty + 1 }
	values := [2]i32{i32(x), i32(y)}
	xcb.configure_window(x11c.c, im.window, XCB_CONFIG_WINDOW_X | XCB_CONFIG_WINDOW_Y, &values[0])
	if !im.mapped { xcb.map_window(x11c.c, im.window); im.mapped = true }
	xcb.flush(x11c.c)
}

@(private = "file")
x11_drag_image_free :: proc() {
	im := &x11c.dnd_source.image
	if im.window == 0 { return }
	xcb.destroy_window(x11c.c, im.window)
	if x11_image.free_pixmap != nil { x11_image.free_pixmap(x11c.c, im.pixmap) }
	if im.colormap != 0 && xcb.free_colormap != nil { xcb.free_colormap(x11c.c, im.colormap) }
	xcb.flush(x11c.c)
	im^ = {}
}
