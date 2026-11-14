#+build windows
package capture

// The pointer drawn over an output's picture (set_cursor): Desktop Duplication hands the pointer apart from the
// picture, and GDI's copy of the screen has none. The system draws it here as it draws it on the screen (DrawIconEx:
// a colour cursor with its alpha, a monochrome one that inverts what is under it), over a copy of the pixels under it.

import win "core:sys/windows"

foreign import user32_cursor "system:User32.lib"
foreign import gdi32_cursor "system:Gdi32.lib"

@(default_calling_convention = "system", private = "file")
foreign user32_cursor {
	GetIconInfo :: proc(icon: win.HICON, info: ^win.ICONINFO) -> win.BOOL ---
	DrawIconEx :: proc(dc: win.HDC, x, y: i32, icon: win.HICON, w, h: i32, step: u32, brush: win.HBRUSH, flags: u32) -> win.BOOL ---
}

@(default_calling_convention = "system", private = "file")
foreign gdi32_cursor {
	@(link_name = "GdiFlush") gdi_flush :: proc() -> win.BOOL ---
}

@(private = "file") DI_NORMAL :: 0x0003
@(private = "file") CURSOR_SHOWING :: 0x0001

// Draws the pointer into `f`, an output's picture (B, G, R, A) whose pixels cover `physical`: the output's rect in the
// virtual desktop's physical pixels, what GetCursorInfo's position is in to this per-monitor aware thread. Nothing when
// the pointer is hidden or on another output.
@(private)
pointer_paint :: proc(f: ^Frame, physical: Rect) {
	if f.order != .BGRA || physical.w <= 0 || physical.h <= 0 || f.width <= 0 || f.height <= 0 { return }
	ci := win.CURSORINFO{cbSize = size_of(win.CURSORINFO)}
	if !win.GetCursorInfo(&ci) || ci.flags & CURSOR_SHOWING == 0 || ci.hCursor == nil { return }
	icon := win.HICON(ci.hCursor)
	info: win.ICONINFO
	if !GetIconInfo(icon, &info) { return }
	// (GetIconInfo hands copies of the cursor's bitmaps: they are ours to delete)
	defer {
		if info.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(info.hbmMask)) }
		if info.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(info.hbmColor)) }
	}
	// Its size: the colour bitmap's; a monochrome cursor has only the mask, its AND half over its XOR half.
	bm: win.BITMAP
	size: [2]i32
	if info.hbmColor != nil && win.GetObjectW(win.HANDLE(info.hbmColor), size_of(win.BITMAP), &bm) != 0 {
		size = {bm.bmWidth, bm.bmHeight}
	} else if info.hbmMask != nil && win.GetObjectW(win.HANDLE(info.hbmMask), size_of(win.BITMAP), &bm) != 0 {
		size = {bm.bmWidth, bm.bmHeight / 2}
	}
	if size.x <= 0 || size.y <= 0 { return }
	// Its top left in the picture's pixels (a picture of the output is its physical size; the ratio stands for another).
	corner := [2]i32{ci.ptScreenPos.x - i32(info.xHotspot) - physical.x, ci.ptScreenPos.y - i32(info.yHotspot) - physical.y}
	at := [2]i32{i32(f64(corner.x) * f64(f.width) / f64(physical.w)), i32(f64(corner.y) * f64(f.height) / f64(physical.h))}
	dst, src, extent, ok := patch_clip({f.width, f.height}, at, size)
	if !ok { return }

	dc := win.CreateCompatibleDC(nil)
	if dc == nil { return }
	defer win.DeleteDC(dc)
	bmi := win.BITMAPINFO{bmiHeader = {
		biSize        = size_of(win.BITMAPINFOHEADER),
		biWidth       = size.x,
		biHeight      = -size.y,   // negative: rows top to bottom, as the frame's
		biPlanes      = 1,
		biBitCount    = 32,
		biCompression = win.BI_RGB,
	}}
	bits: rawptr
	bitmap := win.CreateDIBSection(dc, &bmi, win.DIB_RGB_COLORS, &bits, nil, 0)
	if bitmap == nil || bits == nil { return }
	defer win.DeleteObject(win.HGDIOBJ(bitmap))
	previous := win.SelectObject(dc, win.HGDIOBJ(bitmap))
	defer win.SelectObject(dc, previous)
	patch := ([^]u8)(bits)[:int(size.x) * int(size.y) * 4]
	row := int(extent.x) * 4
	// (what is under the pointer first: a cursor that inverts, or is translucent, is drawn over it)
	for y in 0 ..< int(extent.y) {
		from := f.pixels[(int(dst.y) + y) * int(f.stride) + int(dst.x) * 4:][:row]
		copy(patch[((int(src.y) + y) * int(size.x) + int(src.x)) * 4:][:row], from)
	}
	gdi_flush()
	if !DrawIconEx(dc, 0, 0, icon, size.x, size.y, 0, nil, DI_NORMAL) { return }
	// (GDI batches its calls: the bits are there once the batch ran)
	gdi_flush()
	for y in 0 ..< int(extent.y) {
		to := f.pixels[(int(dst.y) + y) * int(f.stride) + int(dst.x) * 4:][:row]
		copy(to, patch[((int(src.y) + y) * int(size.x) + int(src.x)) * 4:][:row])
		// (GDI leaves the alpha as it pleases: a screen is opaque)
		for x := 3; x < row; x += 4 { to[x] = 255 }
	}
}
