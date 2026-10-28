#+build linux
package platform

// Wayland drag and drop (dragdrop_linux.odin has the API, dragdrop.odin the types). Receiving goes through
// wl_data_device's drag events (enter / motion / drop), the offered MIME types gathered on the wl_data_offer, and a
// wl_data_offer.receive per flavour over a pipe. Sending makes a wl_data_source (the same listener as the clipboard
// owner, clipboard_wl_linux.odin) and wl_data_device.start_drag with the last pointer-button serial.
//
// The data of a drag is read lazily: on Drop we read each flavour the offer advertised into the window's Drag_Data,
// then the app reads drop_data(window).

import "core:strings"
import "core:time"
import "core:sys/posix"

// What this process is dragging now (drag_start), so the shared data-source send callback can feed it.
@(private)
Wl_Drag_Store :: struct {
	data:   Drag_Data,
	active: bool,
}
@(private) wl_drag: Wl_Drag_Store

////////////////////////////////
// receiving

// A drag entered a surface. Keep the offer and the window; the MIME types were gathered on the offer's `offer` events
// (wl_offer_new). Queue Drop_Enter once we have read the data shape (the types), with the data filled lazily at drop.
@(private)
wl_dnd_enter :: proc(serial: u32, surface: Wl_Proxy, x, y: f32, offer: Wl_Proxy) {
	w := window_of_surface(surface)
	if w == nil { return }
	wlc.dnd_offer = offer
	wlc.dnd_window = w
	wlc.dnd_enter_serial = serial
	wlc.dnd_x, wlc.dnd_y = x * w.dpi_scale, y * w.dpi_scale
	// take the MIME list the offer gathered (wl_pending_offer path)
	if offer == wl_pending_offer {
		wl_free_mimes(&wlc.dnd_mimes)
		wlc.dnd_mimes = wl_pending_offer_mimes
		wl_pending_offer_mimes = nil
		wl_pending_offer = nil
	}
	// accept the first type and set our preferred action so the compositor shows a cursor
	if offer != nil {
		if len(wlc.dnd_mimes) > 0 {
			c := strings.clone_to_cstring(wlc.dnd_mimes[0], context.temp_allocator)
			wl.proxy_marshal_flags(offer, WL_DATA_OFFER_ACCEPT, nil, wl.proxy_get_version(offer), 0, serial, c)
		}
		if wl.proxy_get_version(offer) >= 3 {
			wl.proxy_marshal_flags(offer, WL_DATA_OFFER_SET_ACTIONS, nil, wl.proxy_get_version(offer), 0,
				u32(WL_DND_ACTION_COPY | WL_DND_ACTION_MOVE), u32(WL_DND_ACTION_COPY))
		}
	}
	d := dnd_state(w)
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	d.allowed = {.Copy, .Move}
	d.over = true
	d.effect = nil
	deliver_drop(w, .Drop_Enter, {wlc.dnd_x, wlc.dnd_y})
	wl_push(w, {})   // nudge the loop so the queued event is delivered promptly
}

@(private)
wl_dnd_motion :: proc(x, y: f32) {
	w := wlc.dnd_window
	if w == nil { return }
	wlc.dnd_x, wlc.dnd_y = x * w.dpi_scale, y * w.dpi_scale
	deliver_drop(w, .Drop_Over, {wlc.dnd_x, wlc.dnd_y})
}

@(private)
wl_dnd_leave :: proc() {
	w := wlc.dnd_window
	if w != nil {
		d := w.dnd
		if d != nil { d.over = false }
		deliver_drop(w, .Drop_Leave, {wlc.dnd_x, wlc.dnd_y})
	}
	if wlc.dnd_offer != nil {
		wl.proxy_marshal_flags(wlc.dnd_offer, WL_DATA_OFFER_DESTROY, nil, wl.proxy_get_version(wlc.dnd_offer), WL_MARSHAL_FLAG_DESTROY)
		wlc.dnd_offer = nil
	}
	wl_free_mimes(&wlc.dnd_mimes)
	wlc.dnd_window = nil
}

@(private)
wl_dnd_drop :: proc() {
	w := wlc.dnd_window
	if w == nil { return }
	d := dnd_state(w)
	context.allocator = d.allocator
	// read each flavour the offer advertised into the Drag_Data
	drag_data_destroy(&d.data)
	d.data = wl_read_drag_data(wlc.dnd_offer, wlc.dnd_mimes[:], d.allocator)
	if wlc.dnd_offer != nil && wl.proxy_get_version(wlc.dnd_offer) >= 3 {
		wl.proxy_marshal_flags(wlc.dnd_offer, WL_DATA_OFFER_FINISH, nil, wl.proxy_get_version(wlc.dnd_offer), 0)
	}
	d.over = false
	deliver_drop(w, .Drop, {wlc.dnd_x, wlc.dnd_y})
	if wlc.dnd_offer != nil {
		wl.proxy_marshal_flags(wlc.dnd_offer, WL_DATA_OFFER_DESTROY, nil, wl.proxy_get_version(wlc.dnd_offer), WL_MARSHAL_FLAG_DESTROY)
		wlc.dnd_offer = nil
	}
	wl_free_mimes(&wlc.dnd_mimes)
	wlc.dnd_window = nil
}

