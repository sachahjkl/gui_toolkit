#+build linux
package platform

// Cursors on Linux. Wayland names a cursor shape to the compositor (wp_cursor_shape_v1 where it is offered) or sets a
// pixel buffer from the user's cursor theme; X11 sets a themed cursor (Xcursor) on the window. Both are reached through
// the same public API as Windows (set_cursor, custom_cursor_create...). This file keeps the toolkit's side — which
// cursor each window wants, the custom-cursor store counted by key, the scheme (light / dark pointer) — and applies it
// through the backend (cursors_x11_linux.odin, cursors_wl_linux.odin).
//
// Custom cursors come from an RGBA image and a hotspot (CSS `cursor: url(...)`), kept by the window, shared through a
// key and counted references, and freed by custom_cursor_release or with the window.

// A custom cursor the window holds: its pixels and hotspot, reference-counted and keyed so the same image is kept once.
@(private)
Custom_Entry :: struct {
	gen:     u32,
	refs:    int,
	key:     u64,
	pixels:  []u8,     // RGBA8 straight alpha, owned
	size:    [2]int,
	hot:     [2]f32,
	density: f32,      // image pixels per CSS pixel
	// what the backend made of it, at made_scale
	x11_cursor: u32,
	wl_buffer:  Wl_Proxy,
	made_scale: f32,
}

// The older (X11) name of a cursor, for themes without the CSS one, and its glyph in the server's cursor font.
@(private)
cursor_older_name :: proc(c: Cursor) -> (name: string, glyph: u16) {
	XC_BOTTOM_LEFT_CORNER :: 12
	XC_BOTTOM_RIGHT_CORNER :: 14
	XC_BOTTOM_SIDE :: 16
	XC_CROSSHAIR :: 34
	XC_EXCHANGE :: 50
	XC_FLEUR :: 52
	XC_HAND1 :: 58
	XC_HAND2 :: 60
	XC_LEFT_PTR :: 68
	XC_LEFT_SIDE :: 70
	XC_PIRATE :: 88
	XC_PLUS :: 90
	XC_QUESTION_ARROW :: 92
	XC_RIGHT_SIDE :: 96
	XC_SB_H_DOUBLE_ARROW :: 108
	XC_SB_V_DOUBLE_ARROW :: 116
	XC_TOP_LEFT_CORNER :: 134
	XC_TOP_RIGHT_CORNER :: 136
	XC_TOP_SIDE :: 138
	XC_WATCH :: 150
	XC_XTERM :: 152
	switch c {
	case .Arrow, .Context_Menu, .None: return "left_ptr", XC_LEFT_PTR
	case .Hand:          return "hand2", XC_HAND2
	case .Text, .Vertical_Text: return "xterm", XC_XTERM
	case .Resize_H, .Col_Resize: return "sb_h_double_arrow", XC_SB_H_DOUBLE_ARROW
	case .Resize_V, .Row_Resize: return "sb_v_double_arrow", XC_SB_V_DOUBLE_ARROW
	case .Move, .All_Scroll: return "fleur", XC_FLEUR
	case .Not_Allowed, .No_Drop: return "crossed_circle", XC_PIRATE
	case .Help:          return "question_arrow", XC_QUESTION_ARROW
	case .Progress:      return "left_ptr_watch", XC_WATCH
	case .Wait:          return "watch", XC_WATCH
	case .Cell, .Zoom_In, .Zoom_Out: return "plus", XC_PLUS
	case .Crosshair:     return "crosshair", XC_CROSSHAIR
	case .Alias, .Copy:  return "dnd-copy", XC_EXCHANGE
	case .Grab:          return "hand1", XC_HAND1
	case .Grabbing:      return "grabbing", XC_HAND1
	case .Resize_N:      return "top_side", XC_TOP_SIDE
	case .Resize_E:      return "right_side", XC_RIGHT_SIDE
	case .Resize_S:      return "bottom_side", XC_BOTTOM_SIDE
	case .Resize_W:      return "left_side", XC_LEFT_SIDE
	case .Resize_NE, .Resize_NESW: return "top_right_corner", XC_TOP_RIGHT_CORNER
	case .Resize_NW, .Resize_NWSE: return "top_left_corner", XC_TOP_LEFT_CORNER
	case .Resize_SE:     return "bottom_right_corner", XC_BOTTOM_RIGHT_CORNER
	case .Resize_SW:     return "bottom_left_corner", XC_BOTTOM_LEFT_CORNER
	}
	return "left_ptr", XC_LEFT_PTR
}

