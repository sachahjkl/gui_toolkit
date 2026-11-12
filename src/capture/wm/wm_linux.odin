#+build linux
package capture_wm

// The queries: a Unix socket to the compositor, a request, the whole reply. Each is bounded (IO_TIMEOUT_MS a read or a
// write): a compositor that does not answer makes the window list say nothing, it does not hold the caller.

import "core:strings"
import "core:sys/posix"

@(private = "file") IO_TIMEOUT_MS :: 2000
@(private = "file") READ_CHUNK_BYTES :: 16384
@(private = "file") SWAY_MAGIC :: "i3-ipc"
@(private = "file") SWAY_GET_TREE :: 4
@(private = "file") SWAY_HEADER_BYTES :: 14   // the magic, the length, the type
@(private = "file") SWAY_MAX_REPLY_BYTES :: 1 << 26

// The provider of this session, from the environment.
detect :: proc() -> Provider {
	if env("HYPRLAND_INSTANCE_SIGNATURE") != "" { return .Hyprland }
	if env("SWAYSOCK") != "" { return .Sway }
	return .None
}

// The windows the provider tells, front to back. ok is false when it does not answer.
windows :: proc(p: Provider, allocator := context.allocator) -> (list: []Window, ok: bool) {
	switch p {
	case .Hyprland: return hyprland_windows(allocator)
	case .Sway:     return sway_windows(allocator)
	case .None:
	}
	return nil, false
}

@(private = "file")
hyprland_windows :: proc(allocator := context.allocator) -> (list: []Window, ok: bool) {
	sig := env("HYPRLAND_INSTANCE_SIGNATURE")
	// (Hyprland 0.40 moved the socket from /tmp to the runtime directory)
	paths := [2]string{
		strings.concatenate({env("XDG_RUNTIME_DIR"), "/hypr/", sig, "/.socket.sock"}, context.temp_allocator),
		strings.concatenate({"/tmp/hypr/", sig, "/.socket.sock"}, context.temp_allocator),
	}
	for path in paths {
		clients, got := hyprland_ask(path, "j/clients")
		if !got { continue }
		defer delete(clients)
		monitors, got_monitors := hyprland_ask(path, "j/monitors")
		if !got_monitors { return nil, false }
		defer delete(monitors)
		return hyprland_parse(string(clients), string(monitors), allocator)
	}
	return nil, false
}

// One request on its own connection: Hyprland answers it and closes.
@(private = "file")
hyprland_ask :: proc(path, request: string) -> (reply: []u8, ok: bool) {
	fd := unix_connect(path)
	if fd < 0 { return nil, false }
	defer posix.close(fd)
	if !write_all(fd, transmute([]u8)request) { return nil, false }
	buf := make([dynamic]u8)
	chunk: [READ_CHUNK_BYTES]u8
	for {
		if !readable(fd) { delete(buf); return nil, false }
		n := posix.read(fd, &chunk[0], len(chunk))
		if n < 0 { delete(buf); return nil, false }
		if n == 0 { break }
		append(&buf, ..chunk[:n])
	}
	return buf[:], true
}

@(private = "file")
sway_windows :: proc(allocator := context.allocator) -> (list: []Window, ok: bool) {
	fd := unix_connect(env("SWAYSOCK"))
	if fd < 0 { return nil, false }
	defer posix.close(fd)
	header: [SWAY_HEADER_BYTES]u8
	copy(header[:], SWAY_MAGIC)
	put_u32(header[6:], 0)
	put_u32(header[10:], SWAY_GET_TREE)
	if !write_all(fd, header[:]) { return nil, false }
	if !read_exact(fd, header[:]) || string(header[:6]) != SWAY_MAGIC { return nil, false }
	size := int(get_u32(header[6:]))
	if size > SWAY_MAX_REPLY_BYTES { return nil, false }
	payload := make([]u8, size)
	defer delete(payload)
	if !read_exact(fd, payload) { return nil, false }
	return sway_parse(string(payload), allocator)
}

// (i3 IPC's integers are in the machine's order: little-endian on every machine this runs on)
@(private = "file")
put_u32 :: proc(b: []u8, v: u32) { b[0], b[1], b[2], b[3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
@(private = "file")
get_u32 :: proc(b: []u8) -> u32 { return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24 }

@(private = "file")
env :: proc(name: cstring) -> string {
	v := posix.getenv(name)
	return v == nil ? "" : string(v)
}

@(private = "file")
unix_connect :: proc(path: string) -> posix.FD {
	sa: posix.sockaddr_un
	if path == "" || len(path) >= len(sa.sun_path) { return -1 }
	sa.sun_family = .UNIX
	copy(sa.sun_path[:], transmute([]u8)path)
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 { return -1 }
	if posix.connect(fd, (^posix.sockaddr)(&sa), size_of(sa)) != .OK {
		posix.close(fd)
		return -1
	}
	return fd
}

@(private = "file")
readable :: proc(fd: posix.FD) -> bool {
	p := posix.pollfd{fd = fd, events = {.IN}}
	return posix.poll(&p, 1, IO_TIMEOUT_MS) > 0
}

@(private = "file")
write_all :: proc(fd: posix.FD, data: []u8) -> bool {
	rest := data
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), uint(len(rest)))
		if n <= 0 { return false }
		rest = rest[n:]
	}
	return true
}

@(private = "file")
read_exact :: proc(fd: posix.FD, into: []u8) -> bool {
	got := 0
	for got < len(into) {
		if !readable(fd) { return false }
		n := int(posix.read(fd, &into[got], uint(len(into)) - uint(got)))
		if n <= 0 { return false }
		got += n
	}
	return true
}
