package platform

// The resize bands of an integrated title bar, outside the window (Wayland). Bands inside the window took the pointer
// from what the app draws along its edges: a list's scrollbar at the window's right edge was under its band, all but a
// pixel of it. GTK's answer, here: a ring of RESIZE_BAND_PX around the window, an empty subsurface below it that takes
// the pointer there and nowhere else (its input region), and the window's geometry (xdg_surface.set_window_geometry)
// its surface alone: the compositor places, tiles and snaps the window without the ring. The whole window is the app's.
//
// Only a free window has it: maximized, full screen or tiled, its edges are the screen's or another window's (a ring
// there would take their pointer), and a compositor that draws the frame resizes from it. Without a subcompositor or a
// viewporter the bands stay inside (frame_hit).

@(private = "file") WL_SURFACE_SET_INPUT_REGION :: 5
@(private = "file") WL_SUBCOMPOSITOR_GET_SUBSURFACE :: 1
@(private = "file") WL_SUBSURFACE_DESTROY :: 0
@(private = "file") WL_SUBSURFACE_SET_POSITION :: 1
@(private = "file") WL_SUBSURFACE_PLACE_BELOW :: 3
@(private = "file") WL_REGION_DESTROY :: 0
@(private = "file") WL_REGION_SUBTRACT :: 2

// The ring of a window: its surface, its place under the window's, its size.
@(private)
Wl_Outside_Bands :: struct {
	surface:    Wl_Proxy,
	subsurface: Wl_Proxy,
	viewport:   Wl_Proxy,
	logical:    [2]int,   // the window's size the ring was made around (compositor units)
}

// The ring as the window's state asks: made, fitted to its size, or taken away. After each configure and size change.
@(private)
wl_outside_bands_update :: proc(w: ^Window, st: ^Wl_Window_State) {
	if st.xdg_surface == nil { return }
	// (the window's geometry is its surface: without it, the compositor counts the ring in the window's size)
	wl.proxy_marshal_flags(st.xdg_surface, XDG_SURFACE_SET_WINDOW_GEOMETRY, nil, wl.proxy_get_version(st.xdg_surface), 0, i32(0), i32(0), i32(max(st.logical.x, 1)), i32(max(st.logical.y, 1)))
	free_window := w.integrated && st.toplevel == .Normal && !st.tiled && !st.server_side
	if free_window && wlc.clear_buffer == nil { wlc.clear_buffer = wl_shm_buffer({1, 1}) }
	if !free_window || wlc.subcompositor == nil || wlc.viewporter == nil || wlc.clear_buffer == nil {
		wl_outside_bands_destroy(st)
		w.outside_band = 0
		return
	}
	b := &st.outside
	if b.surface == nil {
		b.surface = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
		if b.surface == nil { return }
		// (the pointer over the ring is the window's: window_of_surface reads the state, ptr_enter sees the ring)
		wl.proxy_set_user_data(b.surface, st)
		b.subsurface = wl.proxy_marshal_flags(wlc.subcompositor, WL_SUBCOMPOSITOR_GET_SUBSURFACE, wl.subsurface_interface, wl.proxy_get_version(wlc.subcompositor), 0, nil, b.surface, st.surface)
		b.viewport = wl.proxy_marshal_flags(wlc.viewporter, WP_VIEWPORTER_GET_VIEWPORT, &wp_viewport_iface, wl.proxy_get_version(wlc.viewporter), 0, nil, b.surface)
		if b.subsurface == nil || b.viewport == nil { wl_outside_bands_destroy(st); return }
		m := i32(RESIZE_BAND_PX)
		wl.proxy_marshal_flags(b.subsurface, WL_SUBSURFACE_SET_POSITION, nil, wl.proxy_get_version(b.subsurface), 0, -m, -m)
		wl.proxy_marshal_flags(b.subsurface, WL_SUBSURFACE_PLACE_BELOW, nil, wl.proxy_get_version(b.subsurface), 0, st.surface)
		// (one transparent pixel, stretched by the viewport: a surface with no buffer is not mapped and takes no pointer)
		wl.proxy_marshal_flags(b.surface, WL_SURFACE_ATTACH, nil, wl.proxy_get_version(b.surface), 0, wlc.clear_buffer, i32(0), i32(0))
	}
	w.outside_band = RESIZE_BAND_PX * w.dpi_scale
	if b.logical == st.logical { return }
	b.logical = st.logical
	m := i32(RESIZE_BAND_PX)
	size := [2]i32{i32(max(st.logical.x, 1)), i32(max(st.logical.y, 1))}
	wl.proxy_marshal_flags(b.viewport, WP_VIEWPORT_SET_DESTINATION, nil, wl.proxy_get_version(b.viewport), 0, size.x + 2 * m, size.y + 2 * m)
	region := wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_REGION, wl.region_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
	if region != nil {
		wl.proxy_marshal_flags(region, WL_REGION_ADD, nil, wl.proxy_get_version(region), 0, i32(0), i32(0), size.x + 2 * m, size.y + 2 * m)
		wl.proxy_marshal_flags(region, WL_REGION_SUBTRACT, nil, wl.proxy_get_version(region), 0, m, m, size.x, size.y)
		wl.proxy_marshal_flags(b.surface, WL_SURFACE_SET_INPUT_REGION, nil, wl.proxy_get_version(b.surface), 0, region)
		wl.proxy_marshal_flags(region, WL_REGION_DESTROY, nil, wl.proxy_get_version(region), WL_MARSHAL_FLAG_DESTROY)
	}
	// (a synchronized subsurface: this state goes on the screen with the window's next picture, of the same size)
	wl.proxy_marshal_flags(b.surface, WL_SURFACE_COMMIT, nil, wl.proxy_get_version(b.surface), 0)
}

@(private)
wl_outside_bands_destroy :: proc(st: ^Wl_Window_State) {
	b := &st.outside
	if b.surface != nil && wlc.pointer_surface == b.surface { wlc.pointer_surface = nil }
	if b.viewport != nil { wl.proxy_marshal_flags(b.viewport, WP_VIEWPORT_DESTROY, nil, wl.proxy_get_version(b.viewport), WL_MARSHAL_FLAG_DESTROY) }
	if b.subsurface != nil { wl.proxy_marshal_flags(b.subsurface, WL_SUBSURFACE_DESTROY, nil, wl.proxy_get_version(b.subsurface), WL_MARSHAL_FLAG_DESTROY) }
	if b.surface != nil { wl.proxy_marshal_flags(b.surface, WL_SURFACE_DESTROY, nil, wl.proxy_get_version(b.surface), WL_MARSHAL_FLAG_DESTROY) }
	b^ = {}
}

// A point of the surface the pointer is on (compositor units) in the window's pixels: the ring's starts RESIZE_BAND_PX
// above and left of the window.
@(private)
wl_pointer_point :: proc(w: ^Window, surface: Wl_Proxy, sx, sy: Wl_Fixed) -> [2]f32 {
	p := [2]f32{f32(wl_fixed_to_f64(sx)), f32(wl_fixed_to_f64(sy))}
	if st := wl_state(w); st != nil && surface != nil && surface == st.outside.surface { p -= RESIZE_BAND_PX }
	return p * w.dpi_scale
}
