#+build windows
package tk_image

import win "core:sys/windows"

// The toolkit's own libwebp (native/webp: libwebp's and sharpyuv's sources, built by tools/tk build_webp), beside the
// program: gt_webp.dll, its calls named gt_webp_* (the DLL never stands in for another libwebp by its names).
@(private)
webp_load :: proc() {
	h := win.LoadLibraryW(win.L("gt_webp.dll"))
	if h == nil { return }
	l := &webp_lib
	l.encode_rgba = auto_cast win.GetProcAddress(h, "gt_webp_encode_rgba")
	l.encode_lossless_rgba = auto_cast win.GetProcAddress(h, "gt_webp_encode_lossless_rgba")
	l.decode_rgba = auto_cast win.GetProcAddress(h, "gt_webp_decode_rgba")
	l.free = auto_cast win.GetProcAddress(h, "gt_webp_free")
	if l.encode_rgba == nil || l.encode_lossless_rgba == nil || l.decode_rgba == nil || l.free == nil {
		win.FreeLibrary(h)
		webp_lib = {}
		return
	}
	webp_found = true
}
