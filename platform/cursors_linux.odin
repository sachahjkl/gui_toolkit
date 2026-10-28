#+build linux
package platform

// Cursors on Linux. Wayland names a cursor shape to the compositor (wp_cursor_shape_v1 where it is offered) or sets a
// pixel buffer from the user's cursor theme; X11 sets a themed cursor (Xcursor) on the window. Both are reached through
// the same public API as Windows (set_cursor, custom_cursor_create...). This file keeps the toolkit's side — which
// cursor each window wants, the custom-cursor store counted by key, the scheme (light / dark pointer) — and applies it
// through the backend. The visual apply over the compositor is best effort for now (the shape is tracked and sent
// where the protocol is bound); the store, the shapes (cursor_shapes.odin) and the queries are complete.
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

// The size a cursor has on the window's monitor, in physical pixels (the theme's base size scaled by DPI). The XCURSOR_SIZE
// environment variable overrides the base; 24 is the common default.
cursor_size_px :: proc(w: ^Window) -> int {
	base := 24
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

// Backend apply points. The full themed-cursor upload (a wl_buffer from the theme, or an Xcursor handle) is the
// remaining visual work; these keep the window's choice and are where it is sent.
@(private) wl_apply_cursor :: proc(w: ^Window) {}
@(private) x11_apply_cursor :: proc(w: ^Window) {}

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
		delete(e.pixels)
		e.pixels = nil
		if w.custom_cursor == cc { w.custom_cursor = 0 }
	}
}

custom_cursor_valid :: proc(w: ^Window, cc: Custom_Cursor) -> bool { return custom_entry(w, cc) != nil }

custom_cursor_stats :: proc(w: ^Window) -> (images, handles: int) {
	for &e in w.custom_cursors { if e.refs > 0 { images += 1 } }
	return images, 0   // no themed handles are materialised on Linux yet
}

custom_cursor_info :: proc(w: ^Window, cc: Custom_Cursor, scale: f32 = 0) -> Cursor_Info {
	e := custom_entry(w, cc)
	if e == nil { return {} }
	return {size = e.size, hot = {int(e.hot.x), int(e.hot.y)}, source = .System, ok = true}
}

@(private)
cursors_destroy :: proc(w: ^Window) {
	for &e in w.custom_cursors { if e.pixels != nil { delete(e.pixels) } }
	delete(w.custom_cursors)
	w.custom_cursors = nil
}
