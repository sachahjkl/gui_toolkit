#+build linux
package dbus

// The connection: the Unix-socket transport, the SASL EXTERNAL authentication, the Hello handshake, and the send /
// receive / dispatch loop. Linux only (every D-Bus desktop is); a non-Linux build gets the stub (conn_stub.odin),
// which reports the bus unreachable.
//
// The socket is non-blocking once authenticated, so dispatch() never blocks the UI thread: it reads whatever arrived,
// parses out whole messages and routes them (replies to waiters / async handlers, signals to subscribers). conn_fd
// gives the socket to the window loop's poll(2). A synchronous call writes the message then pumps the socket (with a
// bounded poll) until its reply's serial comes back.

import "core:mem/virtual"
import "core:strings"
import "core:sys/posix"

foreign import libc "system:c"
@(default_calling_convention = "c", private)
foreign libc {
	socket  :: proc(domain, type, protocol: i32) -> i32 ---
	connect :: proc(fd: i32, addr: rawptr, len: u32) -> i32 ---
	send    :: proc(fd: i32, buf: rawptr, len: uint, flags: i32) -> int ---
	recv    :: proc(fd: i32, buf: rawptr, len: uint, flags: i32) -> int ---
	fcntl   :: proc(fd: i32, cmd: i32, #c_vararg args: ..any) -> i32 ---
	getuid  :: proc() -> u32 ---
	close   :: proc(fd: i32) -> i32 ---
	@(link_name="poll") poll_c :: proc(fds: rawptr, nfds: uint, timeout: i32) -> i32 ---
}

@(private) AF_UNIX :: 1
@(private) SOCK_STREAM :: 1
@(private) F_GETFL :: 3
@(private) F_SETFL :: 4
@(private) O_NONBLOCK :: 0o4000
@(private) MSG_NOSIGNAL :: 0x4000
@(private) POLLIN_C :: i16(0x0001)

@(private)
Sockaddr_Un :: struct {
	family: u16,
	path:   [108]u8,
}

@(private)
Pollfd_C :: struct { fd: i32, events: i16, revents: i16 }

// Opens a connection to the bus, authenticates and does Hello. Returns nil when there is no bus or the handshake
// failed; the caller treats that as "the desktop service is unavailable" and falls back.
connect_bus :: proc(bus: Bus_Kind, allocator := context.allocator) -> ^Conn {
	addr := bus_address(bus)
	if addr == "" { return nil }
	return connect_bus_address(addr, allocator)
}

// Opens a connection to a bus named by its D-Bus address string (the AT-SPI bus, say, whose address comes from
// org.a11y.Bus.GetAddress). Same handshake as connect_bus.
connect_bus_address :: proc(addr: string, allocator := context.allocator) -> ^Conn {
	path := unix_path_of(addr)
	if path == "" { return nil }
	fd := socket(AF_UNIX, SOCK_STREAM, 0)
	if fd < 0 { return nil }
	sa: Sockaddr_Un
	sa.family = AF_UNIX
	is_abstract := len(path) > 0 && path[0] == '@'
	// an abstract socket name starts with a NUL byte in the address (Linux); "@" in the address stands for it
	if is_abstract {
		sa.path[0] = 0
		copy(sa.path[1:], path[1:])
		addrlen := u32(size_of(u16) + 1 + len(path) - 1)
		if connect(fd, &sa, addrlen) < 0 { close(fd); return nil }
	} else {
		n := min(len(path), len(sa.path) - 1)
		copy(sa.path[:], path[:n])
		addrlen := u32(size_of(u16) + n + 1)
		if connect(fd, &sa, addrlen) < 0 { close(fd); return nil }
	}
	c := new(Conn, allocator)
	c.fd = fd
	c.serial = 1
	c.in_buf = make([dynamic]u8, allocator)
	c.subs = make([dynamic]Subscription, allocator)
	c.pending = make([dynamic]Pending, allocator)
	_ = virtual.arena_init_growing(&c.msg_arena)
	if !auth_external(c) { conn_close(c); return nil }
	// now non-blocking for the dispatch loop
	set_nonblocking(fd)
	c.connected = true
	if !hello(c) { conn_close(c); return nil }
	return c
}

// The socket's fd for a program's own poll(2). -1 when not connected. Readable means "call dispatch".
conn_fd :: proc(c: ^Conn) -> i32 { return c == nil ? -1 : c.fd }

conn_name :: proc(c: ^Conn) -> string { return c == nil ? "" : c.unique_name }

conn_alive :: proc(c: ^Conn) -> bool { return c != nil && c.connected && !c.disconnected }

conn_close :: proc(c: ^Conn) {
	if c == nil { return }
	if c.fd >= 0 { close(c.fd); c.fd = -1 }
	for s in c.subs { delete(s.rule); delete(s.iface); delete(s.member); delete(s.path) }
	delete(c.subs)
	if c.exports != nil { for e in c.exports { delete(e.path) }; delete(c.exports^); free(c.exports) }
	delete(c.pending)
	delete(c.in_buf)
	delete(c.unique_name)
	virtual.arena_destroy(&c.msg_arena)
	free(c)
}

////////////////////////////////
// addresses

@(private)
bus_address :: proc(bus: Bus_Kind) -> string {
	switch bus {
	case .Session:
		if a := posix.getenv("DBUS_SESSION_BUS_ADDRESS"); a != nil && string(a) != "" { return string(a) }
		// the well-known per-user path
		if rt := posix.getenv("XDG_RUNTIME_DIR"); rt != nil && string(rt) != "" {
			return strings.concatenate({"unix:path=", string(rt), "/bus"}, context.temp_allocator)
		}
	case .System:
		if a := posix.getenv("DBUS_SYSTEM_BUS_ADDRESS"); a != nil && string(a) != "" { return string(a) }
		return "unix:path=/var/run/dbus/system_bus_socket"
	}
	return ""
}

// The Unix socket path out of a D-Bus address ("unix:path=/run/..." or "unix:abstract=..."; the first of a list). An
// abstract name comes back with a leading '@'.
@(private)
unix_path_of :: proc(addr: string) -> string {
	rest := addr
	for entry in strings.split_iterator(&rest, ";") {
		if !strings.has_prefix(entry, "unix:") { continue }
		fields := entry[len("unix:"):]
		kv := fields
		for pair in strings.split_iterator(&kv, ",") {
			if strings.has_prefix(pair, "path=") { return pair[len("path="):] }
			if strings.has_prefix(pair, "abstract=") {
				return strings.concatenate({"@", pair[len("abstract="):]}, context.temp_allocator)
			}
		}
	}
	return ""
}

////////////////////////////////
// authentication (SASL EXTERNAL)

// The SASL exchange: a leading NUL byte, then "AUTH EXTERNAL <hex uid>", "BEGIN". We read line by line (blocking, the
// socket is still blocking here). The server answers "OK <guid>" on success.
@(private)
auth_external :: proc(c: ^Conn) -> bool {
	// the mandatory leading NUL (the "credentials" byte)
	zero := [1]u8{0}
	if send(c.fd, &zero[0], 1, MSG_NOSIGNAL) != 1 { return false }
	uid := getuid()
	hex := uid_hex(uid, context.temp_allocator)
	line := strings.concatenate({"AUTH EXTERNAL ", hex, "\r\n"}, context.temp_allocator)
	if !send_all(c.fd, transmute([]u8)line) { return false }
	resp := read_line(c.fd)
	if !strings.has_prefix(resp, "OK ") { return false }
	// NEGOTIATE_UNIX_FD would go here if we needed to pass fds; the tray and notifications send icon bytes inline, so
	// we skip it (BEGIN straight away).
	begin := "BEGIN\r\n"
	if !send_all(c.fd, transmute([]u8)begin) { return false }
	return true
}

// The uid as lowercase ASCII-hex of its decimal string (D-Bus EXTERNAL wants the hex of the uid's *text*).
@(private)
uid_hex :: proc(uid: u32, allocator := context.allocator) -> string {
	dec := u32_to_string(uid, context.temp_allocator)
	b := strings.builder_make(allocator)
	for ch in transmute([]u8)dec {
		strings.write_byte(&b, hex_digit(ch >> 4))
		strings.write_byte(&b, hex_digit(ch & 0xf))
	}
	return strings.to_string(b)
}

@(private)
hex_digit :: proc(v: u8) -> u8 { return v < 10 ? '0' + v : 'a' + (v - 10) }

@(private)
u32_to_string :: proc(v: u32, allocator := context.allocator) -> string {
	if v == 0 { return strings.clone("0", allocator) }
	buf: [10]u8
	i := len(buf)
	x := v
	for x > 0 { i -= 1; buf[i] = '0' + u8(x % 10); x /= 10 }
	return strings.clone(string(buf[i:]), allocator)
}

// Reads one CRLF line (blocking) during the auth handshake. Bounded to a small buffer: the server's lines are short.
@(private)
read_line :: proc(fd: i32) -> string {
	@(static) buf: [512]u8
	n := 0
	for n < len(buf) - 1 {
		one: [1]u8
		r := recv(fd, &one[0], 1, 0)
		if r <= 0 { break }
		buf[n] = one[0]; n += 1
		if n >= 2 && buf[n - 2] == '\r' && buf[n - 1] == '\n' { return string(buf[:n - 2]) }
	}
	return string(buf[:n])
}

@(private)
send_all :: proc(fd: i32, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n := send(fd, &data[off], uint(len(data)) - uint(off), MSG_NOSIGNAL)
		if n <= 0 { return false }
		off += int(n)
	}
	return true
}

@(private)
set_nonblocking :: proc(fd: i32) {
	fl := fcntl(fd, F_GETFL)
	if fl >= 0 { fcntl(fd, F_SETFL, fl | O_NONBLOCK) }
}

////////////////////////////////
// Hello

@(private)
hello :: proc(c: ^Conn) -> bool {
	msg, ok := call(c, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", nil, 5000)
	if !ok || msg.type != .Method_Return { return false }
	r := msg_reader(&msg)
	name := r_string(&r)
	c.unique_name = strings.clone(name)
	return c.unique_name != ""
}
