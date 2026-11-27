#+private
package tk_rpc

// The last bytes of the child's standard error: a ring that keeps `cap` bytes and drops the oldest. The errors thread
// writes it; any thread copies it out (under the peer's lock).

Tail :: struct {
	buf:   []u8,
	start: int,   // the oldest byte
	len:   int,
}

tail_make :: proc(capacity: int, allocator := context.allocator) -> Tail {
	return Tail{buf = make([]u8, max(capacity, 1), allocator)}
}

tail_destroy :: proc(t: ^Tail, allocator := context.allocator) {
	delete(t.buf, allocator)
	t^ = {}
}

tail_write :: proc(t: ^Tail, data: []u8) {
	d := data
	n := len(t.buf)
	// (only the last n bytes of a long write can stay)
	if len(d) >= n {
		copy(t.buf, d[len(d) - n:])
		t.start, t.len = 0, n
		return
	}
	end := (t.start + t.len) % n
	first := copy(t.buf[end:], d)
	copy(t.buf, d[first:])
	t.len += len(d)
	if t.len > n {
		t.start = (t.start + t.len - n) % n
		t.len = n
	}
}

// The bytes kept, oldest first, in `allocator`.
tail_text :: proc(t: ^Tail, allocator := context.allocator) -> string {
	out := make([]u8, t.len, allocator)
	n := len(t.buf)
	first := copy(out, t.buf[t.start:min(t.start + t.len, n)])
	copy(out[first:], t.buf[:t.len - first])
	return string(out)
}
