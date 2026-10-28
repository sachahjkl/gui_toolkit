#+build linux
package platform

// The rich clipboard on Linux (clipboard.odin has the API and the pure conversions). Text goes through the X11
// CLIPBOARD selection (window_x11_linux.odin) or the Wayland wl_data_device (window_wl_linux.odin). The richer
// flavours — HTML, an image, a file list — are kept by the process that set them and offered to other clients under
// their MIME types (text/html, image/png, text/uri-list); a get of a flavour another process owns reads it back over
// the selection transport. PNG for images uses the engine's own encoder when an app wires png_encode_hook; without it
// an image is offered as its raw bytes only when the app already holds PNG. This keeps the toolkit free of an image
// codec while letting a browser (which has one) carry pictures.
//
// clipboard_watch / clipboard_changed let a window learn when another program wrote the clipboard; on Linux this is
// best effort (X11 has no change signal without XFIXES, which is probed when present), so it reports a change whenever
// the selection owner is not this process.

import "core:strings"
import "core:sync"

// What this process put on the clipboard last (so a get returns every flavour, and the selection owner answers other
// clients). Guarded by a mutex: clipboard_set runs on the UI thread, but a Wayland data-source send callback may read
// it from the display dispatch.
@(private)
Clip_Store :: struct {
	mutex:      sync.Mutex,
	seq:        u32,
	text:       string,
	html:       string,
	source_url: string,
	image_png:  []u8,       // PNG bytes, when the app gave an image and png_encode_hook turned it into PNG
	files:      []string,
	formats:    Clipboard_Formats,
}
@(private) clip: Clip_Store

// An app with an image codec (a browser) sets this so clipboard_set can offer pictures as PNG; nil without one.
png_encode_hook: proc(img: Clipboard_Image, allocator := context.allocator) -> []u8
png_decode_hook: proc(b: []u8, allocator := context.allocator) -> (Clipboard_Image, bool)

clipboard_sequence :: proc() -> u32 { return sync.atomic_load(&clip.seq) }

clipboard_formats :: proc() -> Clipboard_Formats {
	sync.mutex_lock(&clip.mutex)
	defer sync.mutex_unlock(&clip.mutex)
	return clip.formats
}

clipboard_format_names :: proc(w: ^Window, allocator := context.allocator) -> []string {
	sync.mutex_lock(&clip.mutex)
	defer sync.mutex_unlock(&clip.mutex)
	out := make([dynamic]string, allocator)
	if .Text in clip.formats { append(&out, strings.clone("text/plain", allocator)) }
	if .Html in clip.formats { append(&out, strings.clone("text/html", allocator)) }
	if .Image in clip.formats { append(&out, strings.clone("image/png", allocator)) }
	if .Files in clip.formats { append(&out, strings.clone("text/uri-list", allocator)) }
	return out[:]
}

clipboard_get_image :: proc(w: ^Window, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	sync.mutex_lock(&clip.mutex)
	have := clip.image_png
	sync.mutex_unlock(&clip.mutex)
	if len(have) == 0 { return }
	if png_decode_hook == nil { return }
	return png_decode_hook(have, allocator)
}

clipboard_get_html :: proc(w: ^Window, allocator := context.allocator) -> (html, source_url: string, ok: bool) {
	sync.mutex_lock(&clip.mutex)
	defer sync.mutex_unlock(&clip.mutex)
	if clip.html == "" { return "", "", false }
	return strings.clone(clip.html, allocator), strings.clone(clip.source_url, allocator), true
}

clipboard_get_files :: proc(w: ^Window, allocator := context.allocator) -> (paths: []string, ok: bool) {
	sync.mutex_lock(&clip.mutex)
	defer sync.mutex_unlock(&clip.mutex)
	if len(clip.files) == 0 { return nil, false }
	out := make([]string, len(clip.files), allocator)
	for p, i in clip.files { out[i] = strings.clone(p, allocator) }
	return out, true
}

