package tk_instance

// A second start's launch (src/md/features/second-start.md): the launcher's activation token and the words the program
// reads (paths, or a command's words). The bytes: LAUNCH_MARK; the token as a u32 little-endian length and its bytes; the
// count of words as a u32; each word as a length and its bytes. Lengths, not a separator: a word may hold any byte, a
// newline or a NUL included. The count: a message cut between two words is refused, not read as fewer words.

// The first byte of a launch. MESSAGE_PING and MESSAGE_QUIT start with 0x02: neither is a launch.
LAUNCH_MARK :: 0x01

Launch :: struct {
	token: string,     // the launcher's activation token ("": none; platform.activation_token_from_env)
	args:  []string,   // the program's words: absolute paths, or a command and its arguments
}

// The message of `l`, for acquire or send.
launch_encode :: proc(l: Launch, allocator := context.temp_allocator) -> []byte {
	n := 1 + 2 * LENGTH_PREFIX_BYTES + len(l.token)
	for a in l.args { n += LENGTH_PREFIX_BYTES + len(a) }
	out := make([]byte, n, allocator)
	out[0] = LAUNCH_MARK
	at := field_put(out, 1, l.token)
	at = u32_put(out, at, len(l.args))
	for a in l.args { at = field_put(out, at, a) }
	return out
}

// The launch a message carries; its strings point into `message`, the list is in `allocator`. ok = false: no launch
// (a PING, a QUIT, another program's bytes, a message cut short or with bytes after its last word).
launch_decode :: proc(message: []byte, allocator := context.temp_allocator) -> (l: Launch, ok: bool) {
	if len(message) == 0 || message[0] != LAUNCH_MARK { return }
	token, at := field_get(message, 1) or_return
	count: int
	count, at = u32_get(message, at) or_return
	// (each word takes its length's bytes at least: a count larger than that is no launch, and allocates nothing)
	if count > (len(message) - at) / LENGTH_PREFIX_BYTES { return }
	args := make([]string, count, allocator)
	for i in 0 ..< count {
		w, next, got := field_get(message, at)
		if !got { delete(args, allocator); return }
		args[i], at = w, next
	}
	if at != len(message) { delete(args, allocator); return }
	return {token = token, args = args}, true
}

@(private = "file")
u32_put :: proc(out: []byte, at: int, n: int) -> int {
	v := u32(n)
	out[at] = u8(v); out[at + 1] = u8(v >> 8); out[at + 2] = u8(v >> 16); out[at + 3] = u8(v >> 24)
	return at + LENGTH_PREFIX_BYTES
}

@(private = "file")
u32_get :: proc(data: []byte, at: int) -> (n: int, next: int, ok: bool) {
	if len(data) - at < LENGTH_PREFIX_BYTES { return }
	n = int(data[at]) | int(data[at + 1]) << 8 | int(data[at + 2]) << 16 | int(data[at + 3]) << 24
	return n, at + LENGTH_PREFIX_BYTES, true
}

@(private = "file")
field_put :: proc(out: []byte, at: int, s: string) -> int {
	start := u32_put(out, at, len(s))
	copy(out[start:], s)
	return start + len(s)
}

@(private = "file")
field_get :: proc(data: []byte, at: int) -> (s: string, next: int, ok: bool) {
	n, start := u32_get(data, at) or_return
	if n > len(data) - start { return }
	return string(data[start:start + n]), start + n, true
}
