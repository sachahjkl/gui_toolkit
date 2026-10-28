#+build linux
package platform

// The Linux IME dispatcher (ime.odin has the neutral API): routes to the Wayland text-input (ime_wl_linux.odin) or the
// X11 path. On X11 the compositing of dead keys and Compose sequences already happens in libxkbcommon
// (state_key_get_utf8 in window_x11_linux.odin), so committed text arrives as .Text events with no extra work; a full
// IME (ibus / fcitx over XIM or D-Bus) that shows a candidate window is the documented next step and would surface its
// preedit through the same ime_preedit path. So on X11 ime_set_enabled is a no-op that reports "composition works, no
// separate preedit", which is correct for Latin input methods.

@(private)
ime_backend_set_enabled :: proc(w: ^Window, on: bool) {
	if w == nil { return }
	switch w.backend {
	case .Wayland: wl_ime_set_enabled(w, on)
	case .X11:     // xkbcommon composes inline; nothing to enable
	case .None:
	}
}

@(private)
ime_backend_set_cursor_rect :: proc(w: ^Window, x, y, width, height: int) {
	if w == nil { return }
	switch w.backend {
	case .Wayland: wl_ime_set_cursor_rect(w, x, y, width, height)
	case .X11:
	case .None:
	}
}

@(private)
ime_backend_preedit :: proc(w: ^Window) -> (text: string, cursor: int) {
	if w == nil { return "", 0 }
	switch w.backend {
	case .Wayland: return wl_ime_preedit(w)
	case .X11:     return "", 0
	case .None:
	}
	return "", 0
}

@(private)
ime_backend_preedit_changed :: proc(w: ^Window) -> bool {
	if w == nil { return false }
	switch w.backend {
	case .Wayland: return wl_ime_preedit_changed(w)
	case .X11:     return false
	case .None:
	}
	return false
}
