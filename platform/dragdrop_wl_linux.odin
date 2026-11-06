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

@(private = "file") WL_DND_ACTIONS_SINCE :: 3   // the version of the data device that has actions
@(private = "file") WL_DND_POLL_MS :: 100       // between two checks of the limit of a drag
@(private = "file") WL_BUFFER_DESTROY :: 0
@(private = "file") WL_DND_NOT_TOLD :: ~u32(0)  // wlc.dnd_told_action of a new offer

// What this thread's connection is dragging now (drag_start), so the shared data-source send callback can feed it.
@(private)
Wl_Drag_Store :: struct {
	data:  Drag_Data,
	phase: Drag_Phase,
}

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
	// take the MIME list the offer gathered (wlc.pending_offer path)
	if offer == wlc.pending_offer {
		wl_free_mimes(&wlc.dnd_mimes)
		wlc.dnd_mimes = wlc.pending_offer_mimes
		wlc.pending_offer_mimes = nil
		wlc.pending_offer = nil
	}
	// a window that is no drop target takes nothing: the compositor needs an accepted type for a drop to happen here
	if !wl_dnd_target(w) { return }
	d := dnd_state(w)
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	d.allowed = wlc.offer_actions != 0 ? wl_effects_of(wlc.offer_actions) : {.Copy, .Move}
	d.over = true
	d.effect = nil
	wlc.dnd_told_action = WL_DND_NOT_TOLD
	deliver_drop(w, .Drop_Enter, {wlc.dnd_x, wlc.dnd_y})
	wl_dnd_accept(w)
}

@(private = "file")
wl_effects_of :: proc(actions: u32) -> (out: Drop_Effects) {
	if actions & WL_DND_ACTION_COPY != 0 { out += {.Copy} }
	if actions & WL_DND_ACTION_MOVE != 0 { out += {.Move} }
	return
}

@(private = "file")
wl_actions_of :: proc(effects: Drop_Effects) -> (out: u32) {
	if .Copy in effects { out |= WL_DND_ACTION_COPY }
	if .Move in effects { out |= WL_DND_ACTION_MOVE }
	return
}

@(private = "file")
wl_dnd_target :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.enabled }

// Tells the compositor whether a drop here would be taken: the first type, or none as the app answers.
@(private = "file")
wl_dnd_accept :: proc(w: ^Window) {
	offer := wlc.dnd_offer
	if offer == nil { return }
	// the action wanted, each time the app's answer changes (the compositor shows it, and the source hears it)
	answer := dnd_answer(w)
	action: u32
	if e, ok := answer.?; ok { action = wl_actions_of({e}) }
	if action != wlc.dnd_told_action && wl.proxy_get_version(offer) >= WL_DND_ACTIONS_SINCE {
		wl.proxy_marshal_flags(offer, WL_DATA_OFFER_SET_ACTIONS, nil, wl.proxy_get_version(offer), 0, wl_actions_of(w.dnd.allowed), action)
		wlc.dnd_told_action = action
	}
	if answer != nil && len(wlc.dnd_mimes) > 0 {
		c := strings.clone_to_cstring(wlc.dnd_mimes[0], context.temp_allocator)
		wl.proxy_marshal_flags(offer, WL_DATA_OFFER_ACCEPT, nil, wl.proxy_get_version(offer), 0, wlc.dnd_enter_serial, c)
	} else {
		wl.proxy_marshal_flags(offer, WL_DATA_OFFER_ACCEPT, nil, wl.proxy_get_version(offer), 0, wlc.dnd_enter_serial, cstring(nil))
	}
}

@(private)
wl_dnd_motion :: proc(x, y: f32) {
	w := wlc.dnd_window
	if w == nil { return }
	wlc.dnd_x, wlc.dnd_y = x * w.dpi_scale, y * w.dpi_scale
	if !wl_dnd_target(w) { return }
	deliver_drop(w, .Drop_Over, {wlc.dnd_x, wlc.dnd_y})
	wl_dnd_accept(w)
}

