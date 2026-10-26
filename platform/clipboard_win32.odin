#+build windows
package platform

// The clipboard's flavours on Windows (clipboard.odin has the API). Formats read, best first: images "PNG" (alpha, what
// browsers and Office write), CF_DIBV5, CF_DIB, CF_BITMAP; HTML "HTML Format"; files CF_HDROP. Written: CF_UNICODETEXT
// (CRLF line ends), "HTML Format", "PNG" + CF_DIBV5 (alpha) + CF_DIB (opaque over white), CF_HDROP with "Preferred
// DropEffect" = copy. PNG goes through stb_image (vendor:stb).

import "base:runtime"
import "core:strings"
import win "core:sys/windows"
import stbi "vendor:stb/image"

// Changes whenever a program (this one too) writes the clipboard.
clipboard_sequence :: proc() -> u32 { return u32(win.GetClipboardSequenceNumber()) }

// What the clipboard holds, without opening it.
clipboard_formats :: proc() -> (out: Clipboard_Formats) {
	has :: proc(f: u32) -> bool { return f != 0 && bool(win.IsClipboardFormatAvailable(f)) }
	if has(win.CF_UNICODETEXT) || has(win.CF_TEXT) { out += {.Text} }
	if has(u32(registered_format("HTML Format"))) { out += {.Html} }
	if has(u32(registered_format("PNG"))) || has(win.CF_DIBV5) || has(win.CF_DIB) || has(win.CF_BITMAP) { out += {.Image} }
	if has(win.CF_HDROP) { out += {.Files} }
	return
}

// The names of every format on the clipboard (the system's own as CF_*, the registered ones by name), for diagnostics.
clipboard_format_names :: proc(w: ^Window, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	if !open_clipboard(w) { return out[:] }
	defer win.CloseClipboard()
	STANDARD := [?]string{"", "CF_TEXT", "CF_BITMAP", "CF_METAFILEPICT", "CF_SYLK", "CF_DIF", "CF_TIFF", "CF_OEMTEXT", "CF_DIB", "CF_PALETTE", "CF_PENDATA", "CF_RIFF", "CF_WAVE", "CF_UNICODETEXT", "CF_ENHMETAFILE", "CF_HDROP", "CF_LOCALE", "CF_DIBV5"}
	for f := win.EnumClipboardFormats(0); f != 0; f = win.EnumClipboardFormats(f) {
		if int(f) < len(STANDARD) { append(&out, strings.clone(STANDARD[f], allocator)); continue }
		buf: [256]u16
		n := win.GetClipboardFormatNameW(f, &buf[0], len(buf))
		if n > 0 {
			s, _ := win.utf16_to_utf8(buf[:n], allocator)
			append(&out, s)
		} else {
			append(&out, strings.clone("(private)", allocator))
		}
	}
	return out[:]
}

// The clipboard's image, if any (allocator: the pixels; clipboard_image_destroy frees them).
clipboard_get_image :: proc(w: ^Window, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	if !open_clipboard(w) { return }
	defer win.CloseClipboard()
	for name in ([]string{"PNG", "image/png"}) {
		if b := clip_bytes(u32(registered_format(name)), context.temp_allocator); len(b) > 0 {
			if img, ok = png_decode(b, allocator); ok { return }
		}
	}
	for f in ([]u32{win.CF_DIBV5, win.CF_DIB}) {
		if b := clip_bytes(f, context.temp_allocator); len(b) > 0 {
			if img, ok = dib_to_rgba(b, allocator); ok { return }
		}
	}
	if h := win.HBITMAP(win.GetClipboardData(win.CF_BITMAP)); h != nil { return bitmap_rgba(h, allocator) }
	return
}

// The clipboard's HTML: the fragment (UTF-8 markup) and the page it came from (allocator).
clipboard_get_html :: proc(w: ^Window, allocator := context.allocator) -> (html, source_url: string, ok: bool) {
	if !open_clipboard(w) { return }
	defer win.CloseClipboard()
	b := clip_bytes(u32(registered_format("HTML Format")), context.temp_allocator)
	if b == nil { return }
	end := 0
	for end < len(b) && b[end] != 0 { end += 1 }
	s := string(b[:end])
	return strings.clone(html_format_fragment(s), allocator), strings.clone(html_format_source_url(s), allocator), true
}

