#+build linux
package platform

// Accessibility on Linux through AT-SPI 2 over D-Bus (a11y.odin has the neutral tree the ui package builds). AT-SPI's
// registry lives on its own bus, whose address we ask the session bus for (org.a11y.Bus.GetAddress). A client (Orca)
// talks to our objects through the org.a11y.atspi.* interfaces; we expose the window's tree (Accessible, Component,
// Action, Text, Value) from the flat A11y_Update the toolkit sends.
//
// This is a minimal but real bridge: roles, names, descriptions, states, the parent/child structure, the bounds
// (Component.GetExtents), and the Action interface's Invoke / Focus. It is enough for a screen reader to read the
// window and act on its controls. The richer AccessKit `accesskit_unix` adapter is the alternative the report
// discusses (native/a11y); this keeps the toolkit self-contained with no Rust dependency on Linux.
//
// While no assistive technology runs (org.a11y.Status says so, the common case), or the a11y bus is unreachable, a11y_state
// stays Off and nothing is built, exactly as the Windows adapter does. The bridge's connection is read by the window's
// loop (a11y_fd, a11y_pump). It answers the calls on the window's root; it does not yet announce the window to the registry
// (org.a11y.atspi.Socket.Embed), so a reader that walks the desktop from there does not find it.

import "base:runtime"
import "core:strings"
import "../dbus"

@(private) ATSPI_BUS_NAME :: "org.a11y.Bus"
@(private) ATSPI_BUS_PATH :: "/org/a11y/bus"

// The window's accessibility bridge: a connection to the a11y bus and the last tree the toolkit sent.
@(private)
A11y_Bridge :: struct {
	conn:     ^dbus.Conn,
	update:   A11y_Update,     // the whole tree as the updates made it, owned here (a11y_tree_merge)
	requests: [dynamic]A11y_Request,
}

// What the session says of accessibility, for this thread. Unasked until the first frame that wonders. Absent: no a11y bus.
// Quiet: a bus, nobody reading. Listening: an assistive technology runs. Failed: a bus that refused the connection.
@(private) A11y_Bus_State :: enum u8 { Unasked, Absent, Quiet, Listening, Failed }

@(private = "file") ATSPI_STATUS_IFACE :: "org.a11y.Status"
@(private = "file") ATSPI_ENABLED_PROP :: "IsEnabled"

// Whether this build can read its windows to assistive technologies. True on Linux when the a11y bus answers.
a11y_available :: proc() -> bool { return a11y_bus_state() != .Absent && session.a11y != .Failed }

// Asks the session bus, once, for the a11y bus (org.a11y.Bus.GetAddress) and whether anything reads it; then follows that.
@(private)
a11y_bus_state :: proc() -> A11y_Bus_State {
	if session.a11y != .Unasked { return session.a11y }
	session.a11y = .Absent
	conn := session_bus()
	if conn == nil { return .Absent }
	msg, ok := dbus.call(conn, ATSPI_BUS_NAME, ATSPI_BUS_PATH, ATSPI_BUS_NAME, "GetAddress", "", nil, DBUS_QUICK_CALL_MS)
	if !ok { return .Absent }
	r := dbus.msg_reader(&msg)
	session.a11y_address = strings.clone(dbus.r_string(&r))
	if session.a11y_address == "" { return .Absent }
	w := dbus.body_writer()
	dbus.w_string(&w, ATSPI_STATUS_IFACE)
	dbus.w_string(&w, ATSPI_ENABLED_PROP)
	session.a11y = .Quiet
	if status, read := dbus.call(conn, ATSPI_BUS_NAME, ATSPI_BUS_PATH, PROPS_IFACE, "Get", "ss", w.buf[:], DBUS_QUICK_CALL_MS); read {
		sr := dbus.msg_reader(&status)
		if dbus.r_variant_sig(&sr) == "b" && dbus.r_bool(&sr) { session.a11y = .Listening }
	}
	session.a11y_sub = dbus.subscribe(conn, ATSPI_BUS_NAME, ATSPI_BUS_PATH, PROPS_IFACE, "PropertiesChanged", a11y_status_changed, nil)
	return session.a11y
}

