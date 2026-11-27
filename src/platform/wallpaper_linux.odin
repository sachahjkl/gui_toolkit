#+build linux
package platform

// set_wallpaper through the desktop portal: SetWallpaperFile(parent, the picture's descriptor, options), answered on its
// request's Response signal (0: set, 1: the person said no, 2: ended). On a connection of its own on the calling thread,
// as the print portal's: the portal may show the picture and wait for the person.

import "core:strings"
import "core:sys/linux"
import "../dbus"

@(private = "file") WALLPAPER_IFACE :: "org.freedesktop.portal.Wallpaper"
@(private = "file") WALLPAPER_CALL_MS :: 8000   // the request's own answer, not the time the person takes
@(private = "file") WALLPAPER_POLL_MS :: 200

set_wallpaper :: proc(path: string) -> Wallpaper_Result { return wallpaper_set_at(path, "") }

// set_wallpaper on the bus at `address` ("": the session's). A test names a bus that is nowhere: it never reaches the
// person's portal, and sets no variable of the process that the other tests' threads read.
@(private)
wallpaper_set_at :: proc(path, address: string) -> Wallpaper_Result {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(cpath, {.CLOEXEC})
	if err != .NONE { return .Failed }
	defer linux.close(fd)
	conn := address == "" ? dbus.connect_bus(.Session, unix_fds = true) : dbus.connect_bus_address(address, unix_fds = true)
	if conn == nil { return .Unsupported }
	defer dbus.conn_close(conn)
	if !dbus.conn_unix_fds(conn) { return .Unsupported }
	token := portal_token()
	body := wallpaper_body(token)
	answer: Portal_Answer
	expected := portal_request_path(conn, token)
	sub := dbus.subscribe(conn, PORTAL_SERVICE, expected, REQUEST_IFACE, "Response", portal_answer_signal, &answer)
	defer dbus.unsubscribe(conn, sub)
	fds := [1]i32{i32(fd)}
	// (a refusal: no portal on this bus, or none that sets a wallpaper)
	msg, ok := dbus.call_with_fds(conn, PORTAL_SERVICE, PORTAL_PATH, WALLPAPER_IFACE, "SetWallpaperFile", "sha{sv}", body, fds[:], WALLPAPER_CALL_MS)
	if !ok { return .Unsupported }
	r := dbus.msg_reader(&msg)
	request_path := dbus.r_string(&r)
	// (an old portal chose the handle itself)
	other: u32
	if request_path != expected { other = dbus.subscribe(conn, PORTAL_SERVICE, request_path, REQUEST_IFACE, "Response", portal_answer_signal, &answer) }
	defer if other != 0 { dbus.unsubscribe(conn, other) }
	for !answer.done {
		dbus.dispatch(conn)
		if !dbus.conn_alive(conn) { break }
		portal_wait_fd(dbus.conn_fd(conn), WALLPAPER_POLL_MS)
	}
	return wallpaper_result(answer)
}

// SetWallpaperFile's arguments after the descriptor's place: no parent window, the descriptor (the call's first), no
// preview (the person chose the act in the program already), the desktop's background only.
@(private)
wallpaper_body :: proc(token: string) -> []u8 {
	w := dbus.body_writer()
	dbus.w_string(&w, "")
	dbus.w_u32(&w, 0)   // (the 'h': the first descriptor of the call)
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, token)
	dbus.arg_dict_entry(&w, "show-preview"); dbus.arg_variant_bool(&w, false)
	dbus.arg_dict_entry(&w, "set-on"); dbus.arg_variant_string(&w, "background")
	dbus.arg_dict_end(&w, ol, oc)
	return w.buf[:]
}

// What a portal request's Response said: its code, the results left unread.
@(private)
Portal_Answer :: struct { done: bool, code: u32 }

@(private)
portal_answer_signal :: proc(user: rawptr, msg: ^dbus.Message) {
	a := (^Portal_Answer)(user)
	r := dbus.msg_reader(msg)
	a.code = dbus.r_u32(&r)
	a.done = true
}

@(private)
wallpaper_result :: proc(a: Portal_Answer) -> Wallpaper_Result {
	if !a.done { return .Failed }   // (the bus went away)
	switch a.code {
	case 0: return .Set
	case 1: return .Cancelled
	}
	return .Failed
}