// A custom cursor's pixels at a scale: premultiplied BGRA (what X RENDER and wl_shm take), scaled to the nearest pixel, with
// its hotspot.
@(private)
custom_cursor_bgra :: proc(e: ^Custom_Entry, scale: f32, allocator := context.allocator) -> (px: []u8, size: [2]int, hot: [2]int) {
	k := max(scale, 0.1) / e.density
	size = {max(int(f32(e.size.x) * k + 0.5), 1), max(int(f32(e.size.y) * k + 0.5), 1)}
	hot = {clamp(int(e.hot.x * k), 0, size.x - 1), clamp(int(e.hot.y * k), 0, size.y - 1)}
	px = make([]u8, size.x * size.y * 4, allocator)
	for y in 0 ..< size.y {
		sy := min(y * e.size.y / size.y, e.size.y - 1)
		for x in 0 ..< size.x {
			sx := min(x * e.size.x / size.x, e.size.x - 1)
			s := e.pixels[(sy * e.size.x + sx) * 4:][:4]
			d := px[(y * size.x + x) * 4:][:4]
			a := u32(s[3])
			d[0], d[1], d[2], d[3] = u8(u32(s[2]) * a / 255), u8(u32(s[1]) * a / 255), u8(u32(s[0]) * a / 255), s[3]
		}
	}
	return
}

// What the system shows of the window's cursor, to tell two apart: X's serial of the pointer image, or on Wayland what was
// last sent. For tests. ok = false when it cannot be asked.
cursor_on_screen :: proc(w: ^Window) -> (id: u64, ok: bool) {
	switch w.backend {
	case .X11:     return x11_pointer_image_serial()
	case .Wayland: return wlc.cursor_sent, true
	case .None:
	}
	return
}

Cursor_Source :: enum u8 { System, Drawn, Hidden }

// Every cursor has a system (themed) form on Linux except None (hidden). The toolkit draws none itself here (the
// themes are complete), so a cursor is System unless hidden.
cursor_source :: proc(c: Cursor) -> Cursor_Source { return c == .None ? .Hidden : .System }

Cursor_Info :: struct {
	handle: rawptr,
	size:   [2]int,
	hot:    [2]int,
	source: Cursor_Source,
	ok:     bool,
}

// The user's pointer scheme (light or dark). X cursor themes do not expose this cheaply; follow the desktop's dark
// preference (theme_linux.odin), as a dark theme usually ships a light pointer.
cursor_scheme :: proc() -> Cursor_Scheme { return dark_mode_preferred() ? .Dark : .Light }

cursor_settings_changed :: proc() {}   // re-read on demand; nothing cached to invalidate here

// The size a cursor has on the window's monitor, in physical pixels (a base size scaled by DPI: 24, the
// common default; XCURSOR_SIZE is read by the theme's own loader).
@(private = "file") CURSOR_THEME_BASE_PX :: 24
cursor_size_px :: proc(w: ^Window) -> int {
	base := CURSOR_THEME_BASE_PX
	return max(int(f32(base) * (w != nil ? w.dpi_scale : 1)), 1)
}

set_cursor :: proc(w: ^Window, c: Cursor) {
	if w == nil { return }
	w.custom_cursor = 0
	if w.cursor == c { return }
	w.cursor = c
	apply_cursor(w)
}

set_cursor_custom :: proc(w: ^Window, cc: Custom_Cursor, fallback: Cursor, scale: f32 = 0) {
	if w == nil { return }
	w.custom_cursor = cc
	w.custom_fallback = fallback
	apply_cursor(w)
}

@(private)
apply_cursor :: proc(w: ^Window) {
	if w.offscreen { return }
	// The shape the window wants now; the backend sends it. Wayland uses the serial of the last pointer enter.
	switch w.backend {
	case .Wayland: wl_apply_cursor(w)
	case .X11:     x11_apply_cursor(w)
	case .None:
	}
}

@(private)
cursor_on_setcursor :: proc(w: ^Window) { apply_cursor(w) }
@(private)
cursor_on_dpi_change :: proc(w: ^Window) { apply_cursor(w) }

