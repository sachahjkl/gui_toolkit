#+build windows
package platform

import "core:math"
import win "core:sys/windows"

// Cursors on Windows. A Cursor is the system's own when Windows has it (cursor_system_id: the user's scheme and size,
// shared handles loaded once, never destroyed), else drawn by the toolkit (cursor_shapes.odin) at the size the
// system's cursors have on the window's monitor (SM_CXCURSOR at its dpi) and in the colours of the user's scheme (white
// or black pointer); drawn cursors are made once per size and scheme, again when the cursor settings change
// (WM_SETTINGCHANGE SPI_SETCURSORS), and destroyed with the window. None hides the pointer over the client area.
//
// Custom cursors (custom_cursor_create) come from an RGBA image and a hotspot, for CSS `cursor: url(...)`: kept by
// the window, shared through a key and counted references, made into system cursors on demand at each scale they are
// shown at (a few per image), and destroyed by custom_cursor_release or with the window.
//
// The cursor is set in WM_SETCURSOR over the client area (the system keeps its own over the frame, the resize bands
// and the caption of an integrated title bar), and at once by set_cursor / set_cursor_custom when it changes while the
// pointer is over the client area or captured by the window (no WM_SETCURSOR comes during a capture, nor until the
// pointer moves): no frame is needed while the pointer moves over the same thing, and no flash of another cursor.

Cursor_Source :: enum u8 { System, Drawn, Hidden }

// Where cursor `c` comes from on Windows.
cursor_source :: proc(c: Cursor) -> Cursor_Source {
	if c == .None { return .Hidden }
	if _, ok := cursor_system_id(c); ok { return .System }
	return .Drawn
}

// The IDC_* resource of the system cursor for `c` (ok = false: the system has none; it is drawn).
cursor_system_id :: proc(c: Cursor) -> (id: cstring, ok: bool) {
	switch c {
	case .Arrow:                               return win.IDC_ARROW, true
	case .Hand:                                return win.IDC_HAND, true
	case .Text:                                return win.IDC_IBEAM, true
	case .Resize_H, .Resize_E, .Resize_W:      return win.IDC_SIZEWE, true
	case .Resize_V, .Resize_N, .Resize_S:      return win.IDC_SIZENS, true
	case .Resize_NE, .Resize_SW, .Resize_NESW: return win.IDC_SIZENESW, true
	case .Resize_NW, .Resize_SE, .Resize_NWSE: return win.IDC_SIZENWSE, true
	case .Move, .All_Scroll:                   return win.IDC_SIZEALL, true
	case .Not_Allowed:                         return win.IDC_NO, true
	case .Help:                                return win.IDC_HELP, true
	case .Progress:                            return win.IDC_APPSTARTING, true
	case .Wait:                                return win.IDC_WAIT, true
	case .Crosshair:                           return win.IDC_CROSS, true
	case .None, .Context_Menu, .Cell, .Vertical_Text, .Alias, .Copy, .No_Drop, .Grab, .Grabbing,
	     .Col_Resize, .Row_Resize, .Zoom_In, .Zoom_Out:
		return nil, false
	}
	return nil, false
}

@(private) Drawn_Cursor :: struct { c: Cursor, px: int, scheme: Cursor_Scheme, handle: win.HCURSOR }

@(private) Custom_Variant :: struct { px: [2]int, handle: win.HCURSOR, used: u64 }

@(private)
Custom_Entry :: struct {
	gen:      u32,
	refs:     int,
	key:      u64,
	pixels:   []u8,       // RGBA8 straight alpha
	size:     [2]int,     // image pixels
	hot:      [2]f32,     // image pixels
	density:  f32,        // image pixels per CSS pixel
	variants: [CUSTOM_VARIANTS]Custom_Variant,
}

@(private) CUSTOM_VARIANTS :: 4

