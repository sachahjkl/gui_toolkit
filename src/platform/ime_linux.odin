#+build linux
package platform

// The Linux IME dispatcher (ime.odin has the neutral API): routes to the Wayland text-input (ime_wl_linux.odin) or the
// X11 path. On X11 a key's text is what the keymap gives under the modifiers and the group of its event (x11_key): Shift,
// AltGr, Caps Lock, the layouts. Dead keys and Compose sequences are not composed (that is libxkbcommon's compose tables,
// not bound here), nor is there a full IME (ibus / fcitx over XIM or D-Bus): both are the documented next step, and would
// surface their preedit through the same ime_preedit path. So on X11 ime_set_enabled is a no-op that reports no separate
// preedit.

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