shown_cursor :: proc(w: ^Window) -> rawptr { return nil }   // no shared system handle on Linux
cursor_handle_of :: proc(w: ^Window, c: Cursor) -> rawptr { return nil }

cursor_info :: proc(w: ^Window, c: Cursor) -> Cursor_Info {
	info := Cursor_Info{source = cursor_source(c)}
	size := cursor_size_px(w)
	info.size = {size, size}
	info.ok = true
	return info
}

// A cursor rendered over an opaque background for previews. On Linux the toolkit does not hold the themed pixels, so a
// drawn shape (cursor_shapes.odin) is used where one exists; otherwise nil. Returns RGBA8 (opaque).
cursor_render :: proc(handle: rawptr, size: int, background: [3]u8, allocator := context.allocator) -> []u8 {
	return nil
}

////////////////////////////////
// custom cursors (store keyed and reference-counted, mirroring the Win32 semantics)

@(private)
custom_entry :: proc(w: ^Window, cc: Custom_Cursor) -> ^Custom_Entry {
	if cc == 0 { return nil }
	idx := int(u64(cc) & 0xffffffff)
	gen := u32(u64(cc) >> 32)
	if idx <= 0 || idx > len(w.custom_cursors) { return nil }
	e := &w.custom_cursors[idx - 1]
	if e.gen != gen || e.refs <= 0 { return nil }
	return e
}

custom_cursor_create :: proc(w: ^Window, rgba: []u8, size: [2]int, hot: [2]f32, density: f32 = 1, key: u64 = 0, max_css := CUSTOM_CURSOR_MAX_CSS) -> (Custom_Cursor, Custom_Cursor_Error) {
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return 0, .Bad_Size }
	d := density > 0 ? density : 1
	css_w := f32(size.x) / d
	css_h := f32(size.y) / d
	if css_w > f32(max_css) || css_h > f32(max_css) { return 0, .Too_Large }
	// share by key
	if key != 0 {
		for &e, i in w.custom_cursors {
			if e.refs > 0 && e.key == key {
				e.refs += 1
				return Custom_Cursor(u64(e.gen) << 32 | u64(i + 1)), .None
			}
		}
	}
	// a free slot or a new one
	idx := -1
	for &e, i in w.custom_cursors { if e.refs <= 0 { idx = i; break } }
	pixels := make([]u8, len(rgba))
	copy(pixels, rgba)
	gen: u32 = 1
	if idx < 0 {
		append(&w.custom_cursors, Custom_Entry{})
		idx = len(w.custom_cursors) - 1
	} else {
		gen = w.custom_cursors[idx].gen + 1
	}
	w.custom_cursors[idx] = {gen = gen, refs = 1, key = key, pixels = pixels, size = size, hot = hot, density = d}
	return Custom_Cursor(u64(gen) << 32 | u64(idx + 1)), .None
}

custom_cursor_release :: proc(w: ^Window, cc: Custom_Cursor) {
	e := custom_entry(w, cc)
	if e == nil { return }
	e.refs -= 1
	if e.refs <= 0 {
		custom_backend_release(e)
		delete(e.pixels)
		e.pixels = nil
		if w.custom_cursor == cc { w.custom_cursor = 0 }
	}
}

custom_cursor_valid :: proc(w: ^Window, cc: Custom_Cursor) -> bool { return custom_entry(w, cc) != nil }

@(private)
custom_backend_release :: proc(e: ^Custom_Entry) {
	x11_custom_release(e)
	wl_custom_release(e)
}

custom_cursor_stats :: proc(w: ^Window) -> (images, handles: int) {
	for &e in w.custom_cursors { if e.refs > 0 { images += 1 } }
	for &e in w.custom_cursors { if e.refs > 0 && (e.x11_cursor != 0 || e.wl_buffer != nil) { handles += 1 } }
	return images, handles
}

custom_cursor_info :: proc(w: ^Window, cc: Custom_Cursor, scale: f32 = 0) -> Cursor_Info {
	e := custom_entry(w, cc)
	if e == nil { return {} }
	return {size = e.size, hot = {int(e.hot.x), int(e.hot.y)}, source = .System, ok = true}
}

@(private)
cursors_destroy :: proc(w: ^Window) {
	for &e in w.custom_cursors {
		custom_backend_release(&e)
		if e.pixels != nil { delete(e.pixels) }
	}
	delete(w.custom_cursors)
	w.custom_cursors = nil
}
