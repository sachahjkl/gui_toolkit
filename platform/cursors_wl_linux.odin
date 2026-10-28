#+build linux
package platform

// Wayland cursor shapes through wp_cursor_shape_v1: the compositor draws the pointer from a named shape, so the
// toolkit uploads no pixels and the cursor matches the user's theme and size. The device is made from the seat's
// wl_pointer the first time a cursor is applied; set_shape names the shape at the last pointer-enter serial.
//
// A None cursor (hidden) has no shape; we hide it with wl_pointer.set_cursor(nil surface). A custom cursor (an RGBA
// image) would need a wl_buffer from a wl_shm pool — the documented next step; until then a custom cursor falls back
// to its fallback shape.

@(private) WL_POINTER_SET_CURSOR :: 0

// The wp_cursor_shape_v1 shape numbers (the protocol's enum order).
@(private) WP_SHAPE_DEFAULT :: 1
@(private) WP_SHAPE_CONTEXT_MENU :: 2
@(private) WP_SHAPE_HELP :: 3
@(private) WP_SHAPE_POINTER :: 4
@(private) WP_SHAPE_PROGRESS :: 5
@(private) WP_SHAPE_WAIT :: 6
@(private) WP_SHAPE_CELL :: 7
@(private) WP_SHAPE_CROSSHAIR :: 8
@(private) WP_SHAPE_TEXT :: 9
@(private) WP_SHAPE_VERTICAL_TEXT :: 10
@(private) WP_SHAPE_ALIAS :: 11
@(private) WP_SHAPE_COPY :: 12
@(private) WP_SHAPE_MOVE :: 13
@(private) WP_SHAPE_NO_DROP :: 14
@(private) WP_SHAPE_NOT_ALLOWED :: 15
@(private) WP_SHAPE_GRAB :: 16
@(private) WP_SHAPE_GRABBING :: 17
@(private) WP_SHAPE_E_RESIZE :: 18
@(private) WP_SHAPE_N_RESIZE :: 19
@(private) WP_SHAPE_NE_RESIZE :: 20
@(private) WP_SHAPE_NW_RESIZE :: 21
@(private) WP_SHAPE_S_RESIZE :: 22
@(private) WP_SHAPE_SE_RESIZE :: 23
@(private) WP_SHAPE_SW_RESIZE :: 24
@(private) WP_SHAPE_W_RESIZE :: 25
@(private) WP_SHAPE_EW_RESIZE :: 26
@(private) WP_SHAPE_NS_RESIZE :: 27
@(private) WP_SHAPE_NESW_RESIZE :: 28
@(private) WP_SHAPE_NWSE_RESIZE :: 29
@(private) WP_SHAPE_COL_RESIZE :: 30
@(private) WP_SHAPE_ROW_RESIZE :: 31
@(private) WP_SHAPE_ALL_SCROLL :: 32
@(private) WP_SHAPE_ZOOM_IN :: 33
@(private) WP_SHAPE_ZOOM_OUT :: 34

@(private)
wl_apply_cursor :: proc(w: ^Window) {
	if wlc.pointer == nil { return }
	c := w.cursor
	// a custom cursor falls back to its fallback shape until the wl_shm upload is wired
	if w.custom_cursor != 0 { c = w.custom_fallback }
	if c == .None {
		// hide: set a null cursor surface at the enter serial
		wl.proxy_marshal_flags(wlc.pointer, WL_POINTER_SET_CURSOR, nil, wl.proxy_get_version(wlc.pointer), 0, wl_enter_serial, nil, i32(0), i32(0))
		wl.display_flush(wlc.display)
		return
	}
	if wlc.cursor_shape_manager == nil { return }   // no wp_cursor_shape_v1: the compositor keeps the default pointer
	if wlc.cursor_shape_device == nil {
		wlc.cursor_shape_device = wl.proxy_marshal_flags(wlc.cursor_shape_manager, WP_CURSOR_SHAPE_MANAGER_GET_POINTER,
			&wp_cursor_shape_device_iface, wl.proxy_get_version(wlc.cursor_shape_manager), 0, nil, wlc.pointer)
	}
	if wlc.cursor_shape_device == nil { return }
	shape := wl_shape_for_cursor(c)
	wl.proxy_marshal_flags(wlc.cursor_shape_device, WP_CURSOR_SHAPE_DEVICE_SET_SHAPE, nil, wl.proxy_get_version(wlc.cursor_shape_device), 0, wl_enter_serial, u32(shape))
	wl.display_flush(wlc.display)
}

// Our Cursor enum to a wp_cursor_shape_v1 shape number, through the shared CSS name (the first seven keep older enum
// names, so special-case them; the rest match the CSS keyword the shape protocol also uses).
@(private)
wl_shape_for_cursor :: proc(c: Cursor) -> int {
	#partial switch c {
	case .Arrow:        return WP_SHAPE_DEFAULT
	case .Hand:         return WP_SHAPE_POINTER
	case .Text:         return WP_SHAPE_TEXT
	case .Resize_H:     return WP_SHAPE_EW_RESIZE
	case .Resize_V:     return WP_SHAPE_NS_RESIZE
	case .Move:         return WP_SHAPE_MOVE
	case .Not_Allowed:  return WP_SHAPE_NOT_ALLOWED
	}
	switch cursor_css_name(c) {
	case "crosshair":    return WP_SHAPE_CROSSHAIR
	case "wait":         return WP_SHAPE_WAIT
	case "progress":     return WP_SHAPE_PROGRESS
	case "help":         return WP_SHAPE_HELP
	case "context-menu": return WP_SHAPE_CONTEXT_MENU
	case "cell":         return WP_SHAPE_CELL
	case "vertical-text": return WP_SHAPE_VERTICAL_TEXT
	case "alias":        return WP_SHAPE_ALIAS
	case "copy":         return WP_SHAPE_COPY
	case "no-drop":      return WP_SHAPE_NO_DROP
	case "grab":         return WP_SHAPE_GRAB
	case "grabbing":     return WP_SHAPE_GRABBING
	case "all-scroll":   return WP_SHAPE_ALL_SCROLL
	case "zoom-in":      return WP_SHAPE_ZOOM_IN
	case "zoom-out":     return WP_SHAPE_ZOOM_OUT
	case "col-resize":   return WP_SHAPE_COL_RESIZE
	case "row-resize":   return WP_SHAPE_ROW_RESIZE
	case "n-resize":     return WP_SHAPE_N_RESIZE
	case "e-resize":     return WP_SHAPE_E_RESIZE
	case "s-resize":     return WP_SHAPE_S_RESIZE
	case "w-resize":     return WP_SHAPE_W_RESIZE
	case "ne-resize":    return WP_SHAPE_NE_RESIZE
	case "nw-resize":    return WP_SHAPE_NW_RESIZE
	case "se-resize":    return WP_SHAPE_SE_RESIZE
	case "sw-resize":    return WP_SHAPE_SW_RESIZE
	case "ew-resize":    return WP_SHAPE_EW_RESIZE
	case "ns-resize":    return WP_SHAPE_NS_RESIZE
	case "nesw-resize":  return WP_SHAPE_NESW_RESIZE
	case "nwse-resize":  return WP_SHAPE_NWSE_RESIZE
	}
	return WP_SHAPE_DEFAULT
}
