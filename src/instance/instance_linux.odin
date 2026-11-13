package tk_instance

// Linux: a lock file and a Unix socket in the user's runtime directory ($XDG_RUNTIME_DIR/tk_instance, else
// /tmp/tk_instance-<uid>, mode 0700: only this user's processes reach them). See instance.odin for the whole picture.
//
//   <name>.lock   flock(LOCK_EX) says who owns the name; the kernel lets go when the process ends, crashed or not
//   <name>.sock   the owner listens there once owner_start has run (before that, and after owner_closing, there is
//                 nothing to connect to: the second start tries again, as on Windows when there is no window)
//
// A second start connects, writes the envelope (a u32 length, little-endian, then encode's bytes) and reads one byte: 1
// taken, 2 a different identity, 0 refused (closing). The owner reads its socket in pump_messages, on the thread that
// called owner_start, as the Windows owner gets its WM_COPYDATA in the message pump.

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// How long the owner waits for the bytes of a message once a start has connected (it writes them at once).
@(private = "file") READ_MS :: 1000
@(private = "file") LISTEN_BACKLOG :: 16

Owner :: struct {
	name:     string,        // owned
	identity: string,        // owned: the token a sender must match to hand over ("" trusts any sender)
	state:    Owner_State,
	handler:  Handler,
	user:     rawptr,
	lock:     linux.Fd,      // the flock'd file: Claimed, Serving, Closing
	listen:   linux.Fd,      // the socket: Serving
	sock:     string,        // owned: its path: Serving
	thread:   int,           // the thread whose pump_messages reads the socket: Serving
}

@(private)
Reply :: enum u8 { No_Window, Accepted, Other_Instance, Refused, Timeout }

// The owners started in this process (pump_messages serves those of the calling thread).
@(private = "file") owners_mu: sync.Mutex
@(private = "file") owners: [dynamic]^Owner

// "" when it is not this user's alone: /tmp is everyone's, and who made the directory first would get the messages.
@(private = "file")
runtime_dir :: proc() -> string {
	dir := ""
	if x := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); x != "" {
		dir = strings.concatenate({x, "/tk_instance"}, context.temp_allocator)
	} else {
		dir = fmt.tprintf("/tmp/tk_instance-%d", linux.getuid())
	}
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	linux.mkdir(cdir, {.IRUSR, .IWUSR, .IXUSR})
	return dir_is_ours(cdir) ? dir : ""
}

// A real directory, this user's, that no one else can reach.
@(private)
dir_is_ours :: proc(dir: cstring) -> bool {
	st: linux.Stat
	if linux.lstat(dir, &st) != .NONE || !linux.S_ISDIR(st.mode) || st.uid != linux.getuid() { return false }
	return st.mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} == {}
}

// "" with no runtime directory: nothing to open or to connect to, the start carries on by itself.
@(private)
path_of :: proc(name, ext: string) -> string {
	dir := runtime_dir()
	return dir == "" ? "" : strings.concatenate({dir, "/", name, ext}, context.temp_allocator)
}

@(private)
address_of :: proc(path: string) -> (addr: linux.Sock_Addr_Un, ok: bool) {
	if path == "" || len(path) >= len(addr.sun_path) { return {}, false }
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	return addr, true
}

// One attempt to hand `message` (under `identity`) to the owner of `name`, all of it within timeout_ms: the socket does not
// block, whether the owner's backlog is full or the message is more than the socket holds. The socket closes on the way
// out, whatever happened: that is how an owner that wakes later learns that this sender went on alone (serve).
@(private)
forward_once :: proc(name, identity: string, message: []byte, timeout_ms: int) -> Reply {
	addr, ok := address_of(path_of(name, ".sock"))
	if !ok { return .No_Window }
	s, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if err != .NONE { return .No_Window }
	defer linux.close(s)
	if linux.connect(s, &addr) != .NONE { return .No_Window }   // nobody listens (starting, closing), no file, or a full backlog
	deadline := time.tick_add(time.tick_now(), time.Duration(max(timeout_ms, 1)) * time.Millisecond)
	data := encode(identity, message)
	head: [LENGTH_PREFIX_BYTES]u8
	endian.put_u32(head[:], .Little, u32(len(data)))
	if r := send_all(s, head[:], deadline); r != .Accepted { return r }
	if r := send_all(s, data, deadline); r != .Accepted { return r }
	if !wait_for(s, {.IN}, deadline) { return .Timeout }
	answer: [1]u8
	got, rerr := linux.recv(s, answer[:], {})
	if rerr != .NONE || got != 1 { return .No_Window }   // closed without answering: it is going away
	switch answer[0] {
	case 1: return .Accepted
	case 2: return .Other_Instance
	}
	return .Refused
}

