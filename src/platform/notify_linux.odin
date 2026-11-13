package platform

// Notifications on Linux (notify.odin has the API): org.freedesktop.Notifications on the platform's session bus
// (dbus_linux.odin). The one Notify of the toolkit: tray_notify (tray_linux.odin) comes here too, its results going to
// the icon's events instead of the window's.
//
//   * notify asks the server's capabilities once per bus (GetCapabilities: actions, body markup), then calls Notify with
//     notify_dbus_body's arguments. The server's id is the notification's.
//   * The window listens to ActionInvoked, NotificationClosed and ActivationToken from its first notification; a signal
//     about an id the window did not show is another program's, or another window's.
//   * ActivationToken comes before ActionInvoked: an xdg-activation token the server got for the click. raise_window
//     (Wayland) uses it, so that a click on the notification brings the window to the front (notify_activation_token).

import "core:time"
import "../dbus"
import base "../base"

@(private) NOTIFY_SERVICE :: "org.freedesktop.Notifications"
@(private) NOTIFY_PATH :: "/org/freedesktop/Notifications"
@(private = "file") NOTIFY_CALL_MS :: 5000
// How long an activation token stays usable: the click it comes with is what the window raises for.
@(private = "file") NOTIFY_TOKEN_LIFE :: 10 * time.Second

// The notifications a window showed and the signals it listens to (Window.notify).
Notify_State :: struct {
	live:     [dynamic]Notify_Live,
	sub_action, sub_closed, sub_token: u32,
	token:    string,      // the last ActivationToken of a notification of the window (owned)
	token_at: time.Tick,
}

@(private)
Notify_Live :: struct {
	id:   Notification_Id,
	tray: ^Tray,   // tray_notify's: the results are the icon's events
}

@(private)
notify_app_declared :: proc() {}

notify_supported :: proc() -> bool {
	conn := session_bus()
	if conn == nil { return false }
	_, ok := notify_server_caps(conn)
	return ok
}

notify :: proc(w: ^Window, n: Notification, loc := #caller_location) -> (id: Notification_Id, ok: bool) {
	base.blocking("platform.notify", loc)
	return notify_send(w, n, nil)
}

// Asks the server to close it: a Notification_Closed (reason Closed) follows.
notify_close :: proc(w: ^Window, id: Notification_Id) {
	if w == nil || id == 0 { return }
	conn := session_bus()
	if conn == nil { return }
	b := dbus.body_writer()
	dbus.w_u32(&b, u32(id))
	dbus.call_noreply(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "CloseNotification", "u", b.buf[:])
}

// The activation token of the last click on a notification of the window, for 10 s ("" otherwise): what a program gives
// a process it starts for that click (XDG_ACTIVATION_TOKEN). raise_window uses it on Wayland.
notify_activation_token :: proc(w: ^Window) -> string {
	if w == nil || w.notify.token == "" || time.tick_since(w.notify.token_at) > NOTIFY_TOKEN_LIFE { return "" }
	return w.notify.token
}

// The server's capabilities: asked once per bus; ok = false when no server answers (asked again next time).
@(private)
notify_server_caps :: proc(conn: ^dbus.Conn) -> (caps: Notify_Caps, ok: bool) {
	if session.notify_caps_known { return session.notify_caps, true }
	msg, answered := dbus.call(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "GetCapabilities", "", nil, DBUS_QUICK_CALL_MS)
	if !answered { return {}, false }
	r := dbus.msg_reader(&msg)
	names := make([dynamic]string, context.temp_allocator)
	end := dbus.r_array_begin(&r, "s")
	for r.pos < end && !r.err { append(&names, dbus.r_string(&r)) }
	session.notify_caps = notify_caps_of(names[:])
	session.notify_caps_known = true
	return session.notify_caps, true
}