// The files on the clipboard (copied in a file manager): absolute paths (allocator, each and the slice).
clipboard_get_files :: proc(w: ^Window, allocator := context.allocator) -> (paths: []string, ok: bool) {
	if !open_clipboard(w) { return }
	defer win.CloseClipboard()
	h := win.HDROP(win.GetClipboardData(win.CF_HDROP))
	if h == nil { return }
	out := make([dynamic]string, allocator)
	count := win.DragQueryFileW(h, 0xFFFF_FFFF, nil, 0)
	for i in 0 ..< count {
		n := win.DragQueryFileW(h, i, nil, 0)
		if n == 0 { continue }
		buf := make([]u16, n + 1, context.temp_allocator)
		got := win.DragQueryFileW(h, i, raw_data(buf), n + 1)
		if s, err := win.utf16_to_utf8(buf[:got], allocator); err == nil { append(&out, s) }
	}
	return out[:], true
}

// Replaces the clipboard's contents by every flavour of `c` (one owner). False when the clipboard could not be had or
// a flavour could not be written.
clipboard_set :: proc(w: ^Window, c: Clipboard_Content) -> bool {
	Item :: struct { format: u32, data: []u8 }
	items := make([dynamic]Item, context.temp_allocator)
	if c.text != "" {
		crlf, _ := strings.replace_all(c.text, "\r\n", "\n", context.temp_allocator)
		crlf, _ = strings.replace_all(crlf, "\n", "\r\n", context.temp_allocator)
		wide := win.utf8_to_utf16(crlf, context.temp_allocator)
		b := make([]u8, (len(wide) + 1) * 2, context.temp_allocator)
		copy(b, ([^]u8)(raw_data(wide))[:len(wide) * 2])
		append(&items, Item{win.CF_UNICODETEXT, b})
	}
	if c.html != "" {
		payload := html_format_wrap(c.html, c.source_url, context.temp_allocator)
		b := make([]u8, len(payload) + 1, context.temp_allocator)
		copy(b, payload)
		append(&items, Item{u32(registered_format("HTML Format")), b})
	}
	if img, has := c.image.?; has {
		if png := png_encode(img, context.temp_allocator); len(png) > 0 { append(&items, Item{u32(registered_format("PNG")), png}) }
		v5 := rgba_to_dib(img, .Alpha_V5, context.temp_allocator)
		dib := rgba_to_dib(img, .Opaque_Over_White, context.temp_allocator)
		if v5 == nil || dib == nil { return false }
		append(&items, Item{win.CF_DIBV5, v5})
		append(&items, Item{win.CF_DIB, dib})
	}
	if len(c.files) > 0 {
		append(&items, Item{win.CF_HDROP, hdrop_encode(c.files, context.temp_allocator)})
		effect := []u8{1, 0, 0, 0}   // DROPEFFECT_COPY: a paste copies (a cut would say move)
		append(&items, Item{u32(registered_format("Preferred DropEffect")), effect})
	}
	if !open_clipboard(w) { return false }
	defer win.CloseClipboard()
	win.EmptyClipboard()
	all := true
	for it in items {
		if it.format == 0 { all = false; continue }
		mem := global_of(it.data)
		if mem == nil { all = false; continue }
		// on success the system owns the memory; on failure it is still ours
		if win.SetClipboardData(win.UINT(it.format), win.HANDLE(mem)) == nil { win.GlobalFree(mem); all = false }
	}
	return all
}

clipboard_set_html :: proc(w: ^Window, html: string, text := "", source_url := "") -> bool {
	return clipboard_set(w, {text = text, html = html, source_url = source_url})
}

clipboard_set_image :: proc(w: ^Window, img: Clipboard_Image) -> bool { return clipboard_set(w, {image = img}) }

