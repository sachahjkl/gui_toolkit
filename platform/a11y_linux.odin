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
// When the a11y bus is unreachable (no assistive technology running, the common case) a11y_state stays Off and nothing
// is built, exactly as the Windows adapter does.

import "base:runtime"
import "core:strings"
import "toolkit:dbus"

@(private) ATSPI_BUS_NAME :: "org.a11y.Bus"
@(private) ATSPI_BUS_PATH :: "/org/a11y/bus"

// The window's accessibility bridge: a connection to the a11y bus and the last tree the toolkit sent.
@(private)
A11y_Bridge :: struct {
	conn:     ^dbus.Conn,
	update:   A11y_Update,     // the latest tree, owned here (copied from the toolkit's)
	have:     bool,
	active:   bool,            // an assistive technology connected
	requests: [dynamic]A11y_Request,
}

// Whether this build can read its windows to assistive technologies. True on Linux when the a11y bus answers.
a11y_available :: proc() -> bool { return a11y_bus_address() != "" }

@(private) a11y_addr_cached: string
@(private) a11y_addr_tried: bool

// Asks the session bus for the a11y bus address (org.a11y.Bus.GetAddress). "" when there is no a11y bus.
@(private)
a11y_bus_address :: proc() -> string {
	if a11y_addr_tried { return a11y_addr_cached }
	a11y_addr_tried = true
	conn := session_bus()
	if conn == nil { return "" }
	msg, ok := dbus.call(conn, ATSPI_BUS_NAME, ATSPI_BUS_PATH, ATSPI_BUS_NAME, "GetAddress", "", nil, 3000)
	if !ok { return "" }
	r := dbus.msg_reader(&msg)
	addr := dbus.r_string(&r)
	a11y_addr_cached = strings.clone(addr)
	return a11y_addr_cached
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

// What the adapter needs now. Without an a11y bus, Off (the toolkit skips the tree). With one, Full when the bridge is
// new (send the whole tree), Incremental after.
a11y_state :: proc(w: ^Window) -> A11y_State {
	if w == nil || w.offscreen { return .Off }
	if a11y_bus_address() == "" { return .Off }
	if w.a11y == nil { return .Full }
	b := (^A11y_Bridge)(w.a11y)
	return b.have ? .Incremental : .Full
}

// Hands an update to the bridge, making the bridge on the first call. We keep a copy of the whole tree (the a11y bus is
// pull-based: a client asks for a node's properties, so we must be able to answer from the last tree at any time).
a11y_send :: proc(w: ^Window, u: ^A11y_Update, toolkit_name := "gui_toolkit", toolkit_version := "") -> A11y_Send {
	if w == nil || w.offscreen { return .Inactive }
	if a11y_bus_address() == "" { return .Inactive }
	if w.a11y == nil {
		b := new(A11y_Bridge)
		b.conn = dbus.connect_bus_address(a11y_bus_address())
		if b.conn == nil { free(b); return .Inactive }
		dbus.export_object(b.conn, ATSPI_ROOT_PATH, atspi_object_handler, w)
		w.a11y = b
	}
	b := (^A11y_Bridge)(w.a11y)
	a11y_copy_update(&b.update, u)
	b.have = true
	return .Applied
}

a11y_take_request :: proc(w: ^Window) -> (r: A11y_Request, ok: bool) {
	if w == nil || w.a11y == nil { return }
	b := (^A11y_Bridge)(w.a11y)
	if len(b.requests) == 0 { return }
	r = b.requests[0]
	ordered_remove(&b.requests, 0)
	return r, true
}

// A deep copy of the toolkit's update into the bridge's own buffers (the toolkit reuses its arrays each frame).
@(private)
a11y_copy_update :: proc(dst: ^A11y_Update, src: ^A11y_Update) {
	a11y_update_clear(dst)
	append(&dst.nodes, ..src.nodes[:])
	append(&dst.ids, ..src.ids[:])
	append(&dst.props, ..src.props[:])
	append(&dst.bytes, ..src.bytes[:])
	append(&dst.floats, ..src.floats[:])
	dst.root, dst.focus, dst.tree, dst.tree_info = src.root, src.focus, src.tree, src.tree_info
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