// PropertiesChanged(interface s, changed a{sv}, invalidated as): the reader that comes, or goes.
@(private = "file")
a11y_status_changed :: proc(user: rawptr, msg: ^dbus.Message) {
	r := dbus.msg_reader(msg)
	if dbus.r_string(&r) != ATSPI_STATUS_IFACE { return }
	end := dbus.r_array_begin(&r, "{sv}")
	for r.pos < end {
		dbus.r_align_entry(&r)
		key := dbus.r_string(&r)
		sig := dbus.r_variant_sig(&r)
		if key == ATSPI_ENABLED_PROP && sig == "b" {
			if session.a11y == .Quiet || session.a11y == .Listening { session.a11y = dbus.r_bool(&r) ? .Listening : .Quiet }
		} else {
			dbus.r_skip(&r, sig)
		}
	}
}

@(private)
a11y_attach :: proc(w: ^Window) {
	// lazy: the bridge is made the first time the toolkit sends a tree while an assistive technology is listening.
}

@(private)
a11y_detach :: proc(w: ^Window) {
	if w.a11y == nil { return }
	b := (^A11y_Bridge)(w.a11y)
	a11y_update_destroy(&b.update)
	delete(b.requests)
	if b.conn != nil { dbus.conn_close(b.conn) }
	free(b)
	w.a11y = nil
}

// What the adapter needs now. Nobody reading, Off (the toolkit skips the tree). Then Full when the bridge has no tree (send
// the whole tree), Incremental after.
a11y_state :: proc(w: ^Window) -> A11y_State {
	if w == nil || w.offscreen || a11y_bus_state() != .Listening {
		if w != nil && w.a11y != nil { a11y_update_clear(&(^A11y_Bridge)(w.a11y).update) }   // (a reader that comes back gets a whole one)
		return .Off
	}
	if w.a11y == nil { return .Full }
	return len((^A11y_Bridge)(w.a11y).update.nodes) > 0 ? .Incremental : .Full
}

// Hands an update to the bridge, making the bridge on the first call. We keep the whole tree (the a11y bus is pull-based: a
// client asks for a node's properties, so we must be able to answer from it at any time): an update holds what changed.
a11y_send :: proc(w: ^Window, u: ^A11y_Update, toolkit_name := "gui_toolkit", toolkit_version := "") -> A11y_Send {
	if w == nil || w.offscreen || a11y_bus_state() != .Listening { return .Inactive }
	if w.a11y == nil {
		conn := dbus.connect_bus_address(session.a11y_address)
		if conn == nil {
			session.a11y = .Failed   // (asked once: a tree a frame would knock at it for nothing)
			return .Failed
		}
		b := new(A11y_Bridge)
		b.conn = conn
		dbus.export_object(b.conn, ATSPI_ROOT_PATH, atspi_object_handler, w)
		w.a11y = b
	}
	a11y_tree_merge(&(^A11y_Bridge)(w.a11y).update, u)
	return .Applied
}

// Tests: the name of the window's bridge on the accessibility bus ("": none).
a11y_bus_name :: proc(w: ^Window) -> string {
	if w.a11y == nil { return "" }
	return dbus.conn_name((^A11y_Bridge)(w.a11y).conn)
}

// The window's accessibility bus for its loop's poll set (-1: no bridge).
@(private)
a11y_fd :: proc(w: ^Window) -> i32 {
	if w.a11y == nil { return -1 }
	return dbus.conn_fd((^A11y_Bridge)(w.a11y).conn)
}

// Answers what an assistive technology asked since the last pump: nothing else reads the bridge's connection.
@(private)
a11y_pump :: proc(w: ^Window) {
	if w.a11y != nil { dbus.dispatch((^A11y_Bridge)(w.a11y).conn) }
}

