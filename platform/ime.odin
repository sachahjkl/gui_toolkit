package platform

// Input-method editing (composing text with an IME: CJK, dead keys, compose sequences), behind a neutral API.
// Committed text reaches the app as .Text events (one per rune), the same path as a plain key, so an app that only
// reads .Text already receives IME input. The preedit (the uncommitted "marked" text an IME shows underlined while
// composing) is read with ime_preedit / ime_preedit_changed, which an app draws inline at the caret; there is no
// preedit Event kind yet, so a text field polls these each frame (cheap).
//
// Backends: Wayland zwp_text_input_v3 (ime_wl_linux.odin, through Ime_Compose below), X11 through xkbcommon's compose and — the documented next
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

////////////////////////////////
// the composition as the protocols deliver it

// What an input method sent and what of it is applied (zwp_text_input_v3: preedit_string, commit_string,
// delete_surrounding_text are pending until a `done` applies them together). Pure: fed with the protocol's events, it
// gives the app's events and the preedit (tests/ime).
Ime_Compose :: struct {
	preedit:         string,   // applied: what the app draws at the caret
	cursor:          int,      // the caret's byte offset in it
	changed:         bool,     // the preedit changed since ime_compose_take_changed
	pending_preedit: string,
	pending_cursor:  int,
	pending_commit:  string,
	pending_delete:  int,      // characters before the caret the input method replaces (sent as Backspace presses)
}

// The preedit the next `done` shows; `cursor` a byte offset in it (negative: hidden, at its start).
ime_compose_preedit :: proc(c: ^Ime_Compose, text: string, cursor: int) {
	delete(c.pending_preedit)
	c.pending_preedit = clone_string(text)
	c.pending_cursor = clamp(cursor, 0, len(text))
}

// The text the next `done` inserts.
ime_compose_commit :: proc(c: ^Ime_Compose, text: string) {
	delete(c.pending_commit)
	c.pending_commit = clone_string(text)
}

// Text before the caret the next `done` deletes, before it inserts.
ime_compose_delete :: proc(c: ^Ime_Compose, before: int) { c.pending_delete = max(before, 0) }

// Applies what is pending: the deletion as Backspace presses, the commit as .Text events (one per printable rune), then
// the new preedit (none sent since the last `done`: no preedit). Appends the events to `out`.
ime_compose_done :: proc(c: ^Ime_Compose, out: ^[dynamic]Event) {
	for _ in 0 ..< c.pending_delete {
		append(out, Event{kind = .Key_Press, key = .Backspace}, Event{kind = .Key_Release, key = .Backspace})
	}
	for r in c.pending_commit {
		if r >= RUNE_FIRST_PRINTABLE && r != RUNE_DEL { append(out, Event{kind = .Text, text = r}) }
	}
	if c.preedit != c.pending_preedit || c.cursor != c.pending_cursor {
		delete(c.preedit)
		c.preedit, c.pending_preedit = c.pending_preedit, ""
		c.cursor = c.pending_cursor
		c.changed = true
	}
	delete(c.pending_preedit); delete(c.pending_commit)
	c.pending_preedit, c.pending_commit, c.pending_cursor, c.pending_delete = "", "", 0, 0
}

// The input method was turned off: nothing pending, no preedit (a change, so the field repaints).
ime_compose_reset :: proc(c: ^Ime_Compose) {
	ime_compose_destroy(c)
	c.changed = true
}

// True once after the preedit changed.
ime_compose_take_changed :: proc(c: ^Ime_Compose) -> bool {
	r := c.changed
	c.changed = false
	return r
}

ime_compose_destroy :: proc(c: ^Ime_Compose) {
	delete(c.preedit); delete(c.pending_preedit); delete(c.pending_commit)
	c^ = {}
}

// The caret's rectangle in the surface's logical units the compositors take (ours are physical pixels: divided by the
// window's scale, at least one unit high).
ime_cursor_rect_logical :: proc(x, y, width, height: int, scale: f32) -> [4]i32 {
	s := scale > 0 ? scale : 1
	return {i32(f32(x) / s), i32(f32(y) / s), i32(f32(width) / s), max(i32(f32(height) / s), 1)}
}
