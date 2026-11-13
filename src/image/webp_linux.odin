#+build linux
package tk_image

import "core:sys/posix"

@(private)
webp_load :: proc() {
	for name in ([]cstring{"libwebp.so.7", "libwebp.so"}) {
		h := posix.dlopen(name, posix.RTLD_LOCAL + {.NOW})
		if h == nil { continue }
		l := &webp_lib
		l.encode_rgba = auto_cast posix.dlsym(h, "WebPEncodeRGBA")
		l.encode_lossless_rgba = auto_cast posix.dlsym(h, "WebPEncodeLosslessRGBA")
		l.decode_rgba = auto_cast posix.dlsym(h, "WebPDecodeRGBA")
	l.free = auto_cast posix.dlsym(h, "WebPFree")
		if l.encode_rgba == nil || l.encode_lossless_rgba == nil || l.decode_rgba == nil || l.free == nil {
			posix.dlclose(h)
			webp_lib = {}
			continue
		}
		webp_found = true
		return
	}
}