@(private)
wl_dnd_leave :: proc() {
	if w := wlc.dnd_window; w != nil { drop_left(w, {wlc.dnd_x, wlc.dnd_y}) }
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
	if w == nil || !wl_dnd_target(w) { return }
	d := dnd_state(w)
	context.allocator = d.allocator
	// read each flavour the offer advertised into the Drag_Data
	drag_data_destroy(&d.data)
	// (the app's own drag: this thread would have to serve the pipe it reads)
	d.data = wlc.drag.phase != .Idle ? drag_data_clone(wlc.drag.data) : wl_read_drag_data(wlc.dnd_offer, wlc.dnd_mimes[:], d.allocator)
	if wlc.dnd_offer != nil && wl.proxy_get_version(wlc.dnd_offer) >= WL_DND_ACTIONS_SINCE {
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
	d := &wlc.drag.data
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
	for p in wlc.drag.data.files {
		strings.write_string(&b, file_uri(p))
		strings.write_string(&b, "\r\n")
	}
	if wlc.drag.data.url != "" {
		strings.write_string(&b, wlc.drag.data.url)
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
	src := wl.proxy_marshal_flags(wlc.data_device_manager, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
		wl.data_source_interface, wl.proxy_get_version(wlc.data_device_manager), 0, nil)
	if src == nil { return nil, false }
	drag_data_destroy(&wlc.drag.data)
	wlc.drag.data = drag_data_clone(data)
	wlc.drag.phase = .Tracking
	wlc.dnd_source_action = 0
	wlc.dnd_source = src
	wl.proxy_add_listener(src, &data_source_listener, nil)
	for m in drag_data_mimes(data) { wl_source_offer(src, m) }
	if wl.proxy_get_version(src) >= WL_DND_ACTIONS_SINCE {
		wl.proxy_marshal_flags(src, WL_DATA_SOURCE_SET_ACTIONS, nil, wl.proxy_get_version(src), 0, wl_actions_of(allowed))
	}
	// the picture: a surface the compositor moves with the pointer, its hot spot where the buffer is attached
	icon, icon_buffer: Wl_Proxy
	icon_offset: [2]int
	if img, has := image.?; has && drag_image_valid(img) {
		fit, bgra := drag_image_bgra(img)
		icon_buffer = wl_shm_buffer(fit.size, bgra)
		if icon_buffer != nil {
			icon = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
			icon_offset = fit.offset
			d := dnd_state(w)
			d.image_held, d.image_size, d.image_offset = true, fit.size, fit.offset
		}
	}
	defer {
		if icon != nil { wl.proxy_marshal_flags(icon, WL_SURFACE_DESTROY, nil, wl.proxy_get_version(icon), WL_MARSHAL_FLAG_DESTROY) }
		if icon_buffer != nil { wl.proxy_marshal_flags(icon_buffer, WL_BUFFER_DESTROY, nil, wl.proxy_get_version(icon_buffer), WL_MARSHAL_FLAG_DESTROY) }
		wl.display_flush(wlc.display)
	}
	wl.proxy_marshal_flags(wlc.data_device, WL_DATA_DEVICE_START_DRAG, nil, wl.proxy_get_version(wlc.data_device), 0,
		src, st.surface, icon, wlc.button_serial)
	if icon != nil {
		wl.proxy_marshal_flags(icon, WL_SURFACE_ATTACH, nil, wl.proxy_get_version(icon), 0, icon_buffer, i32(-icon_offset.x), i32(-icon_offset.y))
		wl.proxy_marshal_flags(icon, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(icon), 0)
	}
	wl.display_flush(wlc.display)
	// pump until the source is cancelled or finished. The compositor drives it, however long the user holds the button:
	// the limit is the target's, once it has the drop
	dropped_at: time.Tick
	for drag_runs(wlc.drag.phase) {
		if wlc.drag.phase == .Dropped {
			if dropped_at == {} { dropped_at = time.tick_now() }
			if time.duration_milliseconds(time.tick_since(dropped_at)) > drag_limit_ms(.Dropped, w) { wl_drag_given_up() }
		}
		if wlc.link != .Connected { wl_drag_given_up(); break }
		poll_fd_wait(wlc.fd, WL_DND_POLL_MS)
		wl_read_available()
	}
	wlc.drag.phase = .Idle
	// the compositor keeps the pointer during a drag: the release of the press that began it never comes to the window
	buttons_released(w, wlc.pointer_pos, wl_mods())
	eff := wlc.dnd_source_action
	if eff & WL_DND_ACTION_MOVE != 0 { return .Move, true }
	if eff & WL_DND_ACTION_COPY != 0 { return .Copy, true }
	return nil, true
}

@(private = "file")
wl_drag_given_up :: proc() {
	if wlc.dnd_source != nil { wl_data_source_destroy(wlc.dnd_source); wlc.dnd_source = nil }
	wlc.dnd_source_action = 0
	wlc.drag.phase = .Abandoned
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
