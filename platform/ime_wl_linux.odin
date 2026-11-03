#+build linux
package platform

// Wayland input method through zwp_text_input_v3 (ime.odin has the neutral API). The text-input object is made per
// seat (window_wl_linux.odin); enabling it tells the compositor this window wants composition. The compositor sends
// preedit_string (the marked text), commit_string (the text to insert) and delete_surrounding_text between a `done` that
// applies them: Ime_Compose (ime.odin) keeps them and makes the events; the listeners only feed it.

@(private)
Text_Input_Listener :: struct {
	enter:                   proc "c" (data: rawptr, ti: Wl_Proxy, surface: Wl_Proxy),
	leave:                   proc "c" (data: rawptr, ti: Wl_Proxy, surface: Wl_Proxy),
	preedit_string:          proc "c" (data: rawptr, ti: Wl_Proxy, text: cstring, cursor_begin, cursor_end: i32),
	commit_string:           proc "c" (data: rawptr, ti: Wl_Proxy, text: cstring),
	delete_surrounding_text: proc "c" (data: rawptr, ti: Wl_Proxy, before, after: u32),
	done:                    proc "c" (data: rawptr, ti: Wl_Proxy, serial: u32),
}
@(private) text_input_listener := Text_Input_Listener{ti_enter, ti_leave, ti_preedit, ti_commit, ti_delete, ti_done}

@(private)
ti_enter :: proc "c" (data: rawptr, ti: Wl_Proxy, surface: Wl_Proxy) {
	context = wl_ctx_real()
	wlc.ti_window = window_of_surface(surface)
	if wlc.ti_enabled { wl_ti_enable() }
}
@(private)
ti_leave :: proc "c" (data: rawptr, ti: Wl_Proxy, surface: Wl_Proxy) {
	context = wl_ctx_real()
	wlc.ti_window = nil
}
@(private)
ti_preedit :: proc "c" (data: rawptr, ti: Wl_Proxy, text: cstring, cursor_begin, cursor_end: i32) {
	context = wl_ctx_real()
	ime_compose_preedit(&wlc.ime, text != nil ? string(text) : "", int(cursor_begin))
}
@(private)
ti_commit :: proc "c" (data: rawptr, ti: Wl_Proxy, text: cstring) {
	context = wl_ctx_real()
	ime_compose_commit(&wlc.ime, text != nil ? string(text) : "")
}
@(private)
ti_delete :: proc "c" (data: rawptr, ti: Wl_Proxy, before, after: u32) {
	context = wl_ctx_real()
	ime_compose_delete(&wlc.ime, int(before))
}
@(private)
ti_done :: proc "c" (data: rawptr, ti: Wl_Proxy, serial: u32) {
	context = wl_ctx_real()
	evs := make([dynamic]Event, context.temp_allocator)
	ime_compose_done(&wlc.ime, &evs)
	w := wlc.ti_window
	if w == nil { return }
	for e in evs { wl_push(w, e) }
	w.paint_requested = true
}

////////////////////////////////
// the Wayland IME entry points (ime_linux.odin dispatches to these)

@(private)
wl_ime_set_enabled :: proc(w: ^Window, on: bool) {
	if w == nil || wlc.text_input == nil { return }
	wlc.ti_enabled = on
	if on {
		wl_ti_enable()
	} else {
		wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_DISABLE, nil, wl.proxy_get_version(wlc.text_input), 0)
		wl_ti_commit_state()
		ime_compose_reset(&wlc.ime)
	}
}

@(private)
wl_ti_enable :: proc() {
	if wlc.text_input == nil { return }
	wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_ENABLE, nil, wl.proxy_get_version(wlc.text_input), 0)
	// content type: normal text, no hints (0, 0)
	wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_SET_CONTENT_TYPE, nil, wl.proxy_get_version(wlc.text_input), 0, u32(0), u32(0))
	wl_ti_commit_state()
}

@(private)
wl_ti_commit_state :: proc() {
	if wlc.text_input == nil { return }
	wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_COMMIT, nil, wl.proxy_get_version(wlc.text_input), 0)
	wl.display_flush(wlc.display)
}

@(private)
wl_ime_set_cursor_rect :: proc(w: ^Window, x, y, width, height: int) {
	if w == nil || wlc.text_input == nil || !wlc.ti_enabled { return }
	// the compositor wants surface-local (logical) coordinates; our pixels are physical
	r := ime_cursor_rect_logical(x, y, width, height, w.dpi_scale)
	wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_SET_CURSOR_RECTANGLE, nil, wl.proxy_get_version(wlc.text_input), 0, r[0], r[1], r[2], r[3])
	wl_ti_commit_state()
}

@(private)
wl_ime_preedit :: proc(w: ^Window) -> (text: string, cursor: int) {
	return wlc.ime.preedit, wlc.ime.cursor
}

@(private)
wl_ime_preedit_changed :: proc(w: ^Window) -> bool {
	return ime_compose_take_changed(&wlc.ime)
}

