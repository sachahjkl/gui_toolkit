package platform

// Fingers and pens (Pointer_* events, Event.pointer), independent of the system (pointer_win32.odin reads WM_POINTER;
// tablet_wl_linux.odin reads Wayland's tablet tools; X11 has none). The mouse keeps its Mouse_* events; the mouse
// emulation of a finger or a pen still comes, marked `emulated`, so an app that only knows the mouse goes on working
// and one that follows pointers skips those. Windows emulates the mouse itself; on Wayland a client that takes the
// tablet gets no wl_pointer events for it, so the backend makes them.

// A device's raw pressure, on 0..full, as 0..1 (Windows: 0..1024; Wayland's tablet: 0..65535).
pressure_of :: proc(raw, full: u32) -> f32 {
	if full == 0 { return 0 }
	return clamp(f32(raw) / f32(full), 0, 1)
}

// Pointer Events' `buttons` of a finger or a pen: bit 1 = in contact (the pen's tip or a finger), 2 = the pen's barrel
// button, 32 = the eraser (which replaces bit 1).
pointer_buttons :: proc(info: Pointer_Info, in_contact: bool) -> u16 {
	b: u16
	if in_contact { b |= info.eraser ? 32 : 1 }
	if info.kind == .Pen && info.barrel { b |= 2 }
	return b
}

// The pressure a page sees: the device's (0..1) when it measures one, else 0.5 in contact and 0 otherwise (Pointer
// Events: "for hardware that does not support pressure").
pointer_pressure :: proc(measured: Maybe(f32), in_contact: bool) -> f32 {
	if !in_contact { return 0 }
	if m, ok := measured.?; ok { return clamp(m, 0, 1) }
	return 0.5
}

// The pointers of a window that are down (for Pointer_Cancel when the system takes them away).
Pointer_State :: struct {
	down: [dynamic]u32,
}

pointer_state_down :: proc(s: ^Pointer_State, id: u32) {
	for d in s.down { if d == id { return } }
	append(&s.down, id)
}

// Whether `id` was down (and no longer is).
pointer_state_up :: proc(s: ^Pointer_State, id: u32) -> bool {
	for d, i in s.down {
		if d == id { unordered_remove(&s.down, i); return true }
	}
	return false
}

pointer_state_destroy :: proc(s: ^Pointer_State) { delete(s.down); s^ = {} }
