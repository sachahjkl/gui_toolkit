#+build windows, linux
package platform

// The API of drag and drop that does not depend on the system's transport: what a window keeps (Dnd_State, one on each
// system, with these fields) and what the app asks of it. dragdrop.odin has the description.

// What the drag over the window carries (from Drop_Enter; the last one dropped stays until the next enters), nil
// when no drag came yet.
drop_data :: proc(w: ^Window) -> ^Drag_Data {
	if w.dnd == nil { return nil }
	return &w.dnd.data
}

// Whether a drag of the system is over the window now (between Drop_Enter and Drop_Leave / Drop).
drop_active :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.over }

// The effect a drop at the pointer would have, as the app decided it (nil: refused). The system is told at its next
// question (the pointer moves, a modifier changes, the button is released).
drop_set_effect :: proc(w: ^Window, effect: Maybe(Drop_Effect)) { dnd_state(w).effect = effect }

// Frees what drop_data holds (after the app handled a Drop or a Drop_Leave).
drop_data_release :: proc(w: ^Window) {
	if w.dnd == nil || w.dnd.over { return }
	context.allocator = w.dnd.allocator
	drag_data_destroy(&w.dnd.data)
}

// Queues a Drop_* event as if a drag of the system came (tests, remote control): Drop_Enter takes a copy of `data`;
// the other kinds keep the data of the last Drop_Enter. Through the same path as a real drag (inject_event).
drop_inject :: proc(w: ^Window, kind: Event_Kind, pos: [2]f32, data: ^Drag_Data = nil, allowed: Drop_Effects = {.Copy, .Move, .Link}, mods: Modifiers = {}) -> bool {
	#partial switch kind {
	case .Drop_Enter, .Drop_Over, .Drop_Leave, .Drop:
	case: return false
	}
	d := dnd_state(w)
	if kind == .Drop_Enter {
		context.allocator = d.allocator
		drag_data_destroy(&d.data)
		if data != nil { d.data = drag_data_clone(data^) }
		d.effect = nil
	}
	d.allowed = allowed
	d.over = kind == .Drop_Enter || kind == .Drop_Over
	inject_event(w, Event{kind = kind, pos = pos, mods = mods, drop_allowed = allowed})
	return true
}

// Asks the window's app at once, while drag_start runs from it, what a drop would do (Drop_Sync); nil: the events are
// queued as for any drag (the app then sees its own drag only after drag_start returns).
drop_sync_set :: proc(w: ^Window, handler: Drop_Sync, user: rawptr) {
	d := dnd_state(w)
	d.sync, d.sync_user = handler, user
}

// Tests and remote control: the next drag_start from the window does not follow the mouse but `steps` (copied), with
// the same data and drop target calls as a drag of the system that comes back over the window. True when this system
// can do it.
drag_script :: proc(w: ^Window, steps: []Drag_Step) -> bool {
	d := dnd_state(w)
	context.allocator = d.allocator
	clear(&d.script)
	append(&d.script, ..steps)
	return true
}

// The picture the system holds for the last drag_start from the window (read back from the system after the app gave
// it): its size and hot spot; ok = false when there was none or the system refused it.
drag_image_held :: proc(w: ^Window) -> (size, offset: [2]int, ok: bool) {
	if w.dnd == nil || !w.dnd.image_held { return }
	return w.dnd.image_size, w.dnd.image_offset, true
}

// Tests: how long a drag from the window may stay silent before it is given up (0: the system's limit). Nothing to do on
// Windows, whose loop has none.
drag_silence_limit :: proc(w: ^Window, ms: int) { dnd_state(w).silence_ms = ms }

// Whether drag_start is running from this window (its own drop target then sees a drag that came from the app).
drag_sending :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.sending }
