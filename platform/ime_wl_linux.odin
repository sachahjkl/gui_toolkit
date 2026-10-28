#+build linux
package platform

// Wayland input method through zwp_text_input_v3 (ime.odin has the neutral API). The text-input object is made per
// seat (window_wl_linux.odin); enabling it tells the compositor this window wants composition. The compositor sends
// preedit_string (the marked text) and commit_string (the text to insert) between a `done` that applies them: on
// `done` we push the committed text as .Text events (rune by rune) and keep the preedit for the app to draw.

import "core:strings"
import "core:unicode/utf8"

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
	delete(wlc.pending_preedit)
	wlc.pending_preedit = text != nil ? strings.clone(string(text)) : ""
	wlc.preedit_cursor = int(cursor_begin < 0 ? 0 : cursor_begin)
}
@(private)
ti_commit :: proc "c" (data: rawptr, ti: Wl_Proxy, text: cstring) {
	context = wl_ctx_real()
	delete(wlc.pending_commit)
	wlc.pending_commit = text != nil ? strings.clone(string(text)) : ""
}
@(private)
ti_delete :: proc "c" (data: rawptr, ti: Wl_Proxy, before, after: u32) {
	// a backspace of surrounding text the IME asks for: send it as Backspace key presses (best effort). The app's text
	// field handles the composition replacement when it draws the committed string.
	context = wl_ctx_real()
	w := wlc.ti_window
	if w == nil { return }
	for _ in 0 ..< before {
		wl_push(w, {kind = .Key_Press, key = .Backspace})
		wl_push(w, {kind = .Key_Release, key = .Backspace})
	}
}
@(private)
ti_done :: proc "c" (data: rawptr, ti: Wl_Proxy, serial: u32) {
	context = wl_ctx_real()
	w := wlc.ti_window
	// apply the commit: push each rune as a .Text event (the same path as a typed character)
	if wlc.pending_commit != "" && w != nil {
		for r in wlc.pending_commit {
			if r >= 32 && r != 127 { wl_push(w, {kind = .Text, text = r}) }
		}
	}
	delete(wlc.pending_commit); wlc.pending_commit = ""
	// apply the preedit for the app to draw
	if wlc.preedit != wlc.pending_preedit {
		delete(wlc.preedit)
		wlc.preedit = strings.clone(wlc.pending_preedit)
		wlc.preedit_dirty = true
	}
	delete(wlc.pending_preedit); wlc.pending_preedit = ""
	if w != nil { w.paint_requested = true }
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
		delete(wlc.preedit); wlc.preedit = ""; wlc.preedit_dirty = true
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
	s := w.dpi_scale > 0 ? w.dpi_scale : 1
	wl.proxy_marshal_flags(wlc.text_input, ZWP_TI_SET_CURSOR_RECTANGLE, nil, wl.proxy_get_version(wlc.text_input), 0,
		i32(f32(x) / s), i32(f32(y) / s), i32(f32(width) / s), i32(f32(max(height, 1)) / s))
	wl_ti_commit_state()
}

@(private)
wl_ime_preedit :: proc(w: ^Window) -> (text: string, cursor: int) {
	return wlc.preedit, wlc.preedit_cursor
}

@(private)
wl_ime_preedit_changed :: proc(w: ^Window) -> bool {
	r := wlc.preedit_dirty
	wlc.preedit_dirty = false
	return r
}

_ :: utf8
