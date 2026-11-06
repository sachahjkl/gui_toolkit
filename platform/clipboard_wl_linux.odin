#+build linux
package platform

// The Wayland clipboard owner: a full wl_data_source that offers the toolkit's flavours (text,
// HTML, PNG, text/uri-list) to other clients, answers wl_data_source.send by writing the bytes to the fd the
// compositor hands over, and gives the selection up on cancelled; and the read side, wl_data_offer.receive over a
// pipe, read without blocking the UI loop. There is no primary (middle-click) selection on Wayland.
//
// The clip store (clipboard_linux.odin) holds what this process put on the clipboard; here we expose it to the
// compositor. A get of a flavour another client owns reads it back over the selection transport.

import "core:strings"
import "core:sys/posix"

// The MIME types the toolkit offers, in the order a paste target prefers them. Text has two aliases because clients
// ask for either.
@(private) WL_MIME_TEXT  :: "text/plain;charset=utf-8"
@(private) WL_MIME_TEXT2 :: "text/plain"
@(private) WL_MIME_HTML  :: "text/html"
@(private) WL_MIME_PNG   :: "image/png"
@(private) WL_MIME_URIS  :: "text/uri-list"

@(private = "file") WL_PIPE_CHUNK_BYTES :: 4096
@(private = "file") WL_OFFER_READ_WAIT_MS :: 2000   // silence of the peer that gives up a read

////////////////////////////////
// wl_data_source: we own the selection and feed other clients

@(private)
Data_Source_Listener :: struct {
	target:              proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring),
	send:                proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring, fd: i32),
	cancelled:           proc "c" (data: rawptr, src: Wl_Proxy),
	dnd_drop_performed:  proc "c" (data: rawptr, src: Wl_Proxy),
	dnd_finished:        proc "c" (data: rawptr, src: Wl_Proxy),
	action:              proc "c" (data: rawptr, src: Wl_Proxy, action: u32),
}
@(private) data_source_listener := Data_Source_Listener{ds_target, ds_send, ds_cancelled, ds_dnd_drop, ds_dnd_finished, ds_action}

// wl_proxy_destroy alone frees the client's side: the compositor would keep the source, and the drag it belongs to.
@(private)
wl_data_source_destroy :: proc "contextless" (src: Wl_Proxy) {
	wl.proxy_marshal_flags(src, WL_DATA_SOURCE_DESTROY, nil, wl.proxy_get_version(src), WL_MARSHAL_FLAG_DESTROY)
}

@(private) ds_target :: proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring) {}
@(private)
ds_send :: proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring, fd: i32) {
	context = wl_ctx_real()
	// the drag source and the clipboard source share this callback: pick the right store
	if src == wlc.dnd_source {
		wl_write_drag_flavour(fd, string(mime))
	} else {
		wl_write_clip_flavour(fd, string(mime))
	}
}
@(private)
ds_cancelled :: proc "c" (data: rawptr, src: Wl_Proxy) {
	context = wl_ctx_real()
	if src == wlc.data_source {
		wl_data_source_destroy(src)
		wlc.data_source = nil
		clip_note_changed()
	} else if src == wlc.dnd_source {
		wl_data_source_destroy(src)
		wlc.dnd_source = nil
		wlc.drag.phase = .Abandoned
		wlc.dnd_source_action = 0   // (the target it hovered may have chosen an action: nothing was dropped)
	}
}
@(private)
ds_dnd_drop :: proc "c" (data: rawptr, src: Wl_Proxy) {
	if src == wlc.dnd_source { wlc.drag.phase = .Dropped }
}
@(private)
ds_dnd_finished :: proc "c" (data: rawptr, src: Wl_Proxy) {
	context = wl_ctx_real()
	if src == wlc.dnd_source { wl_data_source_destroy(src); wlc.dnd_source = nil; wlc.drag.phase = .Finished }
}
@(private) ds_action :: proc "c" (data: rawptr, src: Wl_Proxy, action: u32) { wlc.dnd_source_action = action }

