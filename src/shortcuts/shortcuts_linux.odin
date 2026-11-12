#+build linux
package tk_shortcuts

// Linux: the desktop portal's GlobalShortcuts (org.freedesktop.portal.GlobalShortcuts), on a thread of its own with its
// own session bus connection (a dbus.Conn is one thread's). The thread:
//
//   1. registers the program's app id (org.freedesktop.host.portal.Registry, xdg-desktop-portal 1.19: a program that is
//      not in a sandbox is otherwise known by no name, and the system cannot keep its shortcuts);
//   2. reads the interface's version (none: Unavailable; 2 or more: the system has a page of its own, ConfigureShortcuts);
//   3. at each bind: closes the session before, creates one (CreateSession), binds the set (BindShortcuts) and waits for
//      the answer, which may come after the user confirmed in a dialog of the system; each shortcut is then Bound with
//      the keys the system words, or No_Keys;
//   4. turns Activated into activations and ShortcutsChanged into new statuses.
//
// The program's thread hands it commands (a queue under the service's lock) and wakes it through a pipe; it sleeps in
// poll(2) on that pipe and the bus.

import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import "../dbus"
import "../platform"

@(private = "file") PORTAL_SERVICE :: "org.freedesktop.portal.Desktop"
@(private = "file") PORTAL_PATH    :: "/org/freedesktop/portal/desktop"
@(private = "file") SHORTCUTS_IFACE :: "org.freedesktop.portal.GlobalShortcuts"
@(private = "file") REQUEST_IFACE  :: "org.freedesktop.portal.Request"
@(private = "file") SESSION_IFACE  :: "org.freedesktop.portal.Session"
@(private = "file") REGISTRY_IFACE :: "org.freedesktop.host.portal.Registry"
@(private = "file") PROPERTIES_IFACE :: "org.freedesktop.DBus.Properties"

// A call that answers at once (a property, the registry).
@(private = "file") QUICK_CALL_MS :: 3000
// How long a request's answer is waited for: the system may ask the user first.
@(private = "file") ANSWER_WAIT :: 120 * time.Second
@(private = "file") CONFIGURE_SINCE :: 2
@(private = "file") RESPONSE_OK :: 0

@(private = "file")
Command :: union {
	Command_Bind,
	Command_Configure,
}
@(private = "file") Command_Bind :: struct { list: []Shortcut }   // (owned: ids and descriptions)
@(private = "file") Command_Configure :: struct {}

@(private = "file")
Linux :: struct {
	thread:   ^thread.Thread,
	pipe:     [2]posix.FD,          // the program writes a byte to [1]; the thread polls [0]
	queue:    [dynamic]Command,     // guarded by the service's lock
	stopping: bool,                 // guarded by the service's lock
	// the thread's own
	conn:     ^dbus.Conn,
	version:  u32,
	session:  string,               // the session's object path ("": none)
	tokens:   u64,
}

@(private)
system_start :: proc(s: ^Service) {
	l := new(Linux, s.allocator)
	l.queue.allocator = s.allocator
	s.impl = l
	if posix.pipe(&l.pipe) != .OK { l.pipe = {-1, -1} }
	l.thread = thread.create_and_start_with_poly_data(s, service_thread)
}

@(private)
system_stop :: proc(s: ^Service) {
	l := (^Linux)(s.impl)
	{
		sync.guard(&s.lock)
		l.stopping = true
	}
	poke(l)
	thread.join(l.thread)
	thread.destroy(l.thread)
	for c in l.queue { command_free(s, c) }
	delete(l.queue)
	if l.pipe[0] >= 0 { posix.close(l.pipe[0]); posix.close(l.pipe[1]) }
	free(l, s.allocator)
}

@(private)
system_bind :: proc(s: ^Service, list: []Shortcut) {
	l := (^Linux)(s.impl)
	own := make([]Shortcut, len(list), s.allocator)
	for sc, i in list {
		own[i] = {id = strings.clone(sc.id, s.allocator), description = strings.clone(sc.description, s.allocator), trigger = sc.trigger}
	}
	{
		sync.guard(&s.lock)
		// (a bind not begun yet is replaced: only the last set counts)
		for i := len(l.queue) - 1; i >= 0; i -= 1 {
			if _, is_bind := l.queue[i].(Command_Bind); is_bind {
				command_free(s, l.queue[i])
				ordered_remove(&l.queue, i)
			}
		}
		append(&l.queue, Command_Bind{own})
	}
	poke(l)
}

