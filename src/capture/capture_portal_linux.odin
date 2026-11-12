#+build linux
package capture

// org.freedesktop.portal.Screenshot: a picture of the whole desktop, from a desktop whose compositor lets no client copy
// the screen itself (GNOME, KDE without their own protocols). Screenshot(parent, {handle_token, interactive: false})
// answers with a Request object; its Response signal carries a file:// URI of a PNG the portal wrote. The file is left
// where the portal put it: it may be the user's Pictures folder (GNOME), not a temporary one, and it is the portal's
// to name. The portal may ask the user the first time (a permission dialog): the wait is bounded by PORTAL_ANSWER_MS.
//
// Each picture opens its own bus connection: a session may be used by one worker, then another, and a dbus.Conn is
// driven by one thread.

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "../dbus"
import png "../png"

@(private = "file") PORTAL_SERVICE :: "org.freedesktop.portal.Desktop"
@(private = "file") PORTAL_PATH :: "/org/freedesktop/portal/desktop"
@(private = "file") SCREENSHOT_IFACE :: "org.freedesktop.portal.Screenshot"
@(private = "file") REQUEST_IFACE :: "org.freedesktop.portal.Request"
@(private = "file") PROPERTIES_IFACE :: "org.freedesktop.DBus.Properties"
@(private = "file") PORTAL_QUERY_MS :: 3000      // is the portal there: a missing one must not hold open()
@(private = "file") PORTAL_CALL_MS :: 8000       // the request, not the picture
@(private = "file") PORTAL_ANSWER_MS :: 120000   // the picture, a permission dialog included
@(private = "file") PORTAL_POLL_MS :: 200
@(private = "file") RESPONSE_OK :: 0
@(private = "file") RESPONSE_CANCELLED :: 1

@(private)
Portal_State :: struct {
	requests: u32,      // the handle tokens made: each request names its own
	size:     [2]i32,   // the last picture's: the one output there is without Wayland
}

// Whether the session bus has a portal with Screenshot (its `version` property answers).
@(private)
portal_available :: proc() -> bool {
	conn := dbus.connect_bus(.Session)
	if conn == nil { return false }
	defer dbus.conn_close(conn)
	w := dbus.body_writer()
	dbus.w_string(&w, SCREENSHOT_IFACE)
	dbus.w_string(&w, "version")
	msg, ok := dbus.call(conn, PORTAL_SERVICE, PORTAL_PATH, PROPERTIES_IFACE, "Get", "ss", w.buf[:], PORTAL_QUERY_MS)
	return ok && msg.type == .Method_Return
}

// What the Response signal said.
@(private = "file")
Portal_Answer :: struct {
	done: bool,
	code: u32,
	uri:  string,   // (the heap: the message's memory goes when the handler returns)
}

