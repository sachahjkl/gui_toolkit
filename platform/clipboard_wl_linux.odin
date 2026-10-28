#+build linux
package platform

// The Wayland clipboard and primary-selection owner: a full wl_data_source that offers the toolkit's flavours (text,
// HTML, PNG, text/uri-list) to other clients, answers wl_data_source.send by writing the bytes to the fd the
// compositor hands over, and gives the selection up on cancelled; and the read side, wl_data_offer.receive over a
// pipe, read without blocking the UI loop. The primary (middle-click) selection rides the same shapes over
// zwp_primary_selection_v1 when the compositor offers it.
//
// The clip store (clipboard_linux.odin) holds what this process put on the clipboard; here we expose it to the
// compositor. A get of a flavour another client owns reads it back over the selection transport.

import "core:strings"
import "core:sys/posix"
import "core:time"

// The MIME types the toolkit offers, in the order a paste target prefers them. Text has two aliases because clients
// ask for either.
@(private) WL_MIME_TEXT  :: "text/plain;charset=utf-8"
@(private) WL_MIME_TEXT2 :: "text/plain"
@(private) WL_MIME_HTML  :: "text/html"
@(private) WL_MIME_PNG   :: "image/png"
@(private) WL_MIME_URIS  :: "text/uri-list"

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
		wl.proxy_destroy(src)
		wlc.data_source = nil
	} else if src == wlc.dnd_source {
		wl.proxy_destroy(src)
		wlc.dnd_source = nil
		wlc.dnd_sending = false
	}
}
@(private) ds_dnd_drop :: proc "c" (data: rawptr, src: Wl_Proxy) {}
@(private)
ds_dnd_finished :: proc "c" (data: rawptr, src: Wl_Proxy) {
	context = wl_ctx_real()
	if src == wlc.dnd_source { wl.proxy_destroy(src); wlc.dnd_source = nil; wlc.dnd_sending = false }
}
@(private) ds_action :: proc "c" (data: rawptr, src: Wl_Proxy, action: u32) { wl_dnd_source_action = action }
@(private) wl_dnd_source_action: u32

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
	if wlc.data_source != nil { wl.proxy_destroy(wlc.data_source); wlc.data_source = nil }
	src := wl.proxy_marshal_flags(wlc.data_device_manager, WL_DATA_DEVICE_MANAGER_CREATE_DATA_SOURCE,
		wl.data_source_interface, wl.proxy_get_version(wlc.data_device_manager), 0, nil)
	if src == nil { return }
	wlc.data_source = src
	wl.proxy_add_listener(src, &data_source_listener, nil)
	fmts := clipboard_formats()
	if .Text in fmts {
		wl_source_offer(src, WL_MIME_TEXT)
		wl_source_offer(src, WL_MIME_TEXT2)
	}
	if .Html in fmts { wl_source_offer(src, WL_MIME_HTML) }
	if .Image in fmts { wl_source_offer(src, WL_MIME_PNG) }
	if .Files in fmts { wl_source_offer(src, WL_MIME_URIS) }
	serial := wlc.kbd_serial != 0 ? wlc.kbd_serial : wl_button_serial
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
	clear(&wl_pending_offer_mimes)
	wl_pending_offer = offer
}
@(private) wl_pending_offer: Wl_Proxy
@(private) wl_pending_offer_mimes: [dynamic]string

@(private)
off_offer :: proc "c" (data: rawptr, o: Wl_Proxy, mime: cstring) {
	context = wl_ctx_real()
	if o == wl_pending_offer {
		append(&wl_pending_offer_mimes, strings.clone(string(mime)))
	}
}
@(private) off_source_actions :: proc "c" (data: rawptr, o: Wl_Proxy, actions: u32) {}
@(private) off_action :: proc "c" (data: rawptr, o: Wl_Proxy, action: u32) {}

// The CLIPBOARD selection changed to `offer` (nil = cleared). The offer's MIME types are whatever we gathered for it
// since its data_offer event; take ownership of that list.
@(private)
wl_selection_set :: proc(offer: Wl_Proxy) {
	if wlc.offer != nil && wlc.offer != offer {
		wl.proxy_destroy(wlc.offer)
		wl_free_mimes(&wlc.offer_mimes)
	}
	wlc.offer = offer
	wlc.have_offer = offer != nil
	if offer != nil && offer == wl_pending_offer {
		wl_free_mimes(&wlc.offer_mimes)
		wlc.offer_mimes = wl_pending_offer_mimes
		wl_pending_offer_mimes = nil
		wl_pending_offer = nil
	}
}

@(private)
wl_free_mimes :: proc(list: ^[dynamic]string) {
	for s in list { delete(s) }
	clear(list)
}

// Reads a flavour another client offers: dup a pipe, call wl_data_offer.receive(mime, write_fd), flush, close the
// write end, read the pipe to EOF. Bounded so a stuck peer cannot hang the loop.
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
	buf := make([dynamic]u8, allocator)
	chunk: [4096]u8
	deadline := time.tick_now()
	for {
		n := sys_read(i32(read_fd), &chunk[0], size_of(chunk))
		if n > 0 { append(&buf, ..chunk[:n]); continue }
		if n == 0 { break }   // EOF
		// EAGAIN: the pipe is non-blocking only if we set it; it is blocking by default, so n<0 is a real error
		if time.duration_milliseconds(time.tick_since(deadline)) > 2000 { break }
		break
	}
	posix.close(read_fd)
	return buf[:]
}

////////////////////////////////
// primary selection (zwp_primary_selection_v1)