// Until `s` can do what `events` says; false at the deadline.
@(private = "file")
wait_for :: proc(s: linux.Fd, events: linux.Fd_Poll_Events, deadline: time.Tick) -> bool {
	for {
		left := time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline))
		if left <= 0 { return false }
		fds := []linux.Poll_Fd{{fd = s, events = events}}
		n, err := linux.poll(fds, i32(left) + 1)
		if err == .EINTR { continue }
		return err == .NONE && n > 0
	}
}

// All of `data` on the non-blocking socket: Accepted when it went, Timeout at the deadline, No_Window when the peer closed.
@(private = "file")
send_all :: proc(s: linux.Fd, data: []u8, deadline: time.Tick) -> Reply {
	at := 0
	for at < len(data) {
		n, err := linux.send(s, data[at:], {.NOSIGNAL})
		if err == .EINTR { continue }
		if err == .EAGAIN {
			if !wait_for(s, {.OUT}, deadline) { return .Timeout }
			continue
		}
		if err != .NONE || n <= 0 { return .No_Window }
		at += n
	}
	return .Accepted
}

// Hands `message` to the owner of `o.name` without trying to become the owner: a pure "ping the running copy".
send :: proc(o: Instance_Options, message: []byte) -> Outcome {
	switch forward_once(o.name, o.identity, message, max(o.wait_ms, FORWARD_MIN_MS)) {
	case .Accepted:        return .Forwarded
	case .Other_Instance:  return .Other_Instance
	case .No_Window, .Refused, .Timeout: return .Unresponsive
	}
	return .Unresponsive
}

// Takes the name of `o.name` or hands `message` to the copy that has it. Tries for up to `o.wait_ms` while the owner is
// starting or closing; a silent owner ends the wait at once (it is busy or hung: not worth waiting for).
acquire :: proc(o: Instance_Options, message: []byte) -> (Outcome, Owner) {
	deadline := time.tick_add(time.tick_now(), time.Duration(o.wait_ms) * time.Millisecond)
	lock_path := strings.clone_to_cstring(path_of(o.name, ".lock"), context.temp_allocator)
	for {
		fd, err := linux.open(lock_path, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
		if err != .NONE { return .Unresponsive, {} }   // (no runtime directory: carry on as if it was not asked)
		if linux.flock(fd, {.EX, .NB}) == .NONE {
			return .First, Owner{name = strings.clone(o.name), identity = strings.clone(o.identity), state = .Claimed, lock = fd}
		}
		linux.close(fd)
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		switch forward_once(o.name, o.identity, message, max(left, FORWARD_MIN_MS)) {
		case .Accepted:        return .Forwarded, {}
		case .Other_Instance:  return .Other_Instance, {}
		case .Timeout:         return .Unresponsive, {}
		case .No_Window, .Refused:
		}
		if left <= 0 { return .Unresponsive, {} }
		time.sleep(ACQUIRE_RETRY_MS * time.Millisecond)
	}
}

// Opens the owner's socket (served by pump_messages on this thread) and sets the handler that takes the messages. False,
// with nothing changed, when it failed or the Owner is not Claimed: an Owner starts once.
owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool {
	if o.state != .Claimed { return false }
	path := path_of(o.name, ".sock")
	addr, ok := address_of(path)
	if !ok { return false }
	s, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if err != .NONE { return false }
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)   // a socket left by an owner that crashed: the lock says it is ours now
	if linux.bind(s, &addr) != .NONE || linux.listen(s, LISTEN_BACKLOG) != .NONE { linux.close(s); return false }
	o.listen, o.sock, o.thread = s, strings.clone(path), sync.current_thread_id()
	o.handler, o.user, o.state = handler, user, .Serving
	sync.mutex_lock(&owners_mu)
	append(&owners, o)
	sync.mutex_unlock(&owners_mu)
	return true
}