// Writes one clipboard flavour to `fd` (the pipe the compositor gave) then closes it. A blocking write to a pipe the
// peer reads is bounded by the pipe buffer; large flavours (a PNG) are written in a loop that tolerates short writes.
@(private)
wl_write_clip_flavour :: proc(fd: i32, mime: string) {
	defer posix.close(posix.FD(fd))
	sync_lock_clip()
	defer sync_unlock_clip()
	switch mime {
	case WL_MIME_TEXT, WL_MIME_TEXT2: wl_fd_write_all(fd, transmute([]u8)clip_text_locked())
	case WL_MIME_HTML:                wl_fd_write_all(fd, transmute([]u8)clip_html_locked())
	case WL_MIME_PNG:                 wl_fd_write_all(fd, clip_png_locked())
	case WL_MIME_URIS:                wl_fd_write_all(fd, transmute([]u8)clip_uris_locked())
	}
}

// Writes all of `data` to the pipe fd, tolerating short writes (the reader drains it). Bounded by the peer reading.
@(private)
wl_fd_write_all :: proc(fd: i32, data: []u8) {
	off := 0
	for off < len(data) {
		n := sys_write(fd, &data[off], uint(len(data)) - uint(off))
		if n <= 0 { break }   // EPIPE (the peer gave up) or an error: stop, the fd closes on return
		off += int(n)
	}
}

// Claims the CLIPBOARD selection for this process: makes a wl_data_source offering every flavour the clip store holds,
// and set_selection with a recent input serial. Replaces an older source. Called by clipboard_set through
// wl_clipboard_publish.
@(private)
wl_clipboard_publish :: proc() {
	if wlc.data_device == nil || wlc.data_device_manager == nil { return }
	if wlc.data_source != nil { wl_data_source_destroy(wlc.data_source); wlc.data_source = nil }
	src := wl.proxy_marshal_flags(wlc.data_device_manager, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
		wl.data_source_interface, wl.proxy_get_version(wlc.data_device_manager), 0, nil)
	if src == nil { return }
	wlc.data_source = src
	wl.proxy_add_listener(src, &data_source_listener, nil)
	fmts := clip_store_formats()
	if .Text in fmts {
		wl_source_offer(src, WL_MIME_TEXT)
		wl_source_offer(src, WL_MIME_TEXT2)
	}
	if .Html in fmts { wl_source_offer(src, WL_MIME_HTML) }
	if .Image in fmts { wl_source_offer(src, WL_MIME_PNG) }
	if .Files in fmts { wl_source_offer(src, WL_MIME_URIS) }
	serial := wlc.kbd_serial != 0 ? wlc.kbd_serial : wlc.button_serial
	wl.proxy_marshal_flags(wlc.data_device, WL_DATA_DEVICE_SET_SELECTION, nil, wl.proxy_get_version(wlc.data_device), 0, src, serial)
	wl.display_flush(wlc.display)
}

@(private)
wl_source_offer :: proc(src: Wl_Proxy, mime: string) {
	c := strings.clone_to_cstring(mime, context.temp_allocator)
	wl.proxy_marshal_flags(src, WL_DATA_SOURCE_OFFER, nil, wl.proxy_get_version(src), 0, c)
}

////////////////////////////////
// wl_data_offer: another client owns the selection, we read it

@(private)
Data_Offer_Listener :: struct {
	offer:         proc "c" (data: rawptr, o: Wl_Proxy, mime: cstring),
	source_actions: proc "c" (data: rawptr, o: Wl_Proxy, actions: u32),
	action:        proc "c" (data: rawptr, o: Wl_Proxy, action: u32),
}
@(private) data_offer_listener := Data_Offer_Listener{off_offer, off_source_actions, off_action}

// A new offer object arrived (data_device.data_offer): start collecting the MIME types it advertises. Which selection
// it is (clipboard / drag) is decided when the matching selection / enter event names it.
@(private)
wl_offer_new :: proc(offer: Wl_Proxy) {
	if offer == nil { return }
	wl.proxy_add_listener(offer, &data_offer_listener, nil)
	// the MIME list for this offer is gathered into a scratch list until the offer is bound to a role
	wl_free_mimes(&wlc.pending_offer_mimes)
	wlc.pending_offer = offer
}