@(private)
notify_send :: proc(w: ^Window, n: Notification, tray: ^Tray) -> (id: Notification_Id, ok: bool) {
	if w == nil { return 0, false }
	conn := session_bus()
	if conn == nil { return 0, false }
	caps := notify_server_caps(conn) or_return
	name := notify_app.name != "" ? notify_app.name : app_id_or_exe()
	icon := notify_app.icon_path != "" ? file_uri_of_unix_path(notify_app.icon_path) : ""
	body := notify_dbus_body(n, name, icon, app_id_or_exe(), caps)
	msg, answered := dbus.call(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "Notify", NOTIFY_SIGNATURE, body, NOTIFY_CALL_MS)
	if !answered { return 0, false }
	r := dbus.msg_reader(&msg)
	id = Notification_Id(dbus.r_u32(&r))
	if r.err || id == 0 { return 0, false }
	notify_listen(w, conn)
	if n.replace != 0 { notify_forget(w, n.replace) }   // (the server's: the same id, or the old one is gone)
	notify_forget(w, id)
	append(&w.notify.live, Notify_Live{id = id, tray = tray})
	return id, true
}

// notify, without waiting for the server: the call goes out now, `done` runs from the window loop (the bus is pumped
// there) once the server answers, with the notification's id, or ok false when there is no server or it refused. The
// server's capabilities are asked first the same way when they are not known yet. `w` must outlive the answer (a
// program's long-lived window: its anchor, its main window). False: nothing was sent (no session bus): `done` will not
// run.
notify_async :: proc(w: ^Window, n: Notification, done: Notify_Done = nil, user: rawptr = nil) -> bool {
	if w == nil { return false }
	conn := session_bus()
	if conn == nil { return false }
	req := new(Notify_Request)
	req^ = {w = w, n = notification_clone(n), done = done, user = user}
	if session.notify_caps_known { return notify_request_send(conn, req) }
	handler :: proc(user: rawptr, status: dbus.Call_Status, msg: ^dbus.Message) {
		req := (^Notify_Request)(user)
		conn := session_bus()
		if status != .Ok || msg == nil || conn == nil { notify_request_end(req, 0, false); return }
		r := dbus.msg_reader(msg)
		names := make([dynamic]string, context.temp_allocator)
		end := dbus.r_array_begin(&r, "s")
		for r.pos < end && !r.err { append(&names, dbus.r_string(&r)) }
		session.notify_caps = notify_caps_of(names[:])
		session.notify_caps_known = true
		if !notify_request_send(conn, req) { notify_request_end(req, 0, false) }
	}
	if dbus.call_async(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "GetCapabilities", "", nil, handler, req, DBUS_QUICK_CALL_MS) { return true }
	notify_request_end(req, 0, false)
	return false
}

@(private = "file")
Notify_Request :: struct {
	w:    ^Window,
	n:    Notification,   // owned
	done: Notify_Done,
	user: rawptr,
}

@(private = "file")
notify_request_send :: proc(conn: ^dbus.Conn, req: ^Notify_Request) -> bool {
	name := notify_app.name != "" ? notify_app.name : app_id_or_exe()
	icon := notify_app.icon_path != "" ? file_uri_of_unix_path(notify_app.icon_path) : ""
	body := notify_dbus_body(req.n, name, icon, app_id_or_exe(), session.notify_caps)
	handler :: proc(user: rawptr, status: dbus.Call_Status, msg: ^dbus.Message) {
		req := (^Notify_Request)(user)
		if status != .Ok || msg == nil { notify_request_end(req, 0, false); return }
		r := dbus.msg_reader(msg)
		id := Notification_Id(dbus.r_u32(&r))
		if r.err || id == 0 { notify_request_end(req, 0, false); return }
		// (the window's list, as notify keeps it: its signals are listened to, a replaced one is forgotten)
		if conn := session_bus(); conn != nil { notify_listen(req.w, conn) }
		if req.n.replace != 0 { notify_forget(req.w, req.n.replace) }
		notify_forget(req.w, id)
		append(&req.w.notify.live, Notify_Live{id = id})
		notify_request_end(req, id, true)
	}
	return dbus.call_async(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "Notify", NOTIFY_SIGNATURE, body, handler, req, NOTIFY_CALL_MS)
}

@(private = "file")
notify_request_end :: proc(req: ^Notify_Request, id: Notification_Id, ok: bool) {
	if req.done != nil { req.done(req.user, id, ok) }
	notification_free(&req.n)
	free(req)
}

@(private = "file")
file_uri_of_unix_path :: proc(path: string) -> string {
	return len(path) > 0 && path[0] == '/' ? concat_temp("file://", path) : path
}

