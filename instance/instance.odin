// Package instance: one running copy of an application per named resource (a profile, a document set, a machine). The
// first process to start with a name owns it; a second start with the same name does not open a second copy on the same
// state: it hands an opaque message (what it was asked to open) to the first one, which comes to the front, and ends.
//
// The interface is platform-neutral: a name (letters, digits and dots, built with `key`), an optional identity (a token
// the owner checks so that only a copy it trusts hands over — an executable path, a version), an opaque message (`[]byte`:
// the package never looks inside it), and a handler the owner runs on the thread that pumps its messages. No window
// handle, no executable semantics and no Windows type cross the boundary.
//
// How (Windows, instance_windows.odin): a named mutex says who owns the name; the owner has a message-only window whose
// title is the name; a second start finds it, allows it to take the foreground, and sends a WM_COPYDATA with the envelope
// below. How (POSIX, instance_posix.odin): a lock file (flock) says who owns the name and a Unix socket in the user's
// runtime directory carries the envelope. The owner answers 1 (taken), 2 (another identity) or 0 (closing).
//
// What can go wrong, and what then: the owner has no window / socket yet (it is starting) or has just dropped it (it is
// closing): the second start tries again for a short while, and when the lock is gone it becomes the owner itself; the
// owner does not answer (a task keeps it busy, a hung process): after the timeout the second start carries on by itself,
// it never waits for ever and never loses its message.
//
// The package name is `tk_instance` (the directory is `instance`, imported as `toolkit:instance`): import it as `instance`
// unless the application keeps a package of its own by that name.
package tk_instance

import "core:path/filepath"
import "core:strings"

// What `acquire` came to.
Outcome :: enum u8 {
	First,            // this process owns the name (Owner is set): carry on, and call owner_start once a loop exists
	Forwarded,        // the owner took the message: this start is done (exit, or just stop)
	Other_Instance,   // the owner is a copy with a different identity: carry on by yourself, owning nothing
	Unresponsive,     // the owner did not answer in time: carry on by yourself, and say so
}

// What a second start hands over, and the trust token of the sender.
Config :: struct {
	name:     string,   // the unique key (letters, digits and dots): build one with `key`
	identity: string,   // the owner hands over only to a sender with this same identity; "" means any sender is trusted
	wait_ms:  int,      // how long to keep trying while the owner is starting or closing (a silent owner ends it at once)
}

// The owner's handler: called on the thread that created the window / socket, inside pump_messages, with a message valid
// only during the call (copy what is kept). It must be quick: the sender waits for it. `message` is the bytes the sender
// gave `acquire` / `send`, nothing added.
Handler :: #type proc(user: rawptr, message: []byte)

// A name from a prefix and a path: "<prefix>.<16 hex digits of a hash of the absolute path>". Two runs on the same path
// get the same name; another path, or another prefix (a channel: release and development never meet), gets another. On
// Windows the case and the slash direction of the path do not matter. Letters, digits and dots only: a name is used as a
// kernel object name and a window title.
key :: proc(prefix, path: string, allocator := context.temp_allocator) -> string {
	p := path
	if abs, err := filepath.abs(path, context.temp_allocator); err == nil { p = abs }
	p, _ = strings.replace_all(p, "\\", "/", context.temp_allocator)
	p = strings.trim_right(p, "/")
	when ODIN_OS == .Windows { p = strings.to_lower(p, context.temp_allocator) }
	h: u64 = 0xcbf29ce484222325   // FNV-1a
	for c in transmute([]u8)p { h = (h ~ u64(c)) * 0x100000001b3 }
	hex := "0123456789abcdef"
	digits: [16]u8
	for i in 0 ..< 16 { digits[15 - i] = hex[h & 0xf]; h >>= 4 }
	return strings.concatenate({prefix, ".", string(digits[:])}, allocator)
}

// The envelope on the wire: a u32 little-endian length of the identity, the identity bytes, then the message bytes. The
// message is carried as-is (any bytes), so the application's own codec is the only thing that reads it.
ENVELOPE_MAX :: 1 << 20   // a message larger than this is not one (both backends refuse it)

@(private)
encode :: proc(identity: string, message: []byte, allocator := context.temp_allocator) -> []byte {
	n := 4 + len(identity) + len(message)
	out := make([]byte, n, allocator)
	id_len := u32(len(identity))
	out[0] = u8(id_len); out[1] = u8(id_len >> 8); out[2] = u8(id_len >> 16); out[3] = u8(id_len >> 24)
	copy(out[4:], transmute([]byte)identity)
	copy(out[4 + len(identity):], message)
	return out
}

// The identity and the message those bytes carry (both point into `data`). ok = false for anything that is not an envelope.
@(private)
decode :: proc(data: []byte) -> (identity: string, message: []byte, ok: bool) {
	if len(data) < 4 { return "", nil, false }
	id_len := int(data[0]) | int(data[1]) << 8 | int(data[2]) << 16 | int(data[3]) << 24
	if id_len < 0 || 4 + id_len > len(data) { return "", nil, false }
	return string(data[4:4 + id_len]), data[4 + id_len:], true
}

// The same identity? An empty owner identity trusts any sender; otherwise an exact match is required. On Windows the case
// and the slash direction do not matter (identities are often file paths).
@(private)
same_identity :: proc(owner, sender: string) -> bool {
	if owner == "" { return true }
	when ODIN_OS == .Windows {
		x, _ := strings.replace_all(owner, "/", "\\", context.temp_allocator)
		y, _ := strings.replace_all(sender, "/", "\\", context.temp_allocator)
		return strings.equal_fold(x, y)
	} else {
		return owner == sender
	}
}