@(private)
system_configure :: proc(s: ^Service) -> bool {
	l := (^Linux)(s.impl)
	{
		sync.guard(&s.lock)
		append(&l.queue, Command_Configure{})
	}
	poke(l)
	return true
}

@(private)
system_feed :: proc(s: ^Service, e: platform.Event) -> bool { return false }
@(private)
system_hold :: proc(s: ^Service, held: bool) {}

@(private = "file")
poke :: proc(l: ^Linux) {
	if l.pipe[1] < 0 { return }
	b := [1]u8{1}
	_ = posix.write(l.pipe[1], &b[0], 1)
}

@(private = "file")
command_free :: proc(s: ^Service, c: Command) {
	if b, is_bind := c.(Command_Bind); is_bind {
		for sc in b.list { delete(sc.id, s.allocator); delete(sc.description, s.allocator) }
		delete(b.list, s.allocator)
	}
}

////////////////////////////////
// The thread

@(private = "file")
service_thread :: proc(s: ^Service) {
	l := (^Linux)(s.impl)
	l.conn = dbus.connect_bus(.Session)
	defer if l.conn != nil { dbus.conn_close(l.conn) }
	if l.conn != nil {
		register_app(l, s.options.app_id)
		l.version = read_version(l)
	}
	if l.version == 0 {
		set_backend(s, .None, false)
	} else {
		set_backend(s, .Portal, l.version >= CONFIGURE_SINCE)
		dbus.subscribe(l.conn, PORTAL_SERVICE, PORTAL_PATH, SHORTCUTS_IFACE, "Activated", on_activated, s)
		dbus.subscribe(l.conn, PORTAL_SERVICE, PORTAL_PATH, SHORTCUTS_IFACE, "ShortcutsChanged", on_changed, s)
	}
	for {
		if stopping(s) { break }
		for c in next_commands(s) {
			defer command_free(s, c)
			switch v in c {
			case Command_Bind:      bind_now(s, l, v.list)
			case Command_Configure: configure_now(l)
			}
			if stopping(s) { break }
		}
		wait(l, -1)
		if l.conn != nil { dbus.dispatch(l.conn) }
	}
	close_session(l)
	delete(l.session)
}

@(private = "file")
stopping :: proc(s: ^Service) -> bool {
	sync.guard(&s.lock)
	return (^Linux)(s.impl).stopping
}

// The commands queued, taken (the caller frees each).
@(private = "file")
next_commands :: proc(s: ^Service) -> []Command {
	sync.guard(&s.lock)
	l := (^Linux)(s.impl)
	out := make([]Command, len(l.queue), context.temp_allocator)
	copy(out, l.queue[:])
	clear(&l.queue)
	return out
}

// Sleeps until the pipe or the bus has something, or `timeout_ms` (-1: no limit). The pipe's bytes are read off.
@(private = "file")
wait :: proc(l: ^Linux, timeout_ms: i32) {
	fds: [2]posix.pollfd
	n: posix.nfds_t = 0
	if l.pipe[0] >= 0 { fds[n] = {fd = l.pipe[0], events = {.IN}}; n += 1 }
	if l.conn != nil && dbus.conn_alive(l.conn) { fds[n] = {fd = posix.FD(dbus.conn_fd(l.conn)), events = {.IN}}; n += 1 }
	if n == 0 { time.sleep(time.Duration(max(timeout_ms, 100)) * time.Millisecond); return }
	posix.poll(&fds[0], n, timeout_ms)
	if l.pipe[0] >= 0 && .IN in fds[0].revents {
		buf: [64]u8
		_ = posix.read(l.pipe[0], &buf[0], len(buf))
	}
}

@(private = "file")
register_app :: proc(l: ^Linux, app_id: string) {
	if app_id == "" { return }
	w := dbus.body_writer()
	dbus.w_string(&w, app_id)
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_end(&w, ol, oc)
	// (an older portal has no registry: the program is then known by its process, as before)
	_, _ = dbus.call(l.conn, PORTAL_SERVICE, PORTAL_PATH, REGISTRY_IFACE, "Register", "sa{sv}", w.buf[:], QUICK_CALL_MS)
}

@(private = "file")
read_version :: proc(l: ^Linux) -> u32 {
	w := dbus.body_writer()
	dbus.w_string(&w, SHORTCUTS_IFACE)
	dbus.w_string(&w, "version")
	msg, ok := dbus.call(l.conn, PORTAL_SERVICE, PORTAL_PATH, PROPERTIES_IFACE, "Get", "ss", w.buf[:], QUICK_CALL_MS)
	if !ok { return 0 }
	r := dbus.msg_reader(&msg)
	return dbus.read_variant_u32_nested(&r)
}

