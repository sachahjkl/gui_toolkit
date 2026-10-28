package platform

// Input-method editing (composing text with an IME: CJK, dead keys, compose sequences), behind a neutral API.
// Committed text reaches the app as .Text events (one per rune), the same path as a plain key, so an app that only
// reads .Text already receives IME input. The preedit (the uncommitted "marked" text an IME shows underlined while
// composing) is read with ime_preedit / ime_preedit_changed, which an app draws inline at the caret; there is no
// preedit Event kind yet, so a text field polls these each frame (cheap).
//
// Backends: Wayland zwp_text_input_v3 (ime_wl_linux.odin), X11 through xkbcommon's compose and — the documented next
// step — ibus over D-Bus. Windows composes through the system IME and commits WM_CHAR, which already arrives as .Text;
// ime_preedit is empty there until the Win32 WM_IME_COMPOSITION path is wired. The stub answers "no IME".

// Turns the IME on or off for a window (a text field focuses: on; it blurs: off). While on, the compositor / server
// routes composition to the window and the app draws the preedit.
ime_set_enabled :: proc(w: ^Window, on: bool) {
	when ODIN_OS == .Linux { ime_backend_set_enabled(w, on) }
}

// Tells the IME where the text caret is (client pixels, the rect of the character being composed), so it places its
// candidate window there. Call it when the caret moves while the IME is on.
ime_set_cursor_rect :: proc(w: ^Window, x, y, width, height: int) {
	when ODIN_OS == .Linux { ime_backend_set_cursor_rect(w, x, y, width, height) }
}

// The current preedit (uncommitted) text and the caret's byte offset inside it ("" when nothing is being composed).
// Valid until the next poll_events. The app draws it at the caret, usually underlined.
ime_preedit :: proc(w: ^Window) -> (text: string, cursor: int) {
	when ODIN_OS == .Linux { return ime_backend_preedit(w) }
	return "", 0
}

// True once after the preedit changed, so a text field knows to repaint (cleared by reading it).
ime_preedit_changed :: proc(w: ^Window) -> bool {
	when ODIN_OS == .Linux { return ime_backend_preedit_changed(w) }
	return false
}
