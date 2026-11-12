package tk_desktop

// Thumbnails on Windows: the shell's, as Explorer shows them. IShellItemImageFactory::GetImage of the path's shell item
// with SIIGBF_THUMBNAILONLY (a thumbnail or nothing: never the type's icon, which file_icon gives), from the system's
// thumbnail cache or made by the type's handler (SIIGBF_INCACHEONLY: the cache only); a handler that has no thumbnail of
// that size is asked for a larger one, reduced here. Its bitmap is 32-bit BGRA, premultiplied: read back as straight
// RGBA. COM is started once on each thread that asks (com_thread_start). The shell fills its cache itself:
// thumbnail_store writes nothing.

import "base:runtime"
import win "core:sys/windows"

@(private = "file") SIIGBF_BIGGERSIZEOK  :: 0x01
@(private = "file") SIIGBF_THUMBNAILONLY :: 0x08
@(private = "file") SIIGBF_INCACHEONLY   :: 0x10

// IShellItemImageFactory's interface id.
@(private = "file", rodata)
IID_IShellItemImageFactory := win.GUID{0xBCC18B79, 0xBA16, 0x442F, {0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B}}

@(private = "file")
IShellItemImageFactory :: struct { using vtbl: ^IShellItemImageFactory_Vtbl }
@(private = "file")
IShellItemImageFactory_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IShellItemImageFactory, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IShellItemImageFactory) -> u32,
	Release:        proc "system" (this: ^IShellItemImageFactory) -> u32,
	GetImage:       proc "system" (this: ^IShellItemImageFactory, size: win.SIZE, flags: i32, bitmap: ^win.HBITMAP) -> win.HRESULT,
}

@(private)
thumbnail_native :: proc(path: string, size: int, mode: Thumbnail_Mode, allocator: runtime.Allocator) -> (thumb: Thumbnail, ok: bool) {
	com_thread_start()
	factory: ^IShellItemImageFactory
	wpath := win.utf8_to_wstring(path, context.temp_allocator)
	if win.SHCreateItemFromParsingName(wpath, nil, &IID_IShellItemImageFactory, (^rawptr)(&factory)) < 0 || factory == nil { return }
	defer factory->Release()
	flags := i32(SIIGBF_THUMBNAILONLY)
	if mode == .Cached { flags |= SIIGBF_INCACHEONLY }
	side := win.SIZE{i32(size), i32(size)}
	bitmap: win.HBITMAP
	if factory->GetImage(side, flags, &bitmap) < 0 || bitmap == nil {
		bitmap = nil
		if factory->GetImage(side, flags | SIIGBF_BIGGERSIZEOK, &bitmap) < 0 || bitmap == nil { return }
	}
	defer win.DeleteObject(win.HGDIOBJ(bitmap))
	rgba, w, h, read := bitmap_rgba(bitmap, allocator)
	if !read { return }
	return thumbnail_fit(rgba, w, h, size, allocator), true
}

@(private)
thumbnail_store_native :: proc(path: string, rgba: []u8, width, height: int) -> bool { return false }

// A 32-bit bitmap of the shell as straight RGBA, rows from the top. Its pixels are BGRA with the alpha premultiplied; a
// bitmap whose alpha is 0 everywhere (a picture with none: a photo's thumbnail) is opaque.
@(private = "file")
bitmap_rgba :: proc(bitmap: win.HBITMAP, allocator: runtime.Allocator) -> (rgba: []u8, w, h: int, ok: bool) {
	bm: win.BITMAP
	if win.GetObjectW(win.HANDLE(bitmap), size_of(bm), &bm) == 0 { return }
	w, h = int(bm.bmWidth), abs(int(bm.bmHeight))
	if w <= 0 || h <= 0 { return }
	bi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(w), biHeight = -i32(h), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	px := make([]u8, w * h * 4, allocator)
	dc := win.CreateCompatibleDC(nil)
	defer win.DeleteDC(dc)
	if win.GetDIBits(dc, bitmap, 0, u32(h), raw_data(px), &bi, win.DIB_RGB_COLORS) == 0 {
		delete(px, allocator)
		return nil, 0, 0, false
	}
	any_alpha := false
	for i := 3; i < len(px); i += 4 { if px[i] != 0 { any_alpha = true; break } }
	for i := 0; i < len(px); i += 4 {
		b, g, r, a := u32(px[i]), u32(px[i + 1]), u32(px[i + 2]), u32(px[i + 3])
		if !any_alpha {
			a = 255
		} else if a > 0 && a < 255 {
			r, g, b = min(255, (r * 255 + a / 2) / a), min(255, (g * 255 + a / 2) / a), min(255, (b * 255 + a / 2) / a)
		}
		px[i], px[i + 1], px[i + 2], px[i + 3] = u8(r), u8(g), u8(b), u8(a)
	}
	return px, w, h, true
}