// Per window (Native_Window.cursors).
@(private)
Cursor_State :: struct {
	custom:       Custom_Cursor,   // shown instead of Window.cursor while it is valid
	custom_scale: f32,             // device pixels per CSS pixel it is shown at
	shown:        win.HCURSOR,     // what WM_SETCURSOR sets (nil: hidden)
	resolved:     bool,            // shown is current
	drawn:        [dynamic]Drawn_Cursor,
	customs:      [dynamic]Custom_Entry,
	clock:        u64,
}

@(private) system_handles: [Cursor]win.HCURSOR
@(private) cursor_settings_ok: bool       // cursor_base_px and cursor_scheme are current
@(private) cursor_base_px: int            // the pointer size at 96 dpi
@(private) cursor_scheme_cached: Cursor_Scheme

// The size of the system's cursors at 96 dpi (SM_CXCURSOR: 32 by default).
cursor_base_size :: proc() -> int {
	settings_refresh()
	return cursor_base_px
}

// The colours of the user's pointer scheme, from the system's arrow: mostly dark pixels are a black pointer.
cursor_scheme :: proc() -> Cursor_Scheme {
	settings_refresh()
	return cursor_scheme_cached
}

// The cursor settings changed (WM_SETTINGCHANGE SPI_SETCURSORS, which the window handles itself): sizes and colours
// are read again and drawn cursors are made again.
cursor_settings_changed :: proc() { cursor_settings_ok = false }

@(private)
settings_refresh :: proc() {
	if cursor_settings_ok { return }
	cursor_settings_ok = true
	// (SM_CXCURSOR, the size of the cursors the system makes, rather than the pointer size of the accessibility settings
	// in the registry (CursorBaseSize): with a larger pointer the system's cursor objects need not be larger, and the
	// drawn ones must be as large as those they stand next to)
	cursor_base_px = 32
	if m := win.GetSystemMetricsForDpi(win.SM_CXCURSOR, 96); m >= 16 && m <= 512 { cursor_base_px = int(m) }
	cursor_scheme_cached = detect_scheme()
}

foreign import user32_cursors "system:User32.lib"
@(default_calling_convention = "system", private)
foreign user32_cursors {
	DrawIconEx :: proc(hdc: win.HDC, x, y: i32, icon: win.HICON, cx, cy: i32, step: u32, brush: win.HBRUSH, flags: u32) -> win.BOOL ---
}

// The system's arrow drawn over white and over black: the pixels that come out the same are its own (opaque); their
// mean brightness tells a white pointer from a black one. (An inverting scheme has none: Light.)
@(private)
detect_scheme :: proc() -> Cursor_Scheme {
	N :: 32
	arrow := win.HCURSOR(win.LoadImageW(nil, transmute(win.LPCWSTR)uintptr(32512), win.IMAGE_CURSOR, N, N, win.LR_SHARED))
	if arrow == nil { return .Light }
	dc := win.CreateCompatibleDC(nil)
	if dc == nil { return .Light }
	defer win.DeleteDC(dc)
	shots: [2][]u32
	for bg, i in ([2]u32{0x00FFFFFF, 0}) {
		bmi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = N, biHeight = -N, biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
		bits: rawptr
		bmp := win.CreateDIBSection(dc, &bmi, win.DIB_RGB_COLORS, &bits, nil, 0)
		if bmp == nil || bits == nil { return .Light }
		defer win.DeleteObject(win.HGDIOBJ(bmp))
		px := ([^]u32)(bits)[:N * N]
		for &p in px { p = bg }
		old := win.SelectObject(dc, win.HGDIOBJ(bmp))
		DrawIconEx(dc, 0, 0, win.HICON(arrow), N, N, 0, nil, 0x0003)   // DI_NORMAL
		win.SelectObject(dc, old)
		shots[i] = make([]u32, N * N, context.temp_allocator)
		copy(shots[i], px)
	}
	sum, count := 0, 0
	for i in 0 ..< N * N {
		a, b := shots[0][i] & 0xFFFFFF, shots[1][i] & 0xFFFFFF
		if a != b { continue }
		sum += int((a & 0xFF) + ((a >> 8) & 0xFF) + ((a >> 16) & 0xFF)) / 3
		count += 1
	}
	if count == 0 { return .Light }
	return sum / count < 128 ? .Dark : .Light
}