// A new token for a request or a session: the program's prefix and a count.
@(private = "file")
token :: proc(l: ^Linux) -> string {
	l.tokens += 1
	digits: [24]u8
	return strings.concatenate({"gtshortcuts", strconv.write_uint(digits[:], l.tokens, 10)}, context.temp_allocator)
}

// /org/freedesktop/portal/desktop/<kind>/SENDER/TOKEN: the sender is the connection's name without its colon, its dots
// as underscores.
@(private = "file")
object_path :: proc(l: ^Linux, kind, tok: string) -> string {
	sender, _ := strings.replace_all(strings.trim_prefix(dbus.conn_name(l.conn), ":"), ".", "_", context.temp_allocator)
	return strings.concatenate({PORTAL_PATH, "/", kind, "/", sender, "/", tok}, context.temp_allocator)
}

// What a request's Response said (copied out of the message: it goes when the handler returns).
@(private = "file")
Answer :: struct {
	done:     bool,
	code:     u32,
	session:  string,                 // CreateSession's session_handle (temporary allocator)
	bound:    [dynamic]Bound_Key,     // BindShortcuts' shortcuts (temporary allocator)
	has_list: bool,
}

@(private = "file")
Bound_Key :: struct { id, trigger: string }

@(private = "file")
on_response :: proc(user: rawptr, msg: ^dbus.Message) {
	a := (^Answer)(user)
	r := dbus.msg_reader(msg)
	a.code = dbus.r_u32(&r)
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end && !r.err {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		vs := dbus.r_variant_sig(&r)
		switch {
		case key == "session_handle" && (vs == "s" || vs == "o"):
			a.session = strings.clone(dbus.r_string(&r), context.temp_allocator)
		case key == "shortcuts" && vs == "a(sa{sv})":
			read_list(&r, &a.bound)
			a.has_list = true
		case:
			dbus.r_skip(&r, vs)
		}
	}
	a.done = true
}

// a(sa{sv}): each shortcut's id and its trigger_description (temporary allocator).
@(private = "file")
read_list :: proc(r: ^dbus.Reader, out: ^[dynamic]Bound_Key) {
	out.allocator = context.temp_allocator
	end := dbus.r_array_begin(r, "(sa{sv})")
	for r.pos < end && !r.err {
		dbus.r_align_entry(r)
		k := Bound_Key{id = strings.clone(dbus.r_string(r), context.temp_allocator)}
		dend := dbus.r_array_begin(r, "{sv}")
		for r.pos < dend && !r.err {
			dbus.r_align_entry(r)
			key := dbus.r_string(r)
			vs := dbus.r_variant_sig(r)
			if key == "trigger_description" && vs == "s" { k.trigger = strings.clone(dbus.r_string(r), context.temp_allocator) } else { dbus.r_skip(r, vs) }
		}
		append(out, k)
	}
}

// Calls a method that answers with a request, then waits for its Response (a stop ends the wait). ok is false when the
// call failed or no answer came.
@(private = "file")
request :: proc(s: ^Service, l: ^Linux, member, signature: string, body: []u8, tok: string, a: ^Answer) -> bool {
	expected := object_path(l, "request", tok)
	// (subscribed before the call: the answer may come before the call's own reply is read)
	sub := dbus.subscribe(l.conn, PORTAL_SERVICE, expected, REQUEST_IFACE, "Response", on_response, a)
	defer dbus.unsubscribe(l.conn, sub)
	msg, ok := dbus.call(l.conn, PORTAL_SERVICE, PORTAL_PATH, SHORTCUTS_IFACE, member, signature, body, QUICK_CALL_MS)
	if !ok { return false }
	r := dbus.msg_reader(&msg)
	handle := dbus.r_string(&r)
	other: u32
	if handle != expected { other = dbus.subscribe(l.conn, PORTAL_SERVICE, handle, REQUEST_IFACE, "Response", on_response, a) }
	defer if other != 0 { dbus.unsubscribe(l.conn, other) }
	deadline := time.tick_add(time.tick_now(), ANSWER_WAIT)
	for !a.done && dbus.conn_alive(l.conn) && time.tick_diff(time.tick_now(), deadline) > 0 {
		if stopping(s) { return false }
		dbus.dispatch(l.conn)
		if a.done { break }
		wait(l, 250)
	}
	return a.done
}

