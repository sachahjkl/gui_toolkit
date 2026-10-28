#+build linux
package dbus

// Exporting objects: a service we run (the StatusNotifierItem and its com.canonical.dbusmenu) answers method calls the
// bus routes to us. An exported object is an object path plus a handler the dispatch loop calls for a Method_Call to
// that path; the handler reads the call and replies (reply_return / reply_error). This is enough for the tray, whose
// host calls a handful of methods (Activate, ContextMenu, Scroll) and reads properties.

import "base:runtime"
import "core:os"
import "core:strings"

// A handler for a method call on an exported object. It returns true when it handled the call (sent a reply); false
// lets the connection send the default "unknown method" error.
Object_Handler :: #type proc(user: rawptr, c: ^Conn, msg: ^Message) -> bool

@(private)
Exported :: struct {
	path:    string,
	handler: Object_Handler,
	user:    rawptr,
}

// Registers an object at `path`; its handler answers method calls the bus routes there. One handler per path (a later
// registration replaces an earlier one).
export_object :: proc(c: ^Conn, path: string, handler: Object_Handler, user: rawptr) {
	if c == nil { return }
	if c.exports == nil { c.exports = new([dynamic]Exported) }
	for &e in c.exports {
		if e.path == path { e.handler = handler; e.user = user; return }
	}
	append(c.exports, Exported{path = strings.clone(path), handler = handler, user = user})
}

export_remove :: proc(c: ^Conn, path: string) {
	if c == nil || c.exports == nil { return }
	for &e, i in c.exports {
		if e.path == path { delete(e.path); unordered_remove(c.exports, i); return }
	}
}

// Requests a well-known name on the bus (RequestName). `flags`: the usual 0 (or the "replace existing" / "do not
// queue" bits). Returns true when the bus granted it (reply code 1 primary owner, 4 already owner).
request_name :: proc(c: ^Conn, name: string, flags: u32 = 0) -> bool {
	w := writer_make(context.temp_allocator)
	w_string(&w, name)
	w_u32(&w, flags)
	msg, ok := call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", w.buf[:], 5000)
	if !ok { return false }
	r := msg_reader(&msg)
	code := r_u32(&r)
	return code == 1 || code == 4   // PRIMARY_OWNER or ALREADY_OWNER
}

@(private)
export_handle_call :: proc(c: ^Conn, msg: ^Message) {
	// org.freedesktop.DBus.Peer.Ping / GetMachineId: answer generically so any object is a well-behaved peer
	if msg.iface == "org.freedesktop.DBus.Peer" {
		switch msg.member {
		case "Ping":
			reply_return(c, msg, "", nil)
			return
		case "GetMachineId":
			w := writer_make(context.temp_allocator)
			w_string(&w, machine_id())
			reply_return(c, msg, "s", w.buf[:])
			return
		}
	}
	if c.exports != nil {
		for &e in c.exports {
			if e.path != msg.path { continue }
			if e.handler != nil && e.handler(e.user, c, msg) { return }
		}
	}
	// no object, or the handler declined: the caller expects an error unless it said NO_REPLY
	if msg.flags & FLAG_NO_REPLY_EXPECTED == 0 {
		reply_error(c, msg, "org.freedesktop.DBus.Error.UnknownMethod", "No such method")
	}
}

@(private)
machine_id :: proc() -> string {
	read_id :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { return "" }
		return strings.trim_space(string(data))
	}
	if id := read_id("/etc/machine-id"); id != "" { return id }
	if id := read_id("/var/lib/dbus/machine-id"); id != "" { return id }
	return "00000000000000000000000000000000"
}

_ :: runtime
