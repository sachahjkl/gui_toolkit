#+build linux
package platform

// Drag and drop on Linux (dragdrop.odin has the API and the pure helpers). The receiving and sending halves are the
// same shape as the Windows OLE backend: a window becomes a drop target, a drag that comes over it queues Drop_* events
// with the data in drop_data(window), and drag_start runs a drag of the system from the window. The transports differ:
// Wayland uses wl_data_device (dragdrop_wl_linux.odin), X11 uses the XDND protocol version 5 (dragdrop_x11_linux.odin).
// This file holds the window's Dnd_State, the API entry points and the shared event delivery; each backend fills the
// Drag_Data from its offer and runs the system's drag.

import "base:runtime"
import "core:time"

// What a window keeps for drag and drop (Native_Window.dnd, made on first use). Mirrors the Win32 Dnd_State fields the
// shared logic uses; the backend-specific handles live in the per-backend conn state (wlc / x11 dnd fields).
@(private)
Dnd_State :: struct {
	enabled:   bool,
	data:      Drag_Data,          // the drag over the window, or the last one dropped (until the next enters)
	effect:    Maybe(Drop_Effect), // the app's answer (drop_set_effect)
	allowed:   Drop_Effects,       // the source's
	over:      bool,               // between Drop_Enter and Drop_Leave / Drop
	sending:   bool,               // drag_start runs from this window
	allocator: runtime.Allocator,  // the app's, when the state was made: `data` lives in it
	sync:      Drop_Sync,          // drop_sync_set
	sync_user: rawptr,
	script:    [dynamic]Drag_Step, // drag_script
	image_size, image_offset: [2]int,
	image_held: bool,
}

@(private)
dnd_state :: proc(w: ^Window) -> ^Dnd_State {
	if w.dnd == nil {
		w.dnd = new(Dnd_State)
		w.dnd.allocator = context.allocator
	}
	return w.dnd
}

// Makes the window a drop target (or no longer one). On Wayland the data-device offers come to the focused surface
// anyway; on X11 we set the XdndAware property. False when there is no window (offscreen): synthetic drops still work.
drop_target_enable :: proc(w: ^Window, on: bool) -> bool {
	if w == nil || w.offscreen { return !on }
	d := dnd_state(w)
	if on == d.enabled { return true }
	d.enabled = on
	switch w.backend {
	case .Wayland: // the compositor routes drags to the focused surface; nothing to register
	case .X11:     x11_dnd_set_aware(w, on)
	case .None:
	}
	return true
}

drop_target_enabled :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.enabled }

// Prepares the calling thread for drag and drop. Nothing to do on Linux (no apartment model); always true.
dragdrop_thread_init :: proc() -> bool { return true }

drop_data :: proc(w: ^Window) -> ^Drag_Data {
	if w.dnd == nil { return nil }
	return &w.dnd.data
}

drop_active :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.over }

drop_set_effect :: proc(w: ^Window, effect: Maybe(Drop_Effect)) { dnd_state(w).effect = effect }

drop_data_release :: proc(w: ^Window) {
	if w.dnd == nil || w.dnd.over { return }
	context.allocator = w.dnd.allocator
	drag_data_destroy(&w.dnd.data)
}

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

drop_sync_set :: proc(w: ^Window, handler: Drop_Sync, user: rawptr) {
	d := dnd_state(w)
	d.sync, d.sync_user = handler, user
}

drag_script :: proc(w: ^Window, steps: []Drag_Step) -> bool {
	d := dnd_state(w)
	context.allocator = d.allocator
	clear(&d.script)
	append(&d.script, ..steps)
	return true
}

drag_image_held :: proc(w: ^Window) -> (size, offset: [2]int, ok: bool) {
	if w.dnd == nil || !w.dnd.image_held { return }
	return w.dnd.image_size, w.dnd.image_offset, true
}

drag_threshold :: proc(w: ^Window) -> [2]f32 { return {4, 4} }   // no system setting we read; the common default

drag_sending :: proc(w: ^Window) -> bool { return w.dnd != nil && w.dnd.sending }

