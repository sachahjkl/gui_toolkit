#+build !linux
package dbus

// D-Bus on the systems that are not Linux (Windows, macOS): there is no bus, so connect_bus returns nil and every
// call answers "unsupported". This keeps the package self-consistent when checked on any platform; the toolkit only
// uses it from its Linux backend. The type system (marshal.odin, message.odin, args.odin) stays available and testable
// everywhere.

// The exported-object record the connection keeps (Linux fills it; the type exists here so Conn is defined cross-platform).
@(private)
Exported :: struct {
	path:    string,
	handler: Object_Handler,
	user:    rawptr,
}

Object_Handler :: #type proc(user: rawptr, c: ^Conn, msg: ^Message) -> bool

connect_bus :: proc(bus: Bus_Kind, allocator := context.allocator) -> ^Conn { return nil }
connect_bus_address :: proc(addr: string, allocator := context.allocator) -> ^Conn { return nil }
conn_fd    :: proc(c: ^Conn) -> i32 { return -1 }
conn_name  :: proc(c: ^Conn) -> string { return "" }
conn_alive :: proc(c: ^Conn) -> bool { return false }
conn_close :: proc(c: ^Conn) {}
dispatch   :: proc(c: ^Conn) {}

call :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8, timeout_ms := 25000) -> (msg: Message, ok: bool) { return {}, false }
call_async :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8, handler: Reply_Handler, user: rawptr, deadline_ms := 25000) -> bool { return false }
call_noreply :: proc(c: ^Conn, destination, path, iface, member, signature: string, body: []u8) -> bool { return false }
emit_signal :: proc(c: ^Conn, path, iface, member, signature: string, body: []u8) -> bool { return false }
reply_return :: proc(c: ^Conn, to: ^Message, signature: string, body: []u8) -> bool { return false }
reply_error :: proc(c: ^Conn, to: ^Message, error_name, message: string) -> bool { return false }
subscribe :: proc(c: ^Conn, sender, path, iface, member: string, handler: Signal_Handler, user: rawptr) -> u32 { return 0 }
unsubscribe :: proc(c: ^Conn, id: u32) {}
export_object :: proc(c: ^Conn, path: string, handler: Object_Handler, user: rawptr) {}
export_remove :: proc(c: ^Conn, path: string) {}
request_name :: proc(c: ^Conn, name: string, flags: u32 = 0) -> bool { return false }