// Is it an elevated process? (Root: it takes messages from the user's own processes only anyway, the socket is 0700.)
is_elevated :: proc() -> bool { return linux.geteuid() == 0 }

// The owner is ending: later messages are refused and the socket goes. The name is still its own (the lock is held):
// a start that comes now waits, and takes the name once owner_stop has released it.
owner_closing :: proc(o: ^Owner) {
	if o.state == .Serving {
		sync.mutex_lock(&owners_mu)
		for x, i in owners { if x == o { unordered_remove(&owners, i); break } }
		if len(owners) == 0 { delete(owners); owners = nil }
		sync.mutex_unlock(&owners_mu)
		linux.close(o.listen)
		linux.unlink(strings.clone_to_cstring(o.sock, context.temp_allocator))
		delete(o.sock)
		o.sock = ""
	}
	if o.state != .None { o.state = .Closing }
}

// The owner is done with the name: the lock is released (a start that was waiting becomes the owner).
owner_stop :: proc(o: ^Owner) {
	if o.state == .None { return }
	owner_closing(o)
	linux.close(o.lock)
	delete(o.name); delete(o.identity)
	o^ = {}
}

// Raising a window is the shell's job (the window system: xdg-activation on Wayland, _NET_ACTIVE_WINDOW on X11): nothing
// to do here. An application calls its toolkit window layer from its handler instead.
raise_window :: proc(handle: rawptr) {}

// Serves the sockets of the owners started on this thread: every waiting start gets its answer.
pump_messages :: proc() {
	me := sync.current_thread_id()
	sync.mutex_lock(&owners_mu)
	mine := make([dynamic]^Owner, context.temp_allocator)
	for o in owners { if o.thread == me { append(&mine, o) } }
	sync.mutex_unlock(&owners_mu)
	for o in mine {
		for {
			c, err := linux.accept(o.listen, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC})
			if err != .NONE { break }   // EAGAIN: nobody waits
			answer := [1]u8{serve(o, c)}
			linux.send(c, answer[:], {.NOSIGNAL})   // (one byte on an empty socket; a sender gone is no matter)
			linux.close(c)
		}
	}
}

// Reads one message from `c` and hands it to the handler: the byte to answer. A sender that hung up has timed out and gone on
// alone: what it wrote is still there to read, and is not handled.
@(private = "file")
serve :: proc(o: ^Owner, c: linux.Fd) -> u8 {
	if o.handler == nil { return 0 }
	head: [LENGTH_PREFIX_BYTES]u8
	if !read_full(c, head[:]) { return 0 }
	n := int(endian.unchecked_get_u32le(head[:]))
	if n == 0 || n > ENVELOPE_MAX { return 0 }
	data := make([]u8, n, context.temp_allocator)
	if !read_full(c, data) { return 0 }
	identity, message, ok := decode(data)
	if !ok { return 0 }
	if !same_identity(o.identity, identity) { return 2 }
	if hung_up(c) { return 0 }
	o.handler(o.user, message)
	return 1
}

@(private = "file")
hung_up :: proc(c: linux.Fd) -> bool {
	fds := []linux.Poll_Fd{{fd = c, events = {.RDHUP}}}
	n, _ := linux.poll(fds, 0)
	return n > 0 && fds[0].revents & {.HUP, .RDHUP} != {}
}

@(private = "file")
read_full :: proc(c: linux.Fd, buf: []u8) -> bool {
	at := 0
	deadline := time.tick_add(time.tick_now(), READ_MS * time.Millisecond)
	for at < len(buf) {
		left := time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline))
		if left <= 0 { return false }
		fds := []linux.Poll_Fd{{fd = c, events = {.IN}}}
		if r, _ := linux.poll(fds, i32(left) + 1); r <= 0 { return false }
		got, err := linux.recv(c, buf[at:], {})
		if err == .EINTR || err == .EAGAIN { continue }
		if err != .NONE || got <= 0 { return false }
		at += got
	}
	return true
}
