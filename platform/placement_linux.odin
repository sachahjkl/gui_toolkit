#+build linux
package platform

// Where a window is on the screen (placement.odin has the shared types and fit_rect_to_work). On X11 the position is
// read from and set on the window (xcb_get_geometry / xcb_configure_window); Wayland does not let a client know or set
// its absolute position (the compositor places windows), so there a window reports {0,0} for its origin and move is a
// no-op, which is correct for the protocol — an app saves and restores its *size* and maximized state, which both
// backends support.

outer_rect :: proc(w: ^Window) -> [4]int {
	if w.offscreen { return w.off_place }
	switch w.backend {
	case .X11:     return x11_outer_rect(w)
	case .Wayland: return {0, 0, w.size.x, w.size.y}
	case .None:
	}
	return {0, 0, w.size.x, w.size.y}
}

client_origin :: proc(w: ^Window) -> [2]int {
	if w.offscreen { return {w.off_place[0], w.off_place[1]} }
	r := outer_rect(w)
	return {r[0], r[1]}
}

move_window :: proc(w: ^Window, x, y: int) {
	if w.offscreen { w.off_place[0], w.off_place[1] = x, y; return }
	if w.backend == .X11 { x11_move(w, x, y) }   // Wayland: the compositor owns placement
}

get_placement :: proc(w: ^Window) -> Placement {
	if w.offscreen { return {w.off_place, w.off_state == .Maximized} }
	return {outer_rect(w), is_maximized(w)}
}

set_placement :: proc(w: ^Window, p: Placement) {
	if w.offscreen { w.off_place = p.rect; w.off_state = p.maximized ? .Maximized : .Normal; return }
	if w.backend == .X11 {
		x11_move(w, p.rect[0], p.rect[1])
		x11_set_size(w, {p.rect[2], p.rect[3]})
	} else {
		// Wayland: restore the size (position is the compositor's)
		wl_set_size(w, {p.rect[2], p.rect[3]})
	}
	if p.maximized { toggle_maximize_to(w, true) }
}

@(private)
toggle_maximize_to :: proc(w: ^Window, on: bool) {
	if w.maximized == on { return }
	switch w.backend {
	case .Wayland: wl_set_maximized(w, on)
	case .X11:     x11_set_maximized(w, on)
	case .None:
	}
}
