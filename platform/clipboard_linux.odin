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
// clipboard_changed tells a window once when the clipboard changes hands: through wl_data_device on Wayland, XFIXES on
// X11. An X server without XFIXES only tells this process when it loses the clipboard.

import "core:strings"
import "core:sync"

// An app with an image codec (a browser) sets this so clipboard_set can offer pictures as PNG; nil without one.
png_encode_hook: proc(img: Clipboard_Image, allocator := context.allocator) -> []u8
png_decode_hook: proc(b: []u8, allocator := context.allocator) -> (Clipboard_Image, bool)

clipboard_sequence :: proc() -> u32 { return sync.atomic_load(&clip.seq) }

// What the clipboard holds now: this process's store while it owns the selection, else what the owner offers. Without a
// connection (no window yet, offscreen), the store.
clipboard_formats :: proc() -> Clipboard_Formats {
	if wlc.display != nil {
		if wlc.data_source != nil { return clip_store_formats() }
		if wlc.have_offer && wlc.offer != nil { return clipboard_formats_from_mimes(wlc.offer_mimes[:]) }
		return {}
	}
	if x11c.c != nil && x11c.clip_owner == 0 && len(x11c.windows) > 0 { return x11_foreign_formats(x11c.windows[0]) }
	return clip_store_formats()
}

clipboard_format_names :: proc(w: ^Window, allocator := context.allocator) -> []string {
	fmts := clipboard_formats()
	out := make([dynamic]string, allocator)
	if .Text in fmts { append(&out, strings.clone("text/plain", allocator)) }
	if .Html in fmts { append(&out, strings.clone("text/html", allocator)) }
	if .Image in fmts { append(&out, strings.clone("image/png", allocator)) }
	if .Files in fmts { append(&out, strings.clone("text/uri-list", allocator)) }
	return out[:]
}

clipboard_get_image :: proc(w: ^Window, allocator := context.allocator) -> (img: Clipboard_Image, ok: bool) {
	if png_decode_hook == nil { return }
	// our own image
	sync.mutex_lock(&clip.mutex)
	have := clip.image_png
	owned := clip.formats >= {.Image} && !clip_foreign_owner(w)
	sync.mutex_unlock(&clip.mutex)
	if owned && len(have) > 0 { return png_decode_hook(have, allocator) }
	// another process owns it: read the PNG flavour over the selection
	b := clip_read_foreign(w, "image/png", context.temp_allocator)
	if len(b) == 0 { return }
	return png_decode_hook(b, allocator)
}

clipboard_get_html :: proc(w: ^Window, allocator := context.allocator) -> (html, source_url: string, ok: bool) {
	sync.mutex_lock(&clip.mutex)
	own_html := clip.html
	owned := !clip_foreign_owner(w)
	url := clip.source_url
	sync.mutex_unlock(&clip.mutex)
	if owned && own_html != "" {
		return strings.clone(own_html, allocator), strings.clone(url, allocator), true
	}
	b := clip_read_foreign(w, "text/html", context.temp_allocator)
	if len(b) == 0 { return "", "", false }
	return strings.clone(string(b), allocator), "", true
}

clipboard_get_files :: proc(w: ^Window, allocator := context.allocator) -> (paths: []string, ok: bool) {
	sync.mutex_lock(&clip.mutex)
	owned := !clip_foreign_owner(w) && len(clip.files) > 0
	own: []string
	if owned {
		own = make([]string, len(clip.files), allocator)
		for p, i in clip.files { own[i] = strings.clone(p, allocator) }
	}
	sync.mutex_unlock(&clip.mutex)
	if owned { return own, true }
	b := clip_read_foreign(w, "text/uri-list", context.temp_allocator)
	if len(b) == 0 { return nil, false }
	list := uri_list_to_paths(string(b), allocator)
	return list, len(list) > 0
}

// Whether another process owns the clipboard now (we are not the selection owner).
@(private)
clip_foreign_owner :: proc(w: ^Window) -> bool {
	if w == nil || w.offscreen { return false }
	switch w.backend {
	case .Wayland: return wlc.data_source == nil && wlc.have_offer && wlc.offer != nil
	case .X11:     return x11c.clip_owner == 0 || (x11_state(w) != nil && x11c.clip_owner != x11_state(w).id)
	case .None:
	}
	return false
}

// Reads a flavour another client owns over the selection transport (bytes, temp allocator by default).
@(private)
clip_read_foreign :: proc(w: ^Window, mime: string, allocator := context.allocator) -> []u8 {
	if w == nil || w.offscreen { return nil }
	switch w.backend {
	case .Wayland:
		if wlc.offer == nil || wlc.data_source != nil { return nil }   // (our own offer: this thread would have to answer itself)
		return wl_offer_read(wlc.offer, mime, allocator)
	case .X11:
		return x11_selection_read(w, x11c.clipboard, mime, allocator)
	case .None:
	}
	return nil
}

clipboard_set :: proc(w: ^Window, c: Clipboard_Content) -> bool {
	clip_store_put(c)
	txt := strings.clone(c.text, context.temp_allocator)
	// own the selection and offer every flavour the store holds (text, HTML, PNG, files)
	if w != nil && !w.offscreen {
		switch w.backend {
		case .Wayland:
			delete(wlc.clip_text); wlc.clip_text = strings.clone(txt)
			wl_clipboard_publish()
		case .X11:
			x11_clipboard_own_rich(w, txt)
		case .None:
		}
	}
	return true
}

clipboard_set_html :: proc(w: ^Window, html: string, text := "", source_url := "") -> bool {
	return clipboard_set(w, {text = text, html = html, source_url = source_url})
}
clipboard_set_image :: proc(w: ^Window, img: Clipboard_Image) -> bool { return clipboard_set(w, {image = img}) }
clipboard_set_files :: proc(w: ^Window, paths: []string) -> bool { return clipboard_set(w, {files = paths}) }

clipboard_watch :: proc(w: ^Window, on: bool) -> bool { return true }   // clipboard_changed reads a count the events keep

// True once after the clipboard changed (compared with the last call for this window; the first call says true).
clipboard_changed :: proc(w: ^Window) -> bool {
	if w == nil { return false }
	seen := clipboard_sequence() + 1   // (never 0 at first: the zero of clip_seen is "not asked yet")
	if seen == w.clip_seen { return false }
	w.clip_seen = seen
	return true
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

////////////////////////////////
// Locked views of the clip store, for the Wayland data-source send callback (clipboard_wl_linux.odin), which runs
// inside the display dispatch and must read the store under its mutex. The caller holds the lock across the read.

@(private) sync_lock_clip   :: proc() { sync.mutex_lock(&clip.mutex) }
@(private) sync_unlock_clip :: proc() { sync.mutex_unlock(&clip.mutex) }
@(private) clip_text_locked :: proc() -> string { return clip.text }
@(private) clip_html_locked :: proc() -> string { return clip.html }
@(private) clip_png_locked  :: proc() -> []u8   { return clip.image_png }

// The clipboard files as a text/uri-list (RFC 2483: one percent-encoded file:// URI per line, CRLF). Built on the temp allocator while
// the lock is held; the send callback writes it straight out.
@(private)
clip_uris_locked :: proc() -> string {
	if len(clip.files) == 0 { return "" }
	b := strings.builder_make(context.temp_allocator)
	for p in clip.files {
		strings.write_string(&b, file_uri(p))
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}