clipboard_set_files :: proc(w: ^Window, paths: []string) -> bool { return clipboard_set(w, {files = paths}) }

// Makes the window wake whenever the clipboard changes (a Paste item to enable, a "paste the copied link?" offer):
// WM_CLIPBOARDUPDATE wakes the loop; clipboard_changed tells it.
clipboard_watch :: proc(w: ^Window, on: bool) -> bool {
	if w.clip_watch == on { return true }
	ok := on ? bool(win.AddClipboardFormatListener(w.hwnd)) : bool(win.RemoveClipboardFormatListener(w.hwnd))
	if ok { w.clip_watch = on }
	return ok
}

// True once after the clipboard changed (compared with the last call for this window; the first call says true).
clipboard_changed :: proc(w: ^Window) -> bool {
	seq := clipboard_sequence()
	if seq == w.clip_seen { return false }
	w.clip_seen = seq
	return true
}

// A PNG file's bytes of the pixels (stb_image_write), nil on failure.
png_encode :: proc(img: Clipboard_Image, allocator := context.allocator) -> []u8 {
	w, h := img.size.x, img.size.y
	if w <= 0 || h <= 0 || len(img.rgba) < w * h * 4 { return nil }
	out := make([dynamic]u8, 0, w * h + 64, allocator)
	sink :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		context = runtime.default_context()
		append((^[dynamic]u8)(ctx), ..([^]u8)(data)[:size])
	}
	if stbi.write_png_to_func(sink, &out, i32(w), i32(h), 4, raw_data(img.rgba), i32(w * 4)) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// The pixels of a PNG file's bytes (stb_image), as straight RGBA.
png_decode :: proc(b: []u8, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	if len(b) < 8 { return }
	w, h, n: i32
	p := stbi.load_from_memory(raw_data(b), i32(len(b)), &w, &h, &n, 4)
	if p == nil { return }
	defer stbi.image_free(p)
	if w <= 0 || h <= 0 { return }
	out := make([]u8, int(w) * int(h) * 4, allocator)
	copy(out, p[:len(out)])
	return {out, {int(w), int(h)}}, true
}

////////////////////////////////
// internals

// The clipboard is shared: another program may hold it open for a moment.
@(private = "file")
open_clipboard :: proc(w: ^Window) -> bool {
	hwnd := w != nil ? w.hwnd : nil
	for _ in 0 ..< 5 {
		if win.OpenClipboard(hwnd) { return true }
		win.Sleep(2)
	}
	return false
}

// A copy of one format's bytes (the clipboard is open), nil when absent.
@(private = "file")
clip_bytes :: proc(format: u32, allocator := context.allocator) -> []u8 {
	if format == 0 { return nil }
	h := win.HGLOBAL(win.GetClipboardData(format))
	if h == nil { return nil }
	p := cast([^]u8)win.GlobalLock(h)
	if p == nil { return nil }
	defer win.GlobalUnlock(h)
	n := int(win.GlobalSize(h))
	out := make([]u8, n, allocator)
	copy(out, p[:n])
	return out
}

// The pixels of a device-dependent bitmap (CF_BITMAP), opaque.
@(private = "file")
bitmap_rgba :: proc(h: win.HBITMAP, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	bm: win.BITMAP
	if win.GetObjectW(win.HANDLE(h), size_of(bm), &bm) == 0 || bm.bmWidth <= 0 || bm.bmHeight <= 0 { return }
	w, hh := int(bm.bmWidth), int(bm.bmHeight)
	bmi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(w), biHeight = -i32(hh), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	px := make([]u8, w * hh * 4, allocator)
	dc := win.GetDC(nil)
	got := win.GetDIBits(dc, h, 0, u32(hh), raw_data(px), &bmi, win.DIB_RGB_COLORS)
	win.ReleaseDC(nil, dc)
	if got == 0 { delete(px, allocator); return }
	for i := 0; i < len(px); i += 4 { px[i], px[i + 2], px[i + 3] = px[i + 2], px[i], 255 }
	return {px, {w, hh}}, true
}
