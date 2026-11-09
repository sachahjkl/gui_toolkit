#+build linux
package platform

// The frame of an integrated title bar on Linux. Windows asks the window what a point is (WM_NCHITTEST) and moves,
// resizes and maximizes it itself; Wayland and X11 leave that to the client that draws its own title bar. So a press
// there is turned into the compositor's or the window manager's own move or resize (xdg_toplevel.move / resize,
// _NET_WM_MOVERESIZE), a double click on the caption maximizes or restores, a right click there opens the compositor's
// window menu (Wayland; X11 has none), and the pointer over a resize band shows the resize cursor. Where things are
// comes from the app's Chrome_Regions, as on Windows; the bands are on all four sides, the compositor drawing no frame.

@(private) CAPTION_DOUBLE_CLICK_MS :: 500   // the usual double-click time (no setting is read)
@(private) CAPTION_DOUBLE_CLICK_PX :: 4     // how far the second press may land from the first, at a scale of 1

// What `pos` (client pixels) is on the window's frame: Client where the app's own (no integrated title, full screen).
@(private)
frame_hit :: proc(w: ^Window, pos: [2]f32) -> Hit {
	if w == nil || !w.integrated || w.offscreen || w.show == .Fullscreen { return .Client }
	border := f32(resize_border(w))
	sides: Sides = w.show == .Maximized ? {} : {.Left, .Top, .Right, .Bottom}
	return hit_test_chrome(&w.chrome, pos, {f32(w.size.x), f32(w.size.y)}, border, border * 2, sides)
}

// The caption buttons are the app's widgets; the caption and the bands are the frame's.
@(private)
hit_is_frame :: proc(h: Hit) -> bool { return h != .Client && h != .Minimize && h != .Maximize && h != .Close }

// The cursor of a resize band (Arrow elsewhere: the window's own then).
@(private)
frame_cursor :: proc(h: Hit) -> (c: Cursor, ok: bool) {
	#partial switch h {
	case .Left:         return .Resize_W, true
	case .Right:        return .Resize_E, true
	case .Top:          return .Resize_N, true
	case .Bottom:       return .Resize_S, true
	case .Top_Left:     return .Resize_NW, true
	case .Top_Right:    return .Resize_NE, true
	case .Bottom_Left:  return .Resize_SW, true
	case .Bottom_Right: return .Resize_SE, true
	}
	return .Arrow, false
}

// The pointer moved to `pos`: over a band the cursor becomes the band's, and back when it leaves.
@(private)
frame_hover_at :: proc(w: ^Window, pos: [2]f32) {
	h := frame_hit(w, pos)
	_, was := frame_cursor(w.frame_hover)
	_, is := frame_cursor(h)
	w.frame_hover = h
	if was != is || is { apply_cursor(w) }
}

// The cursor to show: a band's, else the window's.
@(private)
cursor_shown :: proc(w: ^Window) -> (c: Cursor, band: bool) {
	if band_cursor, ok := frame_cursor(w.frame_hover); ok { return band_cursor, true }
	return w.cursor, false
}

// A second left press on the caption soon after the first, near it (times in ms of the server's clock). Remembers it.
@(private)
caption_double_click :: proc(w: ^Window, pos: [2]f32, time_ms: u32) -> bool {
	near := CAPTION_DOUBLE_CLICK_PX * w.dpi_scale
	d := pos - w.caption_pos
	double := w.caption_ms != 0 && time_ms - w.caption_ms <= CAPTION_DOUBLE_CLICK_MS && abs(d.x) <= near && abs(d.y) <= near
	w.caption_ms = double ? 0 : max(time_ms, 1)
	w.caption_pos = pos
	return double
}