@(private = "file")
concat_temp :: proc(a, b: string) -> string {
	out := make([]u8, len(a) + len(b), context.temp_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

@(private = "file")
notify_listen :: proc(w: ^Window, conn: ^dbus.Conn) {
	s := &w.notify
	if s.sub_action != 0 { return }
	s.sub_action = dbus.subscribe(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "ActionInvoked", notify_action_signal, w)
	s.sub_closed = dbus.subscribe(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "NotificationClosed", notify_closed_signal, w)
	s.sub_token = dbus.subscribe(conn, NOTIFY_SERVICE, NOTIFY_PATH, NOTIFY_SERVICE, "ActivationToken", notify_token_signal, w)
}

@(private = "file")
notify_find :: proc(w: ^Window, id: Notification_Id) -> int {
	for l, i in w.notify.live { if l.id == id { return i } }
	return -1
}

@(private = "file")
notify_forget :: proc(w: ^Window, id: Notification_Id) {
	if i := notify_find(w, id); i >= 0 { ordered_remove(&w.notify.live, i) }
}

@(private = "file")
notify_push :: proc(w: ^Window, kind: Event_Kind, e: Notification_Event) {
	append(&w.events, Event{kind = kind, notification = e, stamp = time.tick_now()})
}

@(private = "file")
notify_action_signal :: proc(user: rawptr, msg: ^dbus.Message) {
	w := (^Window)(user)
	r := dbus.msg_reader(msg)
	id := Notification_Id(dbus.r_u32(&r))
	key := dbus.r_string(&r)
	i := notify_find(w, id)
	if r.err || i < 0 { return }
	if t := w.notify.live[i].tray; t != nil {
		tray_push(t, {kind = .Notify_Click})
		return
	}
	kind, action, ok := notify_action_of_key(key)
	if ok { notify_push(w, kind, {id = id, action = action}) }
}

@(private = "file")
notify_closed_signal :: proc(user: rawptr, msg: ^dbus.Message) {
	w := (^Window)(user)
	r := dbus.msg_reader(msg)
	id := Notification_Id(dbus.r_u32(&r))
	code := dbus.r_u32(&r)
	i := notify_find(w, id)
	if r.err || i < 0 { return }
	t := w.notify.live[i].tray
	ordered_remove(&w.notify.live, i)
	reason := notify_reason_of_code(code)
	if t != nil {
		if t.last_notify == u32(id) { t.last_notify = 0 }
		tray_push(t, {kind = reason == .Expired ? .Notify_Timeout : .Notify_Hidden})
		return
	}
	notify_push(w, .Notification_Closed, {id = id, reason = reason})
}

@(private = "file")
notify_token_signal :: proc(user: rawptr, msg: ^dbus.Message) {
	w := (^Window)(user)
	r := dbus.msg_reader(msg)
	id := Notification_Id(dbus.r_u32(&r))
	token := dbus.r_string(&r)
	if r.err || notify_find(w, id) < 0 { return }
	delete(w.notify.token)
	w.notify.token = clone_string(token)
	w.notify.token_at = time.tick_now()
}

// The token of the last click, taken (raise_window): one activation per click.
@(private)
notify_take_token :: proc(w: ^Window) -> string {
	tok := notify_activation_token(w)
	if tok == "" { return "" }
	out := concat_temp(tok, "")
	delete(w.notify.token)
	w.notify.token = ""
	return out
}

// The icon is going: its notifications stay on the screen, their results go nowhere.
@(private)
notify_tray_gone :: proc(w: ^Window, t: ^Tray) {
	if w == nil { return }
	for i := len(w.notify.live) - 1; i >= 0; i -= 1 {
		if w.notify.live[i].tray == t { ordered_remove(&w.notify.live, i) }
	}
}

// The window is going (destroy_window): its notifications stay on the screen, their results go nowhere.
@(private)
notify_detach :: proc(w: ^Window) {
	s := &w.notify
	if conn := session.conn; conn != nil {
		if s.sub_action != 0 { dbus.unsubscribe(conn, s.sub_action) }
		if s.sub_closed != 0 { dbus.unsubscribe(conn, s.sub_closed) }
		if s.sub_token != 0 { dbus.unsubscribe(conn, s.sub_token) }
	}
	delete(s.live)
	delete(s.token)
	s^ = {}
}