// The whole desktop, as the portal's PNG: BGRA, scale 1, at {0, 0} (the caller places it).
@(private)
portal_screenshot :: proc(p: ^Portal_State, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	conn := dbus.connect_bus(.Session)
	if conn == nil { return {}, .Unsupported }
	defer dbus.conn_close(conn)
	p.requests += 1
	digits: [16]u8
	token := strings.concatenate({"gtcapture", strconv.write_uint(digits[:], u64(p.requests), 10)}, context.temp_allocator)

	w := dbus.body_writer()
	dbus.w_string(&w, "")   // parent_window: none
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, token)
	dbus.arg_dict_entry(&w, "interactive"); dbus.arg_variant_bool(&w, false)
	dbus.arg_dict_end(&w, ol, oc)

	answer: Portal_Answer
	defer delete(answer.uri, runtime.heap_allocator())
	// (subscribed before the call: the answer may come before the call's own reply is read)
	expected := request_path(conn, token)
	sub := dbus.subscribe(conn, PORTAL_SERVICE, expected, REQUEST_IFACE, "Response", portal_response, &answer)
	defer dbus.unsubscribe(conn, sub)
	msg, ok := dbus.call(conn, PORTAL_SERVICE, PORTAL_PATH, SCREENSHOT_IFACE, "Screenshot", "sa{sv}", w.buf[:], PORTAL_CALL_MS)
	if !ok { return {}, msg.type == .Error ? .Denied : .Failed }
	r := dbus.msg_reader(&msg)
	handle := dbus.r_string(&r)
	// (an old portal chose the handle itself)
	other: u32
	if handle != expected { other = dbus.subscribe(conn, PORTAL_SERVICE, handle, REQUEST_IFACE, "Response", portal_response, &answer) }
	defer if other != 0 { dbus.unsubscribe(conn, other) }

	waited := 0
	for !answer.done && dbus.conn_alive(conn) && waited < PORTAL_ANSWER_MS {
		dbus.dispatch(conn)
		if answer.done { break }
		pfd := posix.pollfd{fd = posix.FD(dbus.conn_fd(conn)), events = {.IN}}
		posix.poll(&pfd, 1, PORTAL_POLL_MS)
		waited += PORTAL_POLL_MS
	}
	if !answer.done { return {}, .Failed }
	switch answer.code {
	case RESPONSE_OK:
	case RESPONSE_CANCELLED: return {}, .Denied
	case: return {}, .Failed
	}
	path, is_file := file_uri_path(answer.uri, context.temp_allocator)
	if !is_file { return {}, .Failed }
	data, read_err := os.read_entire_file(path, runtime.heap_allocator())
	if read_err != nil { return {}, .Failed }
	defer delete(data, runtime.heap_allocator())
	rgba, width, height, decoded := png.decode(data, runtime.heap_allocator())
	if !decoded { return {}, .Failed }
	defer delete(rgba, runtime.heap_allocator())
	f = frame_from_buffer(rgba, i32(width), i32(height), i32(width) * 4, .RGBA, .Normal, false, true, allocator)
	p.size = {f.width, f.height}
	return f, .None
}

// /org/freedesktop/portal/desktop/request/SENDER/TOKEN: the sender is the connection's name without its colon, its dots
// as underscores (temporary allocator).
@(private = "file")
request_path :: proc(conn: ^dbus.Conn, token: string) -> string {
	sender, _ := strings.replace_all(strings.trim_prefix(dbus.conn_name(conn), ":"), ".", "_", context.temp_allocator)
	return strings.concatenate({"/org/freedesktop/portal/desktop/request/", sender, "/", token}, context.temp_allocator)
}

// Response(u response, a{sv} results): results["uri"] is the picture's.
@(private = "file")
portal_response :: proc(user: rawptr, msg: ^dbus.Message) {
	a := (^Portal_Answer)(user)
	r := dbus.msg_reader(msg)
	a.code = dbus.r_u32(&r)
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		if key != "uri" { dbus.read_variant_skip(&r); continue }
		vs := dbus.r_variant_sig(&r)
		if vs != "s" { dbus.r_skip(&r, vs); continue }
		delete(a.uri, runtime.heap_allocator())
		a.uri = strings.clone(dbus.r_string(&r), runtime.heap_allocator())
	}
	a.done = true
}

// Without Wayland: the one output there is, the picture's size (a picture is taken to learn it, once).
@(private)
portal_outputs :: proc(p: ^Portal_State, s: ^Session) {
	if p.size.x <= 0 {
		f, err := portal_screenshot(p, s.allocator)
		if err != .None { return }
		frame_free(&f)
	}
	append(&s.outputs, Output{id = 0, name = strings.clone("screen", s.allocator), rect = {0, 0, p.size.x, p.size.y}, scale = 1})
}

// The portal's picture placed over the outputs' bounding rectangle (`places`: the outputs' logical rects; none: the
// picture at {0, 0}, scale 1). The portal's picture covers that rectangle: its scale is its width over the rectangle's.
@(private)
portal_desktop :: proc(p: ^Portal_State, places: []Rect, allocator: runtime.Allocator) -> (f: Frame, err: Error) {
	f = portal_screenshot(p, allocator) or_return
	if len(places) == 0 { return f, .None }
	x0, y0, x1, y1 := max(i32), max(i32), min(i32), min(i32)
	for r in places {
		x0, y0 = min(x0, r.x), min(y0, r.y)
		x1, y1 = max(x1, r.x + r.w), max(y1, r.y + r.h)
	}
	if x1 > x0 {
		f.origin = {x0, y0}
		f.scale = f32(f.width) / f32(x1 - x0)
	}
	return f, .None
}