// The size drawn cursors have on window `w` (its monitor's dpi).
cursor_size_px :: proc(w: ^Window) -> int {
	if w.hwnd != nil {
		if m := win.GetSystemMetricsForDpi(win.SM_CXCURSOR, win.GetDpiForWindow(w.hwnd)); m >= 16 && m <= 1024 { return int(m) }
	}
	return max(int(math.round(f32(cursor_base_size()) * max(w.dpi_scale, 0.5))), 16)
}

// A system cursor from RGBA8 pixels (straight alpha, top-down rows of `size.x` pixels). nil on failure.
@(private)
make_cursor :: proc(rgba: []u8, size: [2]int, hot: [2]int) -> win.HCURSOR {
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return nil }
	hdr := win.BITMAPV5HEADER{
		bV5Size = size_of(win.BITMAPV5HEADER), bV5Width = i32(size.x), bV5Height = -i32(size.y), bV5Planes = 1, bV5BitCount = 32,
		bV5Compression = win.BI_BITFIELDS, bV5RedMask = 0x00FF0000, bV5GreenMask = 0x0000FF00, bV5BlueMask = 0x000000FF, bV5AlphaMask = 0xFF000000,
	}
	dc := win.GetDC(nil)
	bits: rawptr
	color := win.CreateDIBSection(dc, (^win.BITMAPINFO)(&hdr), win.DIB_RGB_COLORS, &bits, nil, 0)
	win.ReleaseDC(nil, dc)
	if color == nil || bits == nil { return nil }
	defer win.DeleteObject(win.HGDIOBJ(color))
	dst := ([^]u8)(bits)[:size.x * size.y * 4]
	for i := 0; i < len(dst); i += 4 {
		dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3]
	}
	mask := win.CreateBitmap(i32(size.x), i32(size.y), 1, 1, nil)   // all 0: the colour bitmap's alpha decides
	if mask == nil { return nil }
	defer win.DeleteObject(win.HGDIOBJ(mask))
	info := win.ICONINFO{fIcon = false, xHotspot = u32(clamp(hot.x, 0, size.x - 1)), yHotspot = u32(clamp(hot.y, 0, size.y - 1)), hbmMask = mask, hbmColor = color}
	return win.HCURSOR(win.CreateIconIndirect(&info))
}

@(private)
system_handle :: proc(c: Cursor) -> win.HCURSOR {
	if system_handles[c] == nil {
		if id, ok := cursor_system_id(c); ok { system_handles[c] = win.LoadCursorA(nil, id) }
	}
	return system_handles[c]
}

// The handle for `c` on `w`: nil for None (and for a drawn cursor that could not be made: the arrow then).
@(private)
cursor_handle :: proc(w: ^Window, c: Cursor) -> win.HCURSOR {
	switch cursor_source(c) {
	case .Hidden: return nil
	case .System: return system_handle(c)
	case .Drawn:
		cs := &w.cursors
		px, scheme := cursor_size_px(w), cursor_scheme()
		for d in cs.drawn { if d.c == c && d.px == px && d.scheme == scheme { return d.handle } }
		// sizes or colours that are no longer in use go (a DPI change, a new scheme), but the one shown
		for i := len(cs.drawn) - 1; i >= 0; i -= 1 {
			d := cs.drawn[i]
			if (d.px != px || d.scheme != scheme) && d.handle != cs.shown {
				win.DestroyCursor(d.handle)
				unordered_remove(&cs.drawn, i)
			}
		}
		img, ok := cursor_draw(c, px, scheme, context.temp_allocator)
		if !ok { return system_handle(.Arrow) }
		h := make_cursor(img.pixels, {img.size, img.size}, img.hot)
		if h == nil { return system_handle(.Arrow) }
		append(&cs.drawn, Drawn_Cursor{c = c, px = px, scheme = scheme, handle = h})
		return h
	}
	return nil
}

