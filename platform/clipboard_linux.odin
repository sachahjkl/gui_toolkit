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
		if wlc.offer == nil { return nil }
		return wl_offer_read(wlc.offer, mime, allocator)
	case .X11:
		return x11_selection_read(w, x11c.clipboard, mime, allocator)
	case .None:
	}
	return nil
}

// The file:// URIs of a text/uri-list turned into filesystem paths (percent-decoded, "file://host/path" -> "/path").
@(private)
uri_list_to_paths :: proc(list: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		if strings.has_prefix(l, "file://") {
			p := l[len("file://"):]
			// strip an authority (host) before the path
			if slash := strings.index_byte(p, '/'); slash > 0 { p = p[slash:] } else if slash < 0 { continue }
			append(&out, percent_decode(p, allocator))
		} else if strings.has_prefix(l, "/") {
			append(&out, strings.clone(l, allocator))
		}
	}
	return out[:]
}

@(private)
percent_decode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hi, lo := hex_val(s[i + 1]), hex_val(s[i + 2])
			if hi >= 0 && lo >= 0 { strings.write_byte(&b, u8(hi * 16 + lo)); i += 3; continue }
		}
		strings.write_byte(&b, s[i]); i += 1
	}
	return strings.to_string(b)
}

@(private)
hex_val :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a' + 10)
	case 'A' ..= 'F': return int(c - 'A' + 10)
	}
	return -1
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
// Locked views of the clip store, for the Wayland data-source send callback (clipboard_wl_linux.odin), which runs
// inside the display dispatch and must read the store under its mutex. The caller holds the lock across the read.

@(private) sync_lock_clip   :: proc() { sync.mutex_lock(&clip.mutex) }
@(private) sync_unlock_clip :: proc() { sync.mutex_unlock(&clip.mutex) }
@(private) clip_text_locked :: proc() -> string { return clip.text }
@(private) clip_html_locked :: proc() -> string { return clip.html }
@(private) clip_png_locked  :: proc() -> []u8   { return clip.image_png }

// The clipboard files as a text/uri-list (RFC 2483: one file:// URI per line, CRLF). Built on the temp allocator while
// the lock is held; the send callback writes it straight out.
@(private)
clip_uris_locked :: proc() -> string {
	if len(clip.files) == 0 { return "" }
	b := strings.builder_make(context.temp_allocator)
	for p in clip.files {
		strings.write_string(&b, "file://")
		strings.write_string(&b, p)
		strings.write_string(&b, "\r\n")
	}
	return strings.to_string(b)
}
