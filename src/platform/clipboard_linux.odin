#+build linux
package platform

// The rich clipboard on Linux (clipboard.odin has the API and the pure conversions). Text goes through the X11
// CLIPBOARD selection (window_x11_linux.odin) or the Wayland wl_data_device (window_wl_linux.odin). The richer
// flavours — HTML, an image, a file list — are kept by the process that set them and offered to other clients under
// their MIME types (text/html, image/png, text/uri-list with GNOME Files' x-special/gnome-copied-files, and KDE's
// application/x-kde-cutselection for files that were cut); a get of a flavour another process owns reads it back over
// the selection transport. Images go through the toolkit's PNG codec (png_encode / png_decode, clipboard.odin); another
// program's JPEG or BMP is read too when it offers no PNG (clipboard_image_decode), GNOME Files' list when there is no
// text/uri-list.
//
// clipboard_request reads without waiting (the answer is an event); the clipboard_get_* procedures and get_clipboard wait
// for the owner, up to seconds when it does not answer.
//
// clipboard_changed tells a window once when the clipboard changes hands: through wl_data_device on Wayland, XFIXES on
// X11. An X server without XFIXES only tells this process when it loses the clipboard.

import "base:runtime"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:sys/posix"
import base "../base"

clipboard_sequence :: proc() -> u32 { return sync.atomic_load(&clip.seq) }

