package platform

import "core:strings"

// (toplevels.odin) The session's windows, in `allocator` (their strings too); none on X11 or offscreen.
toplevels :: proc(w: ^Window, allocator := context.allocator) -> []Toplevel {
	if w == nil || w.offscreen || w.backend != .Wayland { return nil }
	out := make([dynamic]Toplevel, 0, len(wlc.toplevels), allocator)
	for t in wlc.toplevels {
		if t.closed { continue }
		append(&out, Toplevel{
			id = t.id, app_id = strings.clone(t.app_id, allocator), title = strings.clone(t.title, allocator),
			active = t.active, minimized = t.minimized,
		})
	}
	return out[:]
}

// Brings the window `id` names to the front, with the focus (a minimized one comes back). False: it is gone, or the
// system tells no windows.
toplevel_activate :: proc(w: ^Window, id: u64) -> bool {
	if w == nil || w.offscreen || w.backend != .Wayland { return false }
	return wl_toplevel_activate(id)
}