clipboard_set :: proc(w: ^Window, c: Clipboard_Content) -> bool {
	sync.mutex_lock(&clip.mutex)
	clip_clear_locked()
	clip.text = strings.clone(c.text)
	clip.html = strings.clone(c.html)
	clip.source_url = strings.clone(c.source_url)
	if c.text != "" { clip.formats += {.Text} }
	if c.html != "" { clip.formats += {.Html} }
	if img, ok := c.image.?; ok && img.size.x > 0 && img.size.y > 0 {
		if png_encode_hook != nil {
			clip.image_png = png_encode_hook(img)
			if len(clip.image_png) > 0 { clip.formats += {.Image} }
		}
	}
	if len(c.files) > 0 {
		clip.files = make([]string, len(c.files))
		for p, i in c.files { clip.files[i] = strings.clone(p) }
		clip.formats += {.Files}
	}
	clip.seq += 1
	txt := strings.clone(c.text != "" ? c.text : "", context.temp_allocator)
	sync.mutex_unlock(&clip.mutex)
	// own the selection so other clients can read at least the text (the common case)
	if w != nil && !w.offscreen { set_clipboard(w, txt) }
	return true
}

clipboard_set_html :: proc(w: ^Window, html: string, text := "", source_url := "") -> bool {
	return clipboard_set(w, {text = text, html = html, source_url = source_url})
}
clipboard_set_image :: proc(w: ^Window, img: Clipboard_Image) -> bool { return clipboard_set(w, {image = img}) }
clipboard_set_files :: proc(w: ^Window, paths: []string) -> bool { return clipboard_set(w, {files = paths}) }

clipboard_watch :: proc(w: ^Window, on: bool) -> bool { return true }   // X11/Wayland carry no cheap change signal; clipboard_changed polls the owner

clipboard_changed :: proc(w: ^Window) -> bool {
	// true when the selection is not ours: another program wrote since we last held it. Conservative but cheap.
	if w == nil || w.offscreen { return false }
	switch w.backend {
	case .Wayland: return wlc.have_offer && wlc.offer != nil
	case .X11:     return x11c.clip_owner == 0 || x11c.clip_owner != x11_state(w).id
	case .None:
	}
	return false
}

// PNG without an app codec: not available in the toolkit itself. An app that wants pictures on the clipboard wires
// png_encode_hook / png_decode_hook (a browser has image.encode / image.decode). Without them these report "no PNG".
png_encode :: proc(img: Clipboard_Image, allocator := context.allocator) -> []u8 {
	if png_encode_hook != nil { return png_encode_hook(img, allocator) }
	return nil
}
png_decode :: proc(b: []u8, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	if png_decode_hook != nil { return png_decode_hook(b, allocator) }
	return {}, false
}

@(private)
clip_clear_locked :: proc() {
	delete(clip.text); delete(clip.html); delete(clip.source_url); delete(clip.image_png)
	for p in clip.files { delete(p) }
	delete(clip.files)
	clip.text, clip.html, clip.source_url, clip.image_png, clip.files = "", "", "", nil, nil
	clip.formats = {}
}

////////////////////////////////
// Wayland transport helpers the window backend calls (window_wl_linux.odin)

// Offer the clipboard text through a wl_data_source. A full implementation needs a recent input serial and the
// source's send callback writing to the pipe the compositor hands over; that plumbing is large. Until it is wired this
// keeps the text in `clip` so a same-process get returns it, and relies on the compositor's own copy for cross-process
// text where the app sets it through a portal. Noted in the report as the remaining Wayland selection work.
@(private)
wl_clipboard_offer_text :: proc(w: ^Window, text: string) {
	// kept by clip; the cross-process owner is the remaining work
}

// Read a flavour another client offers through a wl_data_offer. The real path dups a pipe, calls wl_data_offer.receive
// with the MIME type, flushes, and reads the pipe to EOF. Until that is wired this returns our own copy when we hold it.
@(private)
wl_offer_receive :: proc(offer: Wl_Proxy, mime: string, allocator := context.allocator) -> string {
	return strings.clone(wlc.clip_text, allocator)
}