// What the clipboard holds now: this process's store while it owns the selection, else what the owner offers. Without a
// connection (no window yet, offscreen), the store.
clipboard_formats :: proc() -> Clipboard_Formats {
	if wlc.display != nil {
		if wlc.data_source != nil { return clip_store_formats() }
		if wlc.offer != nil { return clipboard_formats_from_mimes(wlc.offer_mimes[:]) }
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

clipboard_get_image :: proc(w: ^Window, allocator := context.allocator, loc := #caller_location) -> (img: Clipboard_Image, ok: bool) {
	base.blocking("platform.clipboard_get_image", loc)
	if !clip_foreign_owner(w) { return clip_store_image(allocator) }   // our own image
	// another process owns it: read its best image type over the selection
	wanted := CLIPBOARD_IMAGE_MIMES
	mime := clipboard_pick_mime(clip_foreign_mimes(w), wanted[:])
	if mime == "" { return }
	b := clip_read_foreign(w, mime, context.temp_allocator)
	if len(b) == 0 { return }
	return clipboard_image_decode(mime, b, allocator)
}

clipboard_get_html :: proc(w: ^Window, allocator := context.allocator, loc := #caller_location) -> (html, source_url: string, ok: bool) {
	base.blocking("platform.clipboard_get_html", loc)
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

clipboard_get_files :: proc(w: ^Window, allocator := context.allocator, loc := #caller_location) -> (paths: []string, ok: bool) {
	base.blocking("platform.clipboard_get_files", loc)
	sync.mutex_lock(&clip.mutex)
	owned := !clip_foreign_owner(w) && len(clip.files) > 0
	own: []string
	if owned {
		own = make([]string, len(clip.files), allocator)
		for p, i in clip.files { own[i] = strings.clone(p, allocator) }
	}
	sync.mutex_unlock(&clip.mutex)
	if owned { return own, true }
	if !clip_foreign_owner(w) { return nil, false }
	// (GNOME Files' list is a "copy" or "cut" line, then the URIs: uri_list_to_paths skips that line)
	wanted := CLIPBOARD_FILES_MIMES
	mime := clipboard_pick_mime(clip_foreign_mimes(w), wanted[:])
	if mime == "" { return nil, false }
	b := clip_read_foreign(w, mime, context.temp_allocator)
	if len(b) == 0 { return nil, false }
	list := uri_list_to_paths(string(b), allocator)
	return list, len(list) > 0
}

// Whether the files on the clipboard were cut (a paste moves them): the store's flag while this process owns the
// clipboard, else what another program's KDE flag or GNOME list says.
clipboard_files_cut :: proc(w: ^Window) -> bool {
	if !clip_foreign_owner(w) { return clip_store_files_cut() }
	offered := clip_foreign_mimes(w)
	for mime in CLIPBOARD_CUT_MIMES {
		if clipboard_pick_mime(offered, {mime}) == "" { continue }
		if clipboard_files_cut_decode(mime, clip_read_foreign(w, mime, context.temp_allocator)) { return true }
	}
	return false
}

// The MIME types another client offers on the clipboard (temp allocator): the Wayland offer's, or the X11 owner's TARGETS.
@(private)
clip_foreign_mimes :: proc(w: ^Window) -> []string {
	if w == nil || w.offscreen { return nil }
	switch w.backend {
	case .Wayland:
		if wlc.offer == nil || wlc.data_source != nil { return nil }
		return wlc.offer_mimes[:]
	case .X11:
		return x11_foreign_targets(w)
	case .None:
	}
	return nil
}

// Whether another process owns the clipboard now (we are not the selection owner).
@(private)
clip_foreign_owner :: proc(w: ^Window) -> bool {
	if w == nil || w.offscreen { return false }
	switch w.backend {
	case .Wayland: return wlc.data_source == nil
	case .X11:     return x11c.clip_owner == 0 || (x11_state(w) != nil && x11c.clip_owner != x11_state(w).id)
	case .None:
	}
	return false
}

////////////////////////////////
// clipboard_request: another client's flavours read by the window's loop, without waiting. Each request is a list of
// MIME types read one after the other; the first request of the window runs, the others wait their turn. Wayland: a pipe
// the owner writes into, watched by the loop's poll (poll_sources) and read when it has bytes. X11: ConvertSelection, the
// answer (and an INCR transfer) handled with the other events of the connection. The answer is queued when every type
// was read.

@(private) CLIP_READ_SILENCE_MS :: 2000   // an owner silent this long is given up: the answer says nothing came
// (the files from text/uri-list, else GNOME Files' list; the cut from KDE's flag, else that list's first line)
@(private = "file") CLIP_REQUEST_FILES_MIMES :: [?]string{"text/uri-list", CLIPBOARD_GNOME_FILES_MIME, CLIPBOARD_KDE_CUT_MIME}

// One request's reads (heap).
@(private)
Clip_Read :: struct {
	reply:   Clipboard_Reply,   // the id and the format asked; the rest is filled when every type is read
	mimes:   [dynamic]string,   // the types to read, in order
	got:     [dynamic][]u8,     // what each brought, in that order (nil: nothing)
	running: bool,              // the read of mimes[len(got)] is asked
	fd:      posix.FD,          // Wayland: the pipe the owner writes into (-1: none)
	buf:     [dynamic]u8,       // Wayland: what came on it so far
	size:    int,               // the bytes that had come when the owner was last heard
	heard:   time.Tick,         // when: a silence of CLIP_READ_SILENCE_MS gives the read up
}

clipboard_request :: proc(w: ^Window, format: Clipboard_Format) -> u64 {
	if w == nil { return 0 }
	reply := Clipboard_Reply{id = clipboard_next_id(w), format = format}
	if !clip_foreign_owner(w) {   // (an offscreen window, or this process owns the clipboard: the store, at once)
		clip_store_reply(&reply)
		clipboard_reply_queue(w, reply)
		return reply.id
	}
	mimes := clip_request_mimes(w, format)
	if len(mimes) == 0 {   // (nothing of it on the clipboard)
		clipboard_reply_queue(w, reply)
		return reply.id
	}
	context.allocator = runtime.heap_allocator()
	r := Clip_Read{reply = reply, fd = -1}
	for m in mimes { append(&r.mimes, strings.clone(m)) }
	append(&w.clip_reads, r)
	clip_reads_pump(w)   // (starts it when no other runs)
	return reply.id
}

// The types a request reads (temp allocator): on Wayland those the offer has; X11 asks for each (an owner refuses what it
// does not hold as quickly as it would list its TARGETS, and asking for the list first would be one more wait).
@(private = "file")
clip_request_mimes :: proc(w: ^Window, format: Clipboard_Format) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	wayland := w.backend == .Wayland
	if wayland && (wlc.offer == nil || wlc.data_source != nil) { return nil }
	#partial switch format {
	case .Text:
		if !wayland {
			append(&out, "text/plain")
		} else if m := wl_offer_pick_text(); m != "" {
			append(&out, m)
		}
	case .Files:
		wanted := CLIP_REQUEST_FILES_MIMES
		for m in wanted {
			if !wayland || wl_offer_has_mime(wlc.offer_mimes[:], m) { append(&out, m) }
		}
	case .Image:
		wanted := CLIPBOARD_IMAGE_MIMES
		for m in wanted {
			if !wayland || wl_offer_has_mime(wlc.offer_mimes[:], m) { append(&out, m) }
		}
	}
	return out[:]
}

// Moves the window's reads on without waiting: what came is taken, a request whose types are all read is answered, the next
// one starts. poll_events calls it, and the X11 events that answer a read.
@(private)
clip_reads_pump :: proc(w: ^Window) {
	context.allocator = runtime.heap_allocator()
	for len(w.clip_reads) > 0 {
		r := &w.clip_reads[0]
		for len(r.got) < len(r.mimes) {
			if !r.running {
				r.running, r.size, r.heard = true, 0, time.tick_now()
				clip_read_start(w, r)
			}
			data, done, size := clip_read_take(w, r)
			if !done && size != r.size { r.size, r.heard = size, time.tick_now() }
			if !done && time.duration_milliseconds(time.tick_since(r.heard)) > CLIP_READ_SILENCE_MS {
				clip_read_stop(w, r)
				data, done = nil, true
			}
			if !done { return }
			append(&r.got, data)
			r.running = false
			// (an image is one of its types, the best first: the others would be the same picture, converted by its owner)
			if r.reply.format == .Image && len(data) > 0 { break }
		}
		clip_read_answer(w, r)
		clip_read_free(r)
		ordered_remove(&w.clip_reads, 0)
	}
}

// The longest a wait of the window's loop may last while a read runs: until its owner's silence gives it up (poll_sources).
@(private)
clip_reads_wait_cap :: proc(w: ^Window, timeout_ms: int) -> int {
	if len(w.clip_reads) == 0 || !w.clip_reads[0].running { return timeout_ms }
	left := max(int(CLIP_READ_SILENCE_MS - time.duration_milliseconds(time.tick_since(w.clip_reads[0].heard))) + 1, 0)
	return timeout_ms < 0 ? left : min(timeout_ms, left)
}

// The pipe of the read running on Wayland, which the loop's poll watches (-1: none).
@(private)
clip_reads_fd :: proc(w: ^Window) -> i32 {
	if len(w.clip_reads) == 0 || !w.clip_reads[0].running { return -1 }
	return i32(w.clip_reads[0].fd)
}

// The window goes: its reads are given up, nothing is answered.
@(private)
clip_reads_drop :: proc(w: ^Window) {
	context.allocator = runtime.heap_allocator()
	for &r in w.clip_reads {
		if r.running { clip_read_stop(w, &r) }
		clip_read_free(&r)
	}
	delete(w.clip_reads)
	w.clip_reads = nil
}

@(private = "file")
clip_read_start :: proc(w: ^Window, r: ^Clip_Read) {
	mime := r.mimes[len(r.got)]
	clear(&r.buf)
	switch w.backend {
	case .Wayland: r.fd = wl_request_start(mime)
	case .X11:     x11_request_start(w, mime)
	case .None:
	}
}

// What came for the read running, without waiting: `done` with its bytes (heap; nil: none came), else the bytes so far.
@(private = "file")
clip_read_take :: proc(w: ^Window, r: ^Clip_Read) -> (data: []u8, done: bool, size: int) {
	switch w.backend {
	case .Wayland:
		if r.fd < 0 { return nil, true, 0 }
		if !wl_request_take(r.fd, &r.buf) { return nil, false, len(r.buf) }
		posix.close(r.fd)
		r.fd = -1
		if len(r.buf) > 0 {
			data = make([]u8, len(r.buf))
			copy(data, r.buf[:])
		}
		clear(&r.buf)
		return data, true, 0
	case .X11:
		return x11_request_take(w)
	case .None:
	}
	return nil, true, 0
}

@(private = "file")
clip_read_stop :: proc(w: ^Window, r: ^Clip_Read) {
	switch w.backend {
	case .Wayland:
		if r.fd >= 0 { posix.close(r.fd) }
		r.fd = -1
	case .X11:
		x11_request_stop(w)
	case .None:
	}
}

// The request's answer from what each type brought.
@(private = "file")
clip_read_answer :: proc(w: ^Window, r: ^Clip_Read) {
	reply := r.reply
	#partial switch reply.format {
	case .Text:
		if len(r.got) > 0 && len(r.got[0]) > 0 {
			reply.text = strings.clone(string(r.got[0]))
			reply.ok = true
		}
	case .Files:
		for b, i in r.got {
			mime := r.mimes[i]
			if len(reply.files) == 0 && mime != CLIPBOARD_KDE_CUT_MIME && len(b) > 0 {
				// (GNOME Files' list is a "copy" or "cut" line, then the URIs: uri_list_to_paths skips that line)
				list := uri_list_to_paths(string(b))
				if len(list) > 0 { reply.files = list } else { delete(list) }
			}
			if mime != "text/uri-list" && clipboard_files_cut_decode(mime, b) { reply.cut = true }
		}
		reply.ok = len(reply.files) > 0
		reply.cut = reply.ok && reply.cut
	case .Image:
		for b, i in r.got {
			if len(b) == 0 { continue }
			reply.data, reply.mime, reply.ok = slice.clone(b), strings.clone(r.mimes[i]), true
			break
		}
	}
	clipboard_reply_queue(w, reply)
}

