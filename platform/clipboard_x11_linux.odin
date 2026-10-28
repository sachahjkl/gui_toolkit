#+build linux
package platform

// The rich X11 clipboard: owning CLIPBOARD with every flavour the store holds and answering SelectionRequest for each
// (TARGETS, the MIME targets text/html, image/png, text/uri-list, UTF8_STRING / STRING / TEXT, TIMESTAMP, MULTIPLE),
// with INCR for a payload too large for a single property (a pasted image). The plain-text path in
// window_x11_linux.odin stays; this adds the flavours and the protocol niceties the spec and real clients expect.
//
// Reading a flavour another client owns (x11_selection_read) uses ConvertSelection to a scratch property and reads it
// back, following an INCR hand-off when the owner streams the data in chunks.

import "core:strings"
import "core:time"
import "core:sys/posix"

// The largest property we write in one go before switching to INCR (well under the server's maximum request length).
@(private) X11_INCR_THRESHOLD :: 128 * 1024

// An in-progress INCR transfer we are sending to a requestor: the bytes left and the property / window to post on.
@(private)
X11_Incr_Send :: struct {
	requestor: Xcb_Window,
	property:  Xcb_Atom,
	target:    Xcb_Atom,
	data:      []u8,
	offset:    int,
	active:    bool,
}
@(private) x11_incr_sends: [dynamic]X11_Incr_Send

// Own CLIPBOARD and advertise the rich targets. The store's flavours (clipboard_linux.odin) are read at serve time, so
// this only needs to claim ownership; `text` keeps the plain-text fast path working.
@(private)
x11_clipboard_own_rich :: proc(w: ^Window, text: string) {
	st := x11_state(w)
	if st == nil { return }
	delete(x11c.clip_text)
	x11c.clip_text = strings.clone(text)
	x11c.clip_owner = st.id
	x11_set_selection_owner(x11c.clipboard, st.id)
	// also own PRIMARY with the text (middle-click paste of a selection)
	x11_set_selection_owner(x11c.primary, st.id)
	xcb.flush(x11c.c)
}

// The list of target atoms we offer, from the store's current formats.
@(private)
x11_offer_targets :: proc() -> []Xcb_Atom {
	fmts := clipboard_formats()
	list := make([dynamic]Xcb_Atom, context.temp_allocator)
	append(&list, x11c.targets, x11c.atom_timestamp, x11c.atom_multiple)
	if .Text in fmts { append(&list, x11c.utf8_string, XCB_ATOM_STRING, x11c.atom_text) }
	if .Html in fmts { append(&list, x11c.mime_text_html) }
	if .Image in fmts { append(&list, x11c.mime_image_png) }
	if .Files in fmts { append(&list, x11c.mime_uri_list) }
	return list[:]
}

// The bytes for a target atom (temp allocator), nil when we do not offer it. Reads the store under its lock.
@(private)
x11_bytes_for_target :: proc(target: Xcb_Atom) -> (data: []u8, ok: bool) {
	switch target {
	case x11c.utf8_string, XCB_ATOM_STRING, x11c.atom_text:
		return transmute([]u8)strings.clone(x11c.clip_text, context.temp_allocator), true
	case x11c.mime_text_html:
		sync_lock_clip(); defer sync_unlock_clip()
		return transmute([]u8)strings.clone(clip_html_locked(), context.temp_allocator), clip_html_locked() != ""
	case x11c.mime_image_png:
		sync_lock_clip(); defer sync_unlock_clip()
		png := clip_png_locked()
		if len(png) == 0 { return nil, false }
		out := make([]u8, len(png), context.temp_allocator); copy(out, png); return out, true
	case x11c.mime_uri_list:
		sync_lock_clip(); defer sync_unlock_clip()
		return transmute([]u8)clip_uris_locked(), true
	}
	return nil, false
}

// Serve one SelectionRequest (called from the window event handler). Handles TARGETS, TIMESTAMP, MULTIPLE and the data
// targets, and starts an INCR transfer for a large payload.
@(private)
x11_serve_selection_request :: proc(w: ^Window, b: [^]u8) {
	requestor := Xcb_Window(get_u32(b[16:]))
	selection := Xcb_Atom(get_u32(b[20:]))
	target := Xcb_Atom(get_u32(b[24:]))
	property := Xcb_Atom(get_u32(b[28:]))
	if property == 0 { property = target }   // obsolete clients leave property None: use the target atom
	ok := x11_answer_target(requestor, target, property)
	ev: [32]u8
	ev[0] = XCB_SELECTION_NOTIFY
	put_u32(ev[8:], u32(requestor))
	put_u32(ev[12:], u32(selection))
	put_u32(ev[16:], u32(target))
	put_u32(ev[20:], u32(ok ? property : 0))
	xcb.send_event(x11c.c, 0, requestor, 0, &ev[0])
	xcb.flush(x11c.c)
}

// Writes the answer for one target into `property` on `requestor`. Returns whether it was served (the property was set).
@(private)
x11_answer_target :: proc(requestor: Xcb_Window, target, property: Xcb_Atom) -> bool {
	if target == x11c.targets {
		list := x11_offer_targets()
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, XCB_ATOM_ATOM, 32, u32(len(list)), raw_data(list))
		return true
	}
	if target == x11c.atom_timestamp {
		t: u32 = 0
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, x11c.atom_timestamp, 32, 1, &t)
		return true
	}
	if target == x11c.atom_multiple {
		return x11_answer_multiple(requestor, property)
	}
	data, has := x11_bytes_for_target(target)
	if !has { return false }
	if len(data) > X11_INCR_THRESHOLD {
		x11_start_incr(requestor, property, target, data)
		return true
	}
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, target, 8, u32(len(data)), len(data) > 0 ? raw_data(data) : nil)
	return true
}

