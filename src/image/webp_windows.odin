#+build windows
package tk_image

import win "core:sys/windows"

@(private)
webp_load :: proc() {
	h := win.LoadLibraryW(win.L("libwebp.dll"))
	if h == nil { return }
	l := &webp_lib
	l.encode_rgba = auto_cast win.GetProcAddress(h, "WebPEncodeRGBA")
	l.encode_lossless_rgba = auto_cast win.GetProcAddress(h, "WebPEncodeLosslessRGBA")
	l.decode_rgba = auto_cast win.GetProcAddress(h, "WebPDecodeRGBA")
	l.free = auto_cast win.GetProcAddress(h, "WebPFree")
	if l.encode_rgba == nil || l.encode_lossless_rgba == nil || l.decode_rgba == nil || l.free == nil {
		win.FreeLibrary(h)
		webp_lib = {}
		return
	}
	webp_found = true
}