a11y_take_request :: proc(w: ^Window) -> (r: A11y_Request, ok: bool) {
	if w == nil || w.a11y == nil { return }
	b := (^A11y_Bridge)(w.a11y)
	if len(b.requests) == 0 { return }
	r = b.requests[0]
	ordered_remove(&b.requests, 0)
	return r, true
}

////////////////////////////////
// serving the AT-SPI object requests (minimal)

@(private) ATSPI_ROOT_PATH :: "/org/a11y/atspi/accessible/root"

// The AT-SPI object handler: answers the handful of calls a screen reader makes on our accessibles. This is a thin
// bridge; the full AT-SPI surface (Collection, EditableText, selection ranges) is the richer path the report leaves to
// the AccessKit adapter.
@(private)
atspi_object_handler :: proc(user: rawptr, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	w := (^Window)(user)
	b := (^A11y_Bridge)(w.a11y)
	if b == nil { return false }
	switch msg.iface {
	case "org.a11y.atspi.Accessible":
		return atspi_accessible(b, c, msg)
	case "org.a11y.atspi.Action":
		return atspi_action(w, b, c, msg)
	case "org.freedesktop.DBus.Properties":
		return atspi_properties(b, c, msg)
	}
	return false
}

@(private)
atspi_accessible :: proc(b: ^A11y_Bridge, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	switch msg.member {
	case "GetRole":
		// map our root role to an AT-SPI role number; a full mapping is large, so give FRAME (window) for the root.
		w := dbus.body_writer()
		dbus.w_u32(&w, 76)   // ATSPI_ROLE_FRAME
		dbus.reply_return(c, msg, "u", w.buf[:])
		return true
	case "GetChildCount":
		w := dbus.body_writer()
		n := len(b.update.nodes) > 0 ? a11y_root_child_count(&b.update) : 0
		dbus.w_i32(&w, i32(n))
		dbus.reply_return(c, msg, "i", w.buf[:])
		return true
	}
	return false
}

@(private)
atspi_properties :: proc(b: ^A11y_Bridge, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	if msg.member != "Get" { return false }
	r := dbus.msg_reader(msg)
	_ = dbus.r_string(&r)       // interface
	name := dbus.r_string(&r)   // property
	w := dbus.body_writer()
	switch name {
	case "Name":
		dbus.arg_variant_string(&w, a11y_root_name(&b.update))
		dbus.reply_return(c, msg, "v", w.buf[:])
		return true
	case "Description":
		dbus.arg_variant_string(&w, "")
		dbus.reply_return(c, msg, "v", w.buf[:])
		return true
	}
	return false
}

// Action.DoAction(index) -> queue an Invoke / Focus request on the focused node.
@(private)
atspi_action :: proc(w: ^Window, b: ^A11y_Bridge, c: ^dbus.Conn, msg: ^dbus.Message) -> bool {
	if msg.member != "DoAction" { return false }
	r := dbus.msg_reader(msg)
	index := dbus.r_i32(&r)
	req := A11y_Request{action = index == 0 ? .Click : .Focus, target = b.update.focus, tree = b.update.tree}
	append(&b.requests, req)
	inject_event(w, Event{kind = .Accessibility})
	rw := dbus.body_writer()
	dbus.w_bool(&rw, true)
	dbus.reply_return(c, msg, "b", rw.buf[:])
	return true
}

// The number of children the root node names.
@(private)
a11y_root_child_count :: proc(u: ^A11y_Update) -> int {
	for n, i in u.nodes { if n.id == u.root { return len(a11y_node_children(u, i)) } }
	return 0
}

@(private)
a11y_root_name :: proc(u: ^A11y_Update) -> string {
	for n, i in u.nodes {
		if n.id == u.root {
			if s := a11y_node_string(u, i, .Label); s != "" { return s }
		}
	}
	return "gui_toolkit"
}

_ :: runtime
