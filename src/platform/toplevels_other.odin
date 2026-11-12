#+build !linux
package platform

// (toplevels.odin) No system here tells the session's windows yet: none.
toplevels :: proc(w: ^Window, allocator := context.allocator) -> []Toplevel { return nil }
toplevel_activate :: proc(w: ^Window, id: u64) -> bool { return false }