// Runs a drag of the system from the window. Wayland: wl_data_device.start_drag with a wl_data_source; X11: the XDND
// source loop. Blocks until the drop or cancel; returns the chosen effect. ok = false when the backend could not start
// it (no data, no serial).
drag_start :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, image: Maybe(Drag_Image) = nil) -> (effect: Maybe(Drop_Effect), ok: bool) {
	if drag_data_empty(data) || allowed == {} { return nil, false }
	if w == nil || w.offscreen { return nil, false }
	d := dnd_state(w)
	d.image_held, d.image_size, d.image_offset = false, {}, {}
	if len(d.script) > 0 {
		steps := d.script
		d.script = {}
		defer delete(steps)
		return drag_run_script(w, data, allowed, steps[:]), true
	}
	d.sending = true
	defer d.sending = false
	switch w.backend {
	case .Wayland: return wl_drag_start(w, data, allowed, image)
	case .X11:     return x11_drag_start(w, data, allowed, image)
	case .None:
	}
	return nil, false
}

drop_self_test :: proc(w: ^Window, data: Drag_Data, pos: [2]f32, allowed: Drop_Effects) -> bool {
	d := dnd_state(w)
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	d.data = drag_data_clone(data)
	d.allowed = allowed
	d.over = true
	deliver_drop(w, .Drop_Enter, pos)
	deliver_drop(w, .Drop_Over, pos)
	deliver_drop(w, .Drop, pos)
	d.over = false
	return true
}

////////////////////////////////
// shared event delivery (the backends call this with the data already read into d.data)

// Delivers a Drop_* event to the app: queued for the next poll, or (while drag_start runs from this window and the app
// asked with drop_sync_set) handed to the app at once. Returns the effect to tell the system.
@(private)
deliver_drop :: proc(w: ^Window, kind: Event_Kind, pos: [2]f32, mods: Modifiers = {}) -> Maybe(Drop_Effect) {
	d := w.dnd
	if d == nil { return nil }
	ev := Event{kind = kind, pos = pos, mods = mods, drop_allowed = d.allowed, stamp = time.tick_now()}
	if d.sending && d.sync != nil {
		e := d.sync(d.sync_user, w, ev)
		if kind == .Drop_Leave { return nil }
		d.effect = e
		return e
	}
	append(&w.events, ev)
	return kind == .Drop_Leave ? nil : d.effect
}

// The effect the app last chose, filtered to what the source allows; falls back to the convention when the app has not
// answered (the common case while a drag hovers).
@(private)
dnd_answer :: proc(w: ^Window, mods: Modifiers) -> Maybe(Drop_Effect) {
	d := w.dnd
	if d == nil { return nil }
	if e, ok := d.effect.?; ok && e in d.allowed { return e }
	return drop_effect_for(d.allowed, mods)
}

// A scripted drag (drag_script): feed the window's own drop target along the steps, as a drag that came back over it.
@(private)
drag_run_script :: proc(w: ^Window, data: Drag_Data, allowed: Drop_Effects, steps: []Drag_Step) -> Maybe(Drop_Effect) {
	d := dnd_state(w)
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	d.data = drag_data_clone(data)
	d.allowed = allowed
	inside := false
	result: Maybe(Drop_Effect)
	for s, i in steps {
		now := s.pos.x >= 0 && s.pos.y >= 0 && s.pos.x < f32(w.size.x) && s.pos.y < f32(w.size.y)
		first, second := drag_script_calls(inside, now, i == len(steps) - 1)
		for call in ([]Drag_Script_Call{first, second}) {
			switch call {
			case .None, .Cancel:
			case .Enter: d.over = true; deliver_drop(w, .Drop_Enter, s.pos, s.mods)
			case .Over:  deliver_drop(w, .Drop_Over, s.pos, s.mods)
			case .Leave: d.over = false; deliver_drop(w, .Drop_Leave, s.pos, s.mods)
			case .Drop:  d.over = false; result = deliver_drop(w, .Drop, s.pos, s.mods)
			}
		}
		inside = now
	}
	return result
}

@(private)
dnd_destroy :: proc(w: ^Window) {
	d := w.dnd
	if d == nil { return }
	context.allocator = d.allocator
	drag_data_destroy(&d.data)
	delete(d.script)
	free(d)
	w.dnd = nil
}