// What a cursor is on this window, for tests and diagnostics: its handle, its bitmap's size and its hotspot.
Cursor_Info :: struct {
	handle: rawptr,
	size:   [2]int,
	hot:    [2]int,
	source: Cursor_Source,
	ok:     bool,
}

@(private)
handle_info :: proc(h: win.HCURSOR) -> (info: Cursor_Info) {
	info.handle = rawptr(h)
	if h == nil { return }
	ii: win.ICONINFO
	if !GetIconInfo(win.HICON(h), &ii) { return }
	defer { if ii.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmColor)) }; if ii.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(ii.hbmMask)) } }
	bm: win.BITMAP
	src := ii.hbmColor != nil ? ii.hbmColor : ii.hbmMask
	if win.GetObjectW(win.HANDLE(src), size_of(bm), &bm) == 0 { return }
	info.size = {int(bm.bmWidth), int(bm.bmHeight)}
	if ii.hbmColor == nil { info.size.y /= 2 }   // a monochrome cursor: AND and XOR masks stacked
	info.hot = {int(ii.xHotspot), int(ii.yHotspot)}
	info.ok = true
	return
}

cursor_info :: proc(w: ^Window, c: Cursor) -> Cursor_Info {
	info := handle_info(cursor_handle(w, c))
	info.source = cursor_source(c)
	if info.source == .Hidden { info.ok = true }
	return info
}