// MULTIPLE: the requestor's `property` holds an array of (target, property) atom pairs; serve each in place and write
// 0 into the pairs we refuse.
@(private)
x11_answer_multiple :: proc(requestor: Xcb_Window, property: Xcb_Atom) -> bool {
	cookie := xcb.get_property(x11c.c, 0, requestor, property, x11c.atom_pair, 0, 1 << 16)
	reply := xcb.get_property_reply(x11c.c, cookie, nil)
	if reply == nil { return false }
	defer posix.free(reply)
	n := int(xcb.get_property_value_length(reply)) / 4
	if n < 2 { return false }
	atoms := ([^]u32)(xcb.get_property_value(reply))
	changed := false
	for i := 0; i + 1 < n; i += 2 {
		t := Xcb_Atom(atoms[i])
		p := Xcb_Atom(atoms[i + 1])
		if p == 0 { continue }
		if !x11_answer_target(requestor, t, p) { atoms[i + 1] = 0; changed = true }
	}
	if changed {
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, x11c.atom_pair, 32, u32(n), atoms)
	}
	return true
}

// Starts an INCR transfer: tell the requestor the size (an INCR property), then stream the data in property-change
// steps as the requestor deletes the property (handled in x11_incr_on_property_delete). We must select
// PropertyChangeMask on the requestor to hear its deletes.
@(private)
x11_start_incr :: proc(requestor: Xcb_Window, property, target: Xcb_Atom, data: []u8) {
	// listen for the requestor's property deletes
	mask := [1]u32{XCB_EVENT_MASK_PROPERTY_CHANGE}
	xcb.configure_window(x11c.c, requestor, 0, nil)   // no-op to keep XCB sequence ordering simple
	x11_change_window_attrs_event_mask(requestor, XCB_EVENT_MASK_PROPERTY_CHANGE)
	size := u32(len(data))
	xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, requestor, property, x11c.atom_incr, 32, 1, &size)
	// keep a copy that outlives the temp allocator
	buf := make([]u8, len(data))
	copy(buf, data)
	append(&x11_incr_sends, X11_Incr_Send{requestor = requestor, property = property, target = target, data = buf, offset = 0, active = true})
	xcb.flush(x11c.c)
	_ = mask
}

// The requestor deleted the INCR property: send the next chunk (an empty one ends the transfer). Called from the event
// handler on a PropertyNotify (state delete) for a requestor we stream to.
@(private)
x11_incr_on_property_delete :: proc(window: Xcb_Window, property: Xcb_Atom) {
	for &s, i in x11_incr_sends {
		if !s.active || s.requestor != window || s.property != property { continue }
		remaining := len(s.data) - s.offset
		chunk := min(remaining, X11_INCR_THRESHOLD)
		xcb.change_property(x11c.c, XCB_PROP_MODE_REPLACE, window, property, s.target, 8, u32(chunk), chunk > 0 ? raw_data(s.data[s.offset:]) : nil)
		s.offset += chunk
		xcb.flush(x11c.c)
		if chunk == 0 {   // the terminating empty property: transfer done
			delete(s.data)
			unordered_remove(&x11_incr_sends, i)
		}
		return
	}
}

////////////////////////////////
// reading a flavour another client owns

// Reads `target` (a MIME atom or UTF8_STRING) from `selection` (CLIPBOARD / PRIMARY) into bytes, following INCR. The
// window pumps its connection until the data arrives (bounded); the callers expect a synchronous read.
@(private)
x11_selection_read :: proc(w: ^Window, selection: Xcb_Atom, mime: string, allocator := context.allocator) -> []u8 {
	st := x11_state(w)
	if st == nil { return nil }
	target := x11_target_for_mime(mime)
	if target == 0 { return nil }
	clear(&st.paste_buf)
	st.paste_got = false
	st.paste_incr = false
	x11_convert_selection(st.id, selection, target, x11c.wren_selection)
	xcb.flush(x11c.c)
	deadline := time.tick_now()
	for i in 0 ..< 2000 {
		ev := xcb.poll_for_event(x11c.c)
		if ev != nil { x11_handle_event(w, ev); posix.free(ev); if st.paste_got && !st.paste_incr { break }; continue }
		if st.paste_got && !st.paste_incr { break }
		if time.duration_milliseconds(time.tick_since(deadline)) > 3000 { break }
		poll_fd_wait(x11c.fd, 20)
	}
	if len(st.paste_buf) == 0 { return nil }
	out := make([]u8, len(st.paste_buf), allocator)
	copy(out, st.paste_buf[:])
	return out
}

@(private)
x11_target_for_mime :: proc(mime: string) -> Xcb_Atom {
	switch mime {
	case "text/plain", "text/plain;charset=utf-8", "UTF8_STRING": return x11c.utf8_string
	case "text/html":     return x11c.mime_text_html
	case "image/png":     return x11c.mime_image_png
	case "text/uri-list": return x11c.mime_uri_list
	}
	return x11c.utf8_string
}

// Changes a window's event mask (to hear a requestor's INCR property deletes). A thin wrapper over the XCB request.
@(private)
x11_change_window_attrs_event_mask :: proc(window: Xcb_Window, mask: u32) {
	if x11_change_attrs == nil { x11_change_attrs = auto_cast lib_sym(xcb.handle, "xcb_change_window_attributes") }
	if x11_change_attrs != nil {
		v := [1]u32{mask}
		x11_change_attrs(x11c.c, window, XCB_CW_EVENT_MASK, &v[0])
	}
}
@(private) x11_change_attrs: proc "c" (c: Xcb_Connection, window: Xcb_Window, value_mask: u32, value_list: rawptr) -> Xcb_Void_Cookie