@(private = "file")
clip_read_free :: proc(r: ^Clip_Read) {
	for m in r.mimes { delete(m) }
	for b in r.got { delete(b) }
	delete(r.mimes)
	delete(r.got)
	delete(r.buf)
	if r.fd >= 0 { posix.close(r.fd) }
	r^ = {}
	r.fd = -1
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
			delete(wlc.clip_text, runtime.heap_allocator())
			wlc.clip_text = strings.clone(txt, runtime.heap_allocator())   // (outlives whatever allocator the app calls under)
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

////////////////////////////////
// Locked views of the clip store, for the Wayland data-source send callback (clipboard_wl_linux.odin), which runs
// inside the display dispatch and must read the store under its mutex. The caller holds the lock across the read.

@(private) sync_lock_clip   :: proc() { sync.mutex_lock(&clip.mutex) }
@(private) sync_unlock_clip :: proc() { sync.mutex_unlock(&clip.mutex) }
@(private) clip_text_locked :: proc() -> string { return clip.text }
@(private) clip_html_locked :: proc() -> string { return clip.html }
@(private) clip_png_locked  :: proc() -> []u8   { return clip.image_png }
@(private) clip_files_cut_locked :: proc() -> bool { return clip.files_cut }

// The clipboard files as GNOME Files' list (gnome_copied_files_encode), on the temp allocator while the lock is held.
@(private)
clip_gnome_files_locked :: proc() -> string {
	if len(clip.files) == 0 { return "" }
	return gnome_copied_files_encode(clip.files, clip.files_cut)
}

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