@(private)
off_offer :: proc "c" (data: rawptr, o: Wl_Proxy, mime: cstring) {
	context = wl_ctx_real()
	if o == wlc.pending_offer {
		append(&wlc.pending_offer_mimes, strings.clone(string(mime)))
	}
}
// (right after the offer's types, before the enter that names the offer: only one drag at a time is ever described)
@(private) off_source_actions :: proc "c" (data: rawptr, o: Wl_Proxy, actions: u32) { wlc.offer_actions = actions }
@(private) off_action :: proc "c" (data: rawptr, o: Wl_Proxy, action: u32) {}

// The CLIPBOARD selection changed to `offer` (nil = cleared). The offer's MIME types are whatever we gathered for it
// since its data_offer event; take ownership of that list.
@(private)
wl_selection_set :: proc(offer: Wl_Proxy) {
	if wlc.offer != nil && wlc.offer != offer {
		wl.proxy_marshal_flags(wlc.offer, WL_DATA_OFFER_DESTROY, nil, wl.proxy_get_version(wlc.offer), WL_MARSHAL_FLAG_DESTROY)
		wl_free_mimes(&wlc.offer_mimes)
	}
	wlc.offer = offer
	wlc.have_offer = offer != nil
	if wlc.data_source == nil { clip_note_changed() }
	if offer != nil && offer == wlc.pending_offer {
		wl_free_mimes(&wlc.offer_mimes)
		wlc.offer_mimes = wlc.pending_offer_mimes
		wlc.pending_offer_mimes = nil
		wlc.pending_offer = nil
	}
}

@(private)
wl_free_mimes :: proc(list: ^[dynamic]string) {
	for s in list { delete(s) }
	clear(list)
}

// Reads a flavour another client offers: a pipe, wl_data_offer.receive(mime, write_fd), flush, close the write end, read
// the pipe to EOF. nil when the peer stays silent too long (this thread cannot serve its own offer, a client may hang):
// no partial data.
@(private)
wl_offer_read :: proc(offer: Wl_Proxy, mime: string, allocator := context.allocator) -> []u8 {
	if offer == nil { return nil }
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return nil }
	read_fd, write_fd := fds[0], fds[1]
	c := strings.clone_to_cstring(mime, context.temp_allocator)
	wl.proxy_marshal_flags(offer, WL_DATA_OFFER_RECEIVE, nil, wl.proxy_get_version(offer), 0, c, i32(write_fd))
	wl.display_flush(wlc.display)
	posix.close(write_fd)   // the compositor keeps its own copy of the fd; our end must close so the read sees EOF
	return wl_pipe_read_all(read_fd, allocator)
}

// Reads the pipe to EOF and closes it; nil when no byte comes for WL_OFFER_READ_WAIT_MS, or on an error.
@(private)
wl_pipe_read_all :: proc(fd: posix.FD, allocator := context.allocator) -> []u8 {
	defer posix.close(fd)
	buf := make([dynamic]u8, allocator)
	chunk: [WL_PIPE_CHUNK_BYTES]u8
	for {
		if poll_fd_wait(i32(fd), WL_OFFER_READ_WAIT_MS) <= 0 { delete(buf); return nil }
		n := sys_read(i32(fd), &chunk[0], size_of(chunk))
		if n < 0 { delete(buf); return nil }
		if n == 0 { return buf[:] }
		append(&buf, ..chunk[:n])
	}
}

////////////////////////////////
// the text clipboard entry points platform_linux.odin calls

@(private)
wl_clipboard_get_text :: proc(w: ^Window, allocator := context.allocator) -> string {
	// our own selection: the store's text
	if wlc.data_source != nil || !wlc.have_offer || wlc.offer == nil {
		return strings.clone(wlc.clip_text, allocator)
	}
	// pick the first text MIME the offer advertises
	mime := wl_offer_pick_text()
	if mime == "" { return "" }
	b := wl_offer_read(wlc.offer, mime, allocator)
	return string(b)
}

@(private)
wl_offer_pick_text :: proc() -> string {
	for m in wlc.offer_mimes { if m == WL_MIME_TEXT { return m } }
	for m in wlc.offer_mimes { if m == WL_MIME_TEXT2 { return m } }
	for m in wlc.offer_mimes { if strings.has_prefix(m, "text/plain") { return m } }
	return ""
}

@(private)
wl_offer_has_mime :: proc(list: []string, mime: string) -> bool {
	for m in list { if m == mime { return true } }
	return false
}
