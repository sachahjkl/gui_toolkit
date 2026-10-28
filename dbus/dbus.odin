// Package dbus: a small D-Bus client written in Odin, for the toolkit's Linux desktop services (the tray icon through
// StatusNotifierItem, notifications, the file-chooser portal, the appearance portal, AT-SPI accessibility). It speaks
// the wire protocol itself over the bus's Unix socket — no libdbus link — so a binary built for Linux starts on a
// machine without the library and simply reports the bus unreachable.
//
// What it does:
//   * connects to the session or the system bus (the address from DBUS_SESSION_BUS_ADDRESS / DBUS_SYSTEM_BUS_ADDRESS,
//     or the well-known /run paths), authenticates with SASL EXTERNAL (the uid as hex), and does the Hello handshake to
//     learn its unique name;
//   * marshals and unmarshals the type system (basic types, strings, object paths, signatures, arrays, structs, dicts,
//     variants) with the alignment and byte order the spec requires (marshal.odin, pure and testable);
//   * calls methods, synchronously (call, bounded wait) or asynchronously (call_async + a reply callback), and emits no
//     reply when none is wanted;
//   * subscribes to signals (match rules through the bus's AddMatch) and dispatches them to handlers;
//   * exposes its socket fd (conn_fd) so a program's own poll(2) loop waits on the bus alongside its window, and
//     dispatch() drains whatever arrived without blocking. This is how platform_linux.odin folds the bus into the
//     window loop.
//
// The connection is not thread-safe: drive it from one thread (the UI thread, as the window is). A worker that must
// call a method uses its own short-lived connection, or posts the call back to the UI thread.
//
// See docs/dbus.md.
package dbus

import "base:runtime"
import "core:mem/virtual"
import "core:sync"

// A well-known bus.
Bus_Kind :: enum u8 { Session, System }

// The outcome of a blocking call.
Call_Status :: enum u8 {
	Ok,          // a METHOD_RETURN came back (its body is in the reply)
	Error,       // an ERROR came back (its name and message are in the reply)
	Timeout,     // no reply within the deadline
	Disconnected, // the connection was lost
	Unsupported, // the connection was never established (no bus)
}

// A handler for a signal the connection subscribed to (subscribe). `msg` is valid only during the call; copy what you
// keep. Runs on the thread that calls dispatch / call (the UI thread).
Signal_Handler :: #type proc(user: rawptr, msg: ^Message)

// A handler for an asynchronous method reply (call_async). `msg` is the METHOD_RETURN or ERROR; nil on timeout or
// disconnect (check `status`). Valid only during the call.
Reply_Handler :: #type proc(user: rawptr, status: Call_Status, msg: ^Message)

// A registered signal subscription.
@(private)
Subscription :: struct {
	rule:    string,          // the match rule sent to the bus (for RemoveMatch)
	iface:   string,          // the interface and member matched (fast pre-filter before the rule's finer parts)
	member:  string,
	path:    string,          // "" matches any path
	handler: Signal_Handler,
	user:    rawptr,
	id:      u32,
}

// A pending asynchronous call waiting for its reply (by serial).
@(private)
Pending :: struct {
	serial:   u32,
	handler:  Reply_Handler,
	user:     rawptr,
	deadline: i64,            // monotonic ns; 0 = no deadline
}

// A connection to a bus. Opaque to callers; its fd is given out through conn_fd.
Conn :: struct {
	bus:         Bus_Kind,
	fd:          i32,         // the Unix socket, -1 when not connected
	unique_name: string,      // this connection's name on the bus (":1.42"), learned from Hello
	serial:      u32,         // the next outgoing serial
	// an incoming-byte buffer: whole messages are parsed out of it, a partial message stays until the rest arrives
	in_buf:      [dynamic]u8,
	// matching outgoing serials to callers waiting synchronously: the parsed reply is dropped here
	wait_serial: u32,
	wait_reply:  ^Message,
	wait_status: Call_Status,
	subs:        [dynamic]Subscription,
	next_sub_id: u32,
	pending:     [dynamic]Pending,
	// a scratch allocator for parsing one message (reset between messages), so a signal handler's reads do not leak
	msg_arena:   virtual.Arena,
	exports:     ^[dynamic]Exported,   // objects we serve (export_object), nil until the first
	connected:   bool,
	mutex:       sync.Mutex,  // guards send() so call_async from a worker that shares the conn is at least atomic on the wire
	disconnected: bool,
}

// The connection's per-message scratch allocator (reset before each message is parsed).
@(private)
mem_arena_allocator :: proc(c: ^Conn) -> runtime.Allocator { return virtual.arena_allocator(&c.msg_arena) }
