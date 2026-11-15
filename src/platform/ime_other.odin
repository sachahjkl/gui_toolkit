#+build !linux
package platform

// No IME of the toolkit's here: Windows commits the system IME's text as WM_CHAR (.Text events) and shows its own
// preedit; other systems have none yet.
ime_backend_set_enabled :: proc(w: ^Window, on: bool) {}
ime_backend_set_cursor_rect :: proc(w: ^Window, x, y, width, height: int) {}
ime_backend_preedit :: proc(w: ^Window) -> (text: string, cursor: int) { return "", 0 }
ime_backend_preedit_changed :: proc(w: ^Window) -> bool { return false }