// A cursor as the system draws it (DrawIconEx) over an opaque `background`, `size` x `size` pixels: RGBA8 (opaque), for
// previews and tests. nil when `handle` is nil or the drawing fails.
cursor_render :: proc(handle: rawptr, size: int, background: [3]u8, allocator := context.allocator) -> []u8 {
	if handle == nil || size <= 0 { return nil }
	dc := win.CreateCompatibleDC(nil)
	if dc == nil { return nil }
	defer win.DeleteDC(dc)
	bmi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(size), biHeight = -i32(size), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	bits: rawptr
	bmp := win.CreateDIBSection(dc, &bmi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bmp == nil || bits == nil { return nil }
	defer win.DeleteObject(win.HGDIOBJ(bmp))
	px := ([^]u8)(bits)[:size * size * 4]
	for i := 0; i < len(px); i += 4 { px[i], px[i + 1], px[i + 2], px[i + 3] = background[2], background[1], background[0], 255 }
	old := win.SelectObject(dc, win.HGDIOBJ(bmp))
	ok := DrawIconEx(dc, 0, 0, win.HICON(handle), i32(size), i32(size), 0, nil, 0x0003)   // DI_NORMAL
	win.SelectObject(dc, old)
	if !ok { return nil }
	out := make([]u8, size * size * 4, allocator)
	for i := 0; i < len(out); i += 4 { out[i], out[i + 1], out[i + 2], out[i + 3] = px[i + 2], px[i + 1], px[i], 255 }
	return out
}

// The cursor the window shows over its client area now (nil: hidden).
shown_cursor :: proc(w: ^Window) -> rawptr {
	if !w.cursors.resolved { resolve_cursor(w) }
	return rawptr(w.cursors.shown)
}

// The handle of a cursor as set_cursor would show it (to compare with shown_cursor or GetCursorInfo).
cursor_handle_of :: proc(w: ^Window, c: Cursor) -> rawptr { return rawptr(cursor_handle(w, c)) }

////////////////////////////////
// Setting the cursor

set_cursor :: proc(w: ^Window, c: Cursor) {
	if w.cursor == c && w.cursors.custom == 0 && w.cursors.resolved { return }
	w.cursor = c
	w.cursors.custom = 0
	apply_cursor(w)
}

// Shows custom cursor `cc` at `scale` device pixels per CSS pixel (0: the window's dpi scale; a page zoom multiplies
// it), `fallback` while it is not valid (released, or it cannot be made at that scale). cc = 0: set_cursor(fallback).
set_cursor_custom :: proc(w: ^Window, cc: Custom_Cursor, fallback: Cursor, scale: f32 = 0) {
	sc := scale > 0 ? scale : w.dpi_scale
	cs := &w.cursors
	if w.cursor == fallback && cs.custom == cc && cs.custom_scale == sc && cs.resolved { return }
	w.cursor = fallback
	cs.custom, cs.custom_scale = cc, sc
	apply_cursor(w)
}

@(private)
resolve_cursor :: proc(w: ^Window) -> win.HCURSOR {
	cs := &w.cursors
	h: win.HCURSOR
	have := false
	if cs.custom != 0 {
		if ch := custom_handle(w, cs.custom, cs.custom_scale); ch != nil { h, have = ch, true }
	}
	if !have { h = cursor_handle(w, w.cursor) }
	cs.shown, cs.resolved = h, true
	return h
}

// Resolves the cursor and shows it now when the pointer is over the client area (or the window has the capture).
@(private)
apply_cursor :: proc(w: ^Window) {
	h := resolve_cursor(w)
	if w.hwnd == nil { return }
	if win.GetCapture() == w.hwnd || pointer_hit(w) == win.HTCLIENT { win.SetCursor(h) }
}

// Called on WM_SETCURSOR over the client area.
@(private)
cursor_on_setcursor :: proc(w: ^Window) {
	win.SetCursor(w.cursors.resolved ? w.cursors.shown : resolve_cursor(w))
}

// The monitor's dpi changed: drawn and custom cursors are made at the new size.
// (A custom cursor follows when the app sets it again with the new scale: set_cursor_custom with scale 0 takes it.)
@(private)
cursor_on_dpi_change :: proc(w: ^Window) {
	w.cursors.resolved = false
	apply_cursor(w)
}

////////////////////////////////
// Custom cursors

@(private)
custom_entry :: proc(w: ^Window, cc: Custom_Cursor) -> ^Custom_Entry {
	idx := int(u64(cc) & 0xFFFF_FFFF) - 1
	gen := u32(u64(cc) >> 32)
	if idx < 0 || idx >= len(w.cursors.customs) { return nil }
	e := &w.cursors.customs[idx]
	if e.refs <= 0 || e.gen != gen { return nil }
	return e
}

// A cursor from an image: `rgba` (RGBA8, straight alpha, top-down rows) of `size` pixels, the hotspot in image pixels
// (clamped into the image, as CSS says), `density` image pixels per CSS pixel (2 for an image-set() 2x candidate; an
// SVG rasterized for one scale passes that scale). An image larger than `max_css` CSS pixels on a side is refused
// (.Too_Large: the caller shows its fallback). With a `key` (any nonzero value naming the image, its pixels and
// hotspot) an entry made earlier with the same key is shared: one more reference, nothing copied. The pixels are
// copied; release with custom_cursor_release.
custom_cursor_create :: proc(w: ^Window, rgba: []u8, size: [2]int, hot: [2]f32, density: f32 = 1, key: u64 = 0, max_css := CUSTOM_CURSOR_MAX_CSS) -> (Custom_Cursor, Custom_Cursor_Error) {
	cs := &w.cursors
	if key != 0 {
		for &e, i in cs.customs {
			if e.refs > 0 && e.key == key {
				e.refs += 1
				return Custom_Cursor(u64(e.gen) << 32 | u64(i + 1)), .None
			}
		}
	}
	if size.x <= 0 || size.y <= 0 || len(rgba) < size.x * size.y * 4 { return 0, .Bad_Size }
	d := density > 0 ? density : 1
	if f32(size.x) / d > f32(max_css) + 0.001 || f32(size.y) / d > f32(max_css) + 0.001 { return 0, .Too_Large }
	slot := -1
	for e, i in cs.customs { if e.refs <= 0 { slot = i; break } }
	if slot < 0 {
		append(&cs.customs, Custom_Entry{})
		slot = len(cs.customs) - 1
	}
	e := &cs.customs[slot]
	gen := e.gen + 1
	e^ = Custom_Entry{
		gen = gen, refs = 1, key = key, size = size, density = d,
		hot = {clamp(hot.x, 0, f32(size.x - 1)), clamp(hot.y, 0, f32(size.y - 1))},
	}
	e.pixels = make([]u8, size.x * size.y * 4)
	copy(e.pixels, rgba[:size.x * size.y * 4])
	return Custom_Cursor(u64(gen) << 32 | u64(slot + 1)), .None
}

// One reference less; the last one destroys the image and its system cursors (the window falls back to its keyword
// cursor if it showed this one).
custom_cursor_release :: proc(w: ^Window, cc: Custom_Cursor) {
	e := custom_entry(w, cc)
	if e == nil { return }
	e.refs -= 1
	if e.refs > 0 { return }
	cs := &w.cursors
	if cs.custom == cc {
		cs.custom = 0
		apply_cursor(w)   // off this image's handles before they go
	}
	for &v in e.variants {
		if v.handle != nil {
			if v.handle == cs.shown { cs.shown, cs.resolved = nil, false }
			win.DestroyCursor(v.handle)
		}
		v = {}
	}
	delete(e.pixels)
	e.pixels = nil
	e.refs = 0
}

// Whether `cc` is a live custom cursor of `w`.
custom_cursor_valid :: proc(w: ^Window, cc: Custom_Cursor) -> bool { return custom_entry(w, cc) != nil }

// Live custom cursors of `w` and the system cursors made from them (tests, diagnostics).
custom_cursor_stats :: proc(w: ^Window) -> (images, handles: int) {
	for e in w.cursors.customs {
		if e.refs <= 0 { continue }
		images += 1
		for v in e.variants { if v.handle != nil { handles += 1 } }
	}
	return
}

// What `cc` shows at `scale` (0: the window's): Cursor_Info.ok = false when it cannot be made.
custom_cursor_info :: proc(w: ^Window, cc: Custom_Cursor, scale: f32 = 0) -> Cursor_Info {
	info := handle_info(custom_handle(w, cc, scale > 0 ? scale : w.dpi_scale))
	info.source = .System
	return info
}

// The system cursor of `cc` at `scale`: the image resized to its CSS size times the scale, made once per size.
@(private)
custom_handle :: proc(w: ^Window, cc: Custom_Cursor, scale: f32) -> win.HCURSOR {
	e := custom_entry(w, cc)
	if e == nil { return nil }
	cs := &w.cursors
	k := scale / e.density
	px := [2]int{max(int(math.round(f32(e.size.x) * k)), 1), max(int(math.round(f32(e.size.y) * k)), 1)}
	cs.clock += 1
	for &v in e.variants {
		if v.handle != nil && v.px == px { v.used = cs.clock; return v.handle }
	}
	pixels := e.pixels
	if px != e.size { pixels = cursor_resample(e.pixels, e.size.x, e.size.y, px.x, px.y, context.temp_allocator) }
	hot := [2]int{int(e.hot.x * f32(px.x) / f32(e.size.x)), int(e.hot.y * f32(px.y) / f32(e.size.y))}
	h := make_cursor(pixels, px, hot)
	if h == nil { return nil }
	// a free slot, else the least recently used one that is not shown
	slot := -1
	for v, i in e.variants { if v.handle == nil { slot = i; break } }
	if slot < 0 {
		for v, i in e.variants {
			if v.handle == cs.shown { continue }
			if slot < 0 || v.used < e.variants[slot].used { slot = i }
		}
		if slot < 0 { slot = 0 }
		if e.variants[slot].handle != nil { win.DestroyCursor(e.variants[slot].handle) }
	}
	e.variants[slot] = {px = px, handle = h, used = cs.clock}
	return h
}

// Destroys every cursor the window made (drawn and custom). The window goes on with the system's arrow.
@(private)
cursors_destroy :: proc(w: ^Window) {
	cs := &w.cursors
	if cs.shown != nil && win.GetCapture() == w.hwnd { win.SetCursor(system_handle(.Arrow)) }
	for d in cs.drawn { win.DestroyCursor(d.handle) }
	delete(cs.drawn)
	for &e in cs.customs {
		for v in e.variants { if v.handle != nil { win.DestroyCursor(v.handle) } }
		delete(e.pixels)
	}
	delete(cs.customs)
	cs^ = {}
}
