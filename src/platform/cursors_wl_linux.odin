#+build linux
package platform

import "core:strconv"
import "core:strings"
import "core:sys/posix"

// Wayland cursor shapes through wp_cursor_shape_v1: the compositor draws the pointer from a named shape, so the
// toolkit uploads no pixels and the cursor matches the user's theme and size. The device is made from the seat's
// wl_pointer the first time a cursor is applied; set_shape names the shape at the last pointer-enter serial.
//
// A None cursor (hidden) has no shape; we hide it with wl_pointer.set_cursor(nil surface). A custom cursor (an RGBA image)
// is a wl_buffer from a wl_shm pool on a surface of our own, and so is the theme's image on a compositor without the
// protocol (libwayland-cursor, by dlopen, optional; without it the compositor keeps its pointer). The compositor forgets
// the cursor when the pointer leaves: it is sent again on each enter (ptr_enter).

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

@(private = "file") WL_BUFFER_DESTROY_REQUEST :: 0
@(private = "file") WL_SURFACE_DAMAGE_REQUEST :: 2
@(private = "file") WL_CURSOR_THEME_BASE_PX :: 24
@(private = "file") WL_CURSOR_DAMAGE_ALL :: 0x7fffffff
@(private = "file") WL_CURSOR_SENT_SURFACE :: 1 << 32   // wlc.cursor_sent: an image of ours, plus which
@(private = "file") WL_CURSOR_SENT_HIDDEN :: 1 << 33


@(private = "file") Wl_Cursor_Image :: struct { width, height, hotspot_x, hotspot_y, delay: u32 }
@(private = "file") Wl_Cursor :: struct { image_count: u32, images: [^]^Wl_Cursor_Image, name: cstring }
@(private = "file")
Wl_Cursor_Lib :: struct {
	loaded: bool,
	theme_load: proc "c" (name: cstring, size: i32, shm: Wl_Proxy) -> rawptr,
	get_cursor: proc "c" (theme: rawptr, name: cstring) -> ^Wl_Cursor,
	image_buffer: proc "c" (image: ^Wl_Cursor_Image) -> Wl_Proxy,
	theme: rawptr,
	theme_scale: i32,
}
// libwayland-cursor and the theme loaded on this thread's connection (wlc.shm)
@(private = "file", thread_local) wlcl: Wl_Cursor_Lib

// An image on the pointer: the buffer on our cursor surface, at a whole scale.
@(private = "file")
wl_cursor_image :: proc(buffer: Wl_Proxy, hot: [2]int, scale: i32) {
	if wlc.compositor == nil { return }
	if wlc.cursor_surface == nil {
		wlc.cursor_surface = wl.proxy_marshal_flags(wlc.compositor, WL_COMPOSITOR_CREATE_SURFACE, wl.surface_interface, wl.proxy_get_version(wlc.compositor), 0, nil)
		if wlc.cursor_surface == nil { return }
	}
	v := wl.proxy_get_version(wlc.cursor_surface)
	wl.proxy_marshal_flags(wlc.cursor_surface, WL_SURFACE_ATTACH, nil, v, 0, buffer, i32(0), i32(0))
	wl.proxy_marshal_flags(wlc.cursor_surface, WL_SURFACE_SET_BUFFER_SCALE, nil, v, 0, scale)
	wl.proxy_marshal_flags(wlc.cursor_surface, WL_SURFACE_DAMAGE_REQUEST, nil, v, 0, i32(0), i32(0), i32(WL_CURSOR_DAMAGE_ALL), i32(WL_CURSOR_DAMAGE_ALL))
	wl.proxy_marshal_flags(wlc.cursor_surface, WL_SURFACE_COMMIT, nil, v, 0)
	wl.proxy_marshal_flags(wlc.pointer, WL_POINTER_SET_CURSOR, nil, wl.proxy_get_version(wlc.pointer), 0, wlc.enter_serial, wlc.cursor_surface, i32(hot.x) / scale, i32(hot.y) / scale)
	wl.display_flush(wlc.display)
}