@(private = "file")
bind_now :: proc(s: ^Service, l: ^Linux, list: []Shortcut) {
	if l.version == 0 { set_all(s, .Unavailable); return }
	close_session(l)
	// a session
	tok, stok := token(l), token(l)
	w := dbus.body_writer()
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, tok)
	dbus.arg_dict_entry(&w, "session_handle_token"); dbus.arg_variant_string(&w, stok)
	dbus.arg_dict_end(&w, ol, oc)
	a: Answer
	if !request(s, l, "CreateSession", "a{sv}", w.buf[:], tok, &a) || a.code != RESPONSE_OK {
		set_all(s, a.done ? .Refused : .Unavailable)
		return
	}
	session := a.session != "" ? a.session : object_path(l, "session", stok)
	delete(l.session)
	l.session = strings.clone(session)

	// the set, with the keys asked
	tok = token(l)
	w = dbus.body_writer()
	dbus.w_string(&w, l.session)
	al, ac := dbus.w_array_begin(&w, 8)
	for sc in list {
		dbus.w_struct(&w)
		dbus.w_string(&w, sc.id)
		dl, dc := dbus.arg_dict_begin(&w)
		dbus.arg_dict_entry(&w, "description"); dbus.arg_variant_string(&w, sc.description)
		if t := portal_trigger(sc.trigger); t != "" { dbus.arg_dict_entry(&w, "preferred_trigger"); dbus.arg_variant_string(&w, t) }
		dbus.arg_dict_end(&w, dl, dc)
	}
	dbus.w_array_end(&w, al, ac)
	dbus.w_string(&w, "")   // parent_window: none (the program has no window in front)
	ol, oc = dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "handle_token"); dbus.arg_variant_string(&w, tok)
	dbus.arg_dict_end(&w, ol, oc)
	b: Answer
	if !request(s, l, "BindShortcuts", "oa(sa{sv})sa{sv}", w.buf[:], tok, &b) {
		set_all(s, .Unavailable)
		return
	}
	if b.code != RESPONSE_OK { set_all(s, .Refused); return }
	apply_list(s, b.bound[:], list)
}

// The statuses from a list the system gave: a shortcut it names is Bound (or No_Keys without a trigger); one of `asked`
// it does not name was not taken.
@(private = "file")
apply_list :: proc(s: ^Service, bound: []Bound_Key, asked: []Shortcut) {
	for sc in asked {
		found := false
		for k in bound {
			if k.id != sc.id { continue }
			found = true
			set_status(s, sc.id, k.trigger != "" ? .Bound : .No_Keys, k.trigger)
		}
		if !found { set_status(s, sc.id, .Refused, "") }
	}
}

@(private = "file")
configure_now :: proc(l: ^Linux) {
	if l.session == "" || l.version < CONFIGURE_SINCE { return }
	w := dbus.body_writer()
	dbus.w_string(&w, l.session)
	dbus.w_string(&w, "")   // parent_window
	ol, oc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_end(&w, ol, oc)
	_ = dbus.call_noreply(l.conn, PORTAL_SERVICE, PORTAL_PATH, SHORTCUTS_IFACE, "ConfigureShortcuts", "osa{sv}", w.buf[:])
}

@(private = "file")
close_session :: proc(l: ^Linux) {
	if l.session == "" || l.conn == nil { return }
	_ = dbus.call_noreply(l.conn, PORTAL_SERVICE, l.session, SESSION_IFACE, "Close", "", nil)
	delete(l.session)
	l.session = ""
}

// Activated(o session_handle, s shortcut_id, t timestamp, a{sv} options)
@(private = "file")
on_activated :: proc(user: rawptr, msg: ^dbus.Message) {
	s := (^Service)(user)
	l := (^Linux)(s.impl)
	r := dbus.msg_reader(msg)
	session := dbus.r_string(&r)
	id := dbus.r_string(&r)
	if r.err || session != l.session { return }
	push_activated(s, id)
}

// ShortcutsChanged(o session_handle, a(sa{sv}) shortcuts): the user gave other keys in the system's settings.
@(private = "file")
on_changed :: proc(user: rawptr, msg: ^dbus.Message) {
	s := (^Service)(user)
	l := (^Linux)(s.impl)
	r := dbus.msg_reader(msg)
	if dbus.r_string(&r) != l.session { return }
	list: [dynamic]Bound_Key
	read_list(&r, &list)
	if r.err { return }
	for k in list { set_status(s, k.id, k.trigger != "" ? .Bound : .No_Keys, k.trigger) }
}