@(private)
Primary_Device_Listener :: struct {
	data_offer: proc "c" (data: rawptr, dev: Wl_Proxy, offer: Wl_Proxy),
	selection:  proc "c" (data: rawptr, dev: Wl_Proxy, offer: Wl_Proxy),
}
@(private) primary_device_listener := Primary_Device_Listener{pd_data_offer, pd_selection}

@(private)
Primary_Offer_Listener :: struct { offer: proc "c" (data: rawptr, o: Wl_Proxy, mime: cstring) }
@(private) primary_offer_listener := Primary_Offer_Listener{po_offer}

@(private)
Primary_Source_Listener :: struct {
	send:      proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring, fd: i32),
	cancelled: proc "c" (data: rawptr, src: Wl_Proxy),
}
@(private) primary_source_listener := Primary_Source_Listener{ps_send, ps_cancelled}

@(private)
pd_data_offer :: proc "c" (data: rawptr, dev: Wl_Proxy, offer: Wl_Proxy) {
	context = wl_ctx_real()
	if offer != nil { wl.proxy_add_listener(offer, &primary_offer_listener, nil) }
	wl_pending_primary_offer = offer
}
@(private) wl_pending_primary_offer: Wl_Proxy
@(private)
po_offer :: proc "c" (data: rawptr, o: Wl_Proxy, mime: cstring) {}
@(private)
pd_selection :: proc "c" (data: rawptr, dev: Wl_Proxy, offer: Wl_Proxy) {
	context = wl_ctx_real()
	if wlc.primary_offer != nil && wlc.primary_offer != offer {
		wl.proxy_marshal_flags(wlc.primary_offer, ZWP_PRIMARY_OFFER_DESTROY, nil, wl.proxy_get_version(wlc.primary_offer), WL_MARSHAL_FLAG_DESTROY)
	}
	wlc.primary_offer = offer
	wlc.have_primary_offer = offer != nil
}
@(private)
ps_send :: proc "c" (data: rawptr, src: Wl_Proxy, mime: cstring, fd: i32) {
	context = wl_ctx_real()
	defer posix.close(posix.FD(fd))
	wl_fd_write_all(fd, transmute([]u8)wl_primary_text)
}
@(private)
ps_cancelled :: proc "c" (data: rawptr, src: Wl_Proxy) {
	context = wl_ctx_real()
	if src == wlc.primary_source {
		wl.proxy_marshal_flags(src, ZWP_PRIMARY_SOURCE_DESTROY, nil, wl.proxy_get_version(src), WL_MARSHAL_FLAG_DESTROY)
		wlc.primary_source = nil
	}
}
@(private) wl_primary_text: string   // the primary selection's text, while we own it

// Sets the primary (middle-click) selection to `text`. The X11 counterpart is the PRIMARY selection (window backend).
@(private)
wl_primary_set :: proc(text: string) {
	if wlc.primary_device == nil || wlc.primary_manager == nil { return }
	delete(wl_primary_text)
	wl_primary_text = strings.clone(text)
	if wlc.primary_source != nil {
		wl.proxy_marshal_flags(wlc.primary_source, ZWP_PRIMARY_SOURCE_DESTROY, nil, wl.proxy_get_version(wlc.primary_source), WL_MARSHAL_FLAG_DESTROY)
		wlc.primary_source = nil
	}
	src := wl.proxy_marshal_flags(wlc.primary_manager, ZWP_PRIMARY_DEVICE_MANAGER_CREATE_SOURCE,
		&zwp_primary_source_iface, wl.proxy_get_version(wlc.primary_manager), 0, nil)
	if src == nil { return }
	wlc.primary_source = src
	wl.proxy_add_listener(src, &primary_source_listener, nil)
	for mime in ([]string{WL_MIME_TEXT, WL_MIME_TEXT2}) {
		c := strings.clone_to_cstring(mime, context.temp_allocator)
		wl.proxy_marshal_flags(src, ZWP_PRIMARY_SOURCE_OFFER, nil, wl.proxy_get_version(src), 0, c)
	}
	serial := wlc.kbd_serial != 0 ? wlc.kbd_serial : wl_button_serial
	wl.proxy_marshal_flags(wlc.primary_device, ZWP_PRIMARY_DEVICE_SET_SELECTION, nil, wl.proxy_get_version(wlc.primary_device), 0, src, serial)
	wl.display_flush(wlc.display)
}

@(private)
wl_primary_get :: proc(allocator := context.allocator) -> string {
	if wlc.primary_source != nil { return strings.clone(wl_primary_text, allocator) }
	if !wlc.have_primary_offer || wlc.primary_offer == nil { return strings.clone(wl_primary_text, allocator) }
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return "" }
	read_fd, write_fd := fds[0], fds[1]
	c := strings.clone_to_cstring(WL_MIME_TEXT, context.temp_allocator)
	wl.proxy_marshal_flags(wlc.primary_offer, ZWP_PRIMARY_OFFER_RECEIVE, nil, wl.proxy_get_version(wlc.primary_offer), 0, c, i32(write_fd))
	wl.display_flush(wlc.display)
	posix.close(write_fd)
	buf := make([dynamic]u8, context.temp_allocator)
	chunk: [4096]u8
	for {
		n := sys_read(i32(read_fd), &chunk[0], size_of(chunk))
		if n <= 0 { break }
		append(&buf, ..chunk[:n])
	}
	posix.close(read_fd)
	return strings.clone(string(buf[:]), allocator)
}

////////////////////////////////
// the text clipboard entry points platform_linux.odin calls

@(private)
wl_clipboard_set_text :: proc(w: ^Window, text: string) {
	delete(wlc.clip_text)
	wlc.clip_text = strings.clone(text)
	wl_clipboard_publish()
}

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