// Reads every advertised flavour into a Drag_Data (over the offer's pipes).
@(private)
wl_read_drag_data :: proc(offer: Wl_Proxy, mimes: []string, allocator := context.allocator) -> (out: Drag_Data) {
	context.allocator = allocator
	if offer == nil { return }
	if wl_offer_has_mime(mimes, WL_MIME_URIS) {
		b := wl_offer_read(offer, WL_MIME_URIS, context.temp_allocator)
		for p in uri_list_to_paths(string(b), allocator) { append(&out.files, p) }
	}
	if wl_offer_has_mime(mimes, WL_MIME_HTML) {
		b := wl_offer_read(offer, WL_MIME_HTML, context.temp_allocator)
		out.html = clone_string(string(b))
	}
	for m in ([]string{WL_MIME_TEXT, WL_MIME_TEXT2}) {
		if wl_offer_has_mime(mimes, m) {
			b := wl_offer_read(offer, m, context.temp_allocator)
			out.text = clone_string(string(b))
			break
		}
	}
	if len(out.files) == 0 && wl_offer_has_mime(mimes, WL_MIME_PNG) {
		b := wl_offer_read(offer, WL_MIME_PNG, context.temp_allocator)
		if len(b) > 0 { out.image = make([]u8, len(b)); copy(out.image, b) }
	}
	// the app's own formats come through as their MIME types
	for m in mimes {
		if m == WL_MIME_TEXT || m == WL_MIME_TEXT2 || m == WL_MIME_HTML || m == WL_MIME_PNG || m == WL_MIME_URIS { continue }
		b := wl_offer_read(offer, m, context.temp_allocator)
		if len(b) > 0 { append(&out.custom, Drag_Entry{clone_string(m), clone_string(string(b))}) }
	}
	return
}

////////////////////////////////
// sending

// Writes one flavour of the active drag to the pipe fd (the data-source send callback routes here for wlc.dnd_source).
@(private)
wl_write_drag_flavour :: proc(fd: i32, mime: string) {
	d := &wl_drag.data
	switch mime {
	case WL_MIME_TEXT, WL_MIME_TEXT2: wl_fd_write_all(fd, transmute([]u8)d.text)
	case WL_MIME_HTML:                wl_fd_write_all(fd, transmute([]u8)d.html)
	case WL_MIME_PNG:                 wl_fd_write_all(fd, d.image)
	case WL_MIME_URIS:                wl_fd_write_all(fd, transmute([]u8)wl_drag_uris())
	case:
		for e in d.custom { if e.mime == mime { wl_fd_write_all(fd, transmute([]u8)e.data); break } }
	}
	posix.close(posix.FD(fd))
}

@(private)
wl_drag_uris :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for p in wl_drag.data.files {
		strings.write_string(&b, "file://")
		strings.write_string(&b, p)
		strings.write_string(&b, "\r\n")
	}
	if wl_drag.data.url != "" {
		strings.write_string(&b, wl_drag.data.url)
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}

// Runs a drag from `w`. Makes a wl_data_source offering the data's flavours, start_drag with the last button serial,
// and pumps the display until the source is cancelled or the drop completes. Returns the effect the target chose.
@(private)
wl_drag_start :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, image: Maybe(Drag_Image)) -> (effect: Maybe(Drop_Effect), ok: bool) {
	st := wl_state(w)
	if st == nil || wlc.data_device == nil || wlc.data_device_manager == nil { return nil, false }
	drag_data_destroy(&wl_drag.data)
	wl_drag.data = drag_data_clone(data)
	wl_drag.active = true
	src := wl.proxy_marshal_flags(wlc.data_device_manager, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
		wl.data_source_interface, wl.proxy_get_version(wlc.data_device_manager), 0, nil)
	if src == nil { return nil, false }
	wlc.dnd_source = src
	wlc.dnd_sending = true
	wl.proxy_add_listener(src, &data_source_listener, nil)
	for m in drag_data_mimes(data) { wl_source_offer(src, m) }
	if wl.proxy_get_version(src) >= 3 {
		act: u32 = 0
		if .Copy in allowed { act |= WL_DND_ACTION_COPY }
		if .Move in allowed { act |= WL_DND_ACTION_MOVE }
		wl.proxy_marshal_flags(src, WL_DATA_SOURCE_SET_ACTIONS, nil, wl.proxy_get_version(src), 0, act)
	}
	wl.proxy_marshal_flags(wlc.data_device, WL_DATA_DEVICE_START_DRAG, nil, wl.proxy_get_version(wlc.data_device), 0,
		src, st.surface, nil, wl_button_serial)
	wl.display_flush(wlc.display)
	// pump until the source is cancelled or finished (bounded; the compositor drives it)
	l := wayland_lib()
	deadline := time.tick_now()
	for wlc.dnd_source != nil {
		l.display_dispatch(wlc.display)
		if time.duration_milliseconds(time.tick_since(deadline)) > 60000 { break }
	}
	wlc.dnd_sending = false
	wl_drag.active = false
	eff := wl_dnd_source_action
	if eff & WL_DND_ACTION_MOVE != 0 { return .Move, true }
	if eff & WL_DND_ACTION_COPY != 0 { return .Copy, true }
	return nil, true
}

// The MIME types a Drag_Data offers (the app's own first, then the standard ones).
@(private)
drag_data_mimes :: proc(d: Drag_Data) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for e in d.custom { append(&out, e.mime) }
	if d.text != "" || d.url != "" { append(&out, WL_MIME_TEXT, WL_MIME_TEXT2) }
	if d.html != "" { append(&out, WL_MIME_HTML) }
	if len(d.files) > 0 || d.url != "" { append(&out, WL_MIME_URIS) }
	if len(d.image) > 0 { append(&out, WL_MIME_PNG) }
	return out[:]
}