// A theme's image for a cursor, on a compositor without wp_cursor_shape_v1.
@(private = "file")
wl_theme_cursor :: proc(w: ^Window, c: Cursor) -> bool {
	if !wlcl.loaded {
		wlcl.loaded = true
		if h := lib_open({"libwayland-cursor.so.0", "libwayland-cursor.so"}); h != nil {
			wlcl.theme_load = auto_cast lib_sym(h, "wl_cursor_theme_load")
			wlcl.get_cursor = auto_cast lib_sym(h, "wl_cursor_theme_get_cursor")
			wlcl.image_buffer = auto_cast lib_sym(h, "wl_cursor_image_get_buffer")
		}
	}
	if wlcl.theme_load == nil || wlcl.get_cursor == nil || wlcl.image_buffer == nil || wlc.shm == nil { return false }
	scale := max(i32(w.dpi_scale + 0.999), 1)
	if wlcl.theme == nil || wlcl.theme_scale != scale {
		base := i32(WL_CURSOR_THEME_BASE_PX)
		if env := posix.getenv("XCURSOR_SIZE"); env != nil {
			if n, ok := strconv.parse_int(string(env)); ok && n > 0 { base = i32(n) }
		}
		// (an older theme stays alive: its buffers may still be on the surface; a scale changes rarely)
		wlcl.theme = wlcl.theme_load(posix.getenv("XCURSOR_THEME"), base * scale, wlc.shm)
		wlcl.theme_scale = scale
		if wlcl.theme == nil { return false }
	}
	cursor := wlcl.get_cursor(wlcl.theme, strings.clone_to_cstring(cursor_css_name(c), context.temp_allocator))
	if cursor == nil {
		older, _ := cursor_older_name(c)
		cursor = wlcl.get_cursor(wlcl.theme, strings.clone_to_cstring(older, context.temp_allocator))
	}
	if cursor == nil || cursor.image_count == 0 { return false }
	image := cursor.images[0]
	buffer := wlcl.image_buffer(image)
	if buffer == nil { return false }
	wl_cursor_image(buffer, {int(image.hotspot_x), int(image.hotspot_y)}, scale)
	wlc.cursor_sent = WL_CURSOR_SENT_SURFACE | u64(c)
	return true
}

@(private)
wl_custom_release :: proc(e: ^Custom_Entry) {
	if e.wl_buffer != nil { wl.proxy_marshal_flags(e.wl_buffer, WL_BUFFER_DESTROY_REQUEST, nil, wl.proxy_get_version(e.wl_buffer), WL_MARSHAL_FLAG_DESTROY) }
	e.wl_buffer = nil
}

// A custom cursor at the window's scale, on our surface. false: it cannot be shown (its fallback then).
@(private = "file")
wl_custom_cursor :: proc(w: ^Window, e: ^Custom_Entry) -> bool {
	scale := max(i32(custom_cursor_scale(w) + 0.999), 1)
	if e.wl_buffer == nil || e.made_scale != f32(scale) {
		wl_custom_release(e)
		px, size, hot := custom_cursor_bgra(e, f32(scale), context.temp_allocator)
		e.wl_buffer = wl_shm_buffer(size, px)
		e.wl_hot = hot
		e.made_scale = f32(scale)
	}
	if e.wl_buffer == nil { return false }
	wl_cursor_image(e.wl_buffer, e.wl_hot, scale)
	wlc.cursor_sent = WL_CURSOR_SENT_SURFACE | u64(uintptr(e.wl_buffer))
	return true
}

@(private)
wl_apply_cursor :: proc(w: ^Window) {
	// (one pointer for the seat: another window's cursor is sent when the pointer enters it, with that enter's serial)
	if wlc.pointer == nil || wlc.pointer_focus != w { return }
	c := w.cursor
	if w.custom_cursor != 0 {
		c = w.custom_fallback
		if e := custom_entry(w, w.custom_cursor); e != nil && wl_custom_cursor(w, e) { return }
	}
	if c == .None {
		// hide: set a null cursor surface at the enter serial
		wl.proxy_marshal_flags(wlc.pointer, WL_POINTER_SET_CURSOR, nil, wl.proxy_get_version(wlc.pointer), 0, wlc.enter_serial, nil, i32(0), i32(0))
		wl.display_flush(wlc.display)
		wlc.cursor_sent = WL_CURSOR_SENT_HIDDEN
		return
	}
	if wlc.cursor_shape_manager == nil { wl_theme_cursor(w, c); return }
	if wlc.cursor_shape_device == nil {
		wlc.cursor_shape_device = wl.proxy_marshal_flags(wlc.cursor_shape_manager, WP_CURSOR_SHAPE_MANAGER_GET_POINTER,
			&wp_cursor_shape_device_iface, wl.proxy_get_version(wlc.cursor_shape_manager), 0, nil, wlc.pointer)
	}
	if wlc.cursor_shape_device == nil { return }
	shape := wl_shape_for_cursor(c)
	wl.proxy_marshal_flags(wlc.cursor_shape_device, WP_CURSOR_SHAPE_DEVICE_SET_SHAPE, nil, wl.proxy_get_version(wlc.cursor_shape_device), 0, wlc.enter_serial, u32(shape))
	wlc.cursor_sent = u64(shape)
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
