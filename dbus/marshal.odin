package dbus

// The D-Bus wire type system (marshalling and unmarshalling), pure so it is tested and shared. D-Bus values are packed
// with per-type natural alignment (padded with zero bytes) in a chosen byte order; the header states the order ('l'
// little, 'B' big). The toolkit always writes little-endian (every Linux desktop is) and reads whatever the server
// sends.
//
// Type codes (the "signature" letters): y u8, b u32 bool, n i16, q u16, i i32, u u32, x i64, t u64, d f64, h u32 fd
// index, s string, o object path, g signature, a array, '(' ')' struct, '{' '}' dict entry, v variant.

import "base:runtime"
import "core:mem"

// A growing little-endian writer with D-Bus alignment. `base` is the offset the alignment is measured from (0 for a
// body; for a header the whole message starts at 0 so base stays 0).
Writer :: struct {
	buf:  [dynamic]u8,
	base: int,
}

writer_make :: proc(allocator := context.allocator) -> Writer {
	return Writer{buf = make([dynamic]u8, allocator)}
}

writer_destroy :: proc(w: ^Writer) { delete(w.buf) }

@(private)
w_align :: proc(w: ^Writer, a: int) {
	for (len(w.buf) - w.base) % a != 0 { append(&w.buf, 0) }
}

w_u8  :: proc(w: ^Writer, v: u8)  { append(&w.buf, v) }
w_u16 :: proc(w: ^Writer, v: u16) { w_align(w, 2); b := transmute([2]u8)v; append(&w.buf, ..b[:]) }
w_i16 :: proc(w: ^Writer, v: i16) { w_u16(w, cast(u16)v) }
w_u32 :: proc(w: ^Writer, v: u32) { w_align(w, 4); b := transmute([4]u8)v; append(&w.buf, ..b[:]) }
w_i32 :: proc(w: ^Writer, v: i32) { w_u32(w, cast(u32)v) }
w_u64 :: proc(w: ^Writer, v: u64) { w_align(w, 8); b := transmute([8]u8)v; append(&w.buf, ..b[:]) }
w_i64 :: proc(w: ^Writer, v: i64) { w_u64(w, cast(u64)v) }
w_f64 :: proc(w: ^Writer, v: f64) { w_u64(w, transmute(u64)v) }
w_bool :: proc(w: ^Writer, v: bool) { w_u32(w, v ? 1 : 0) }

// A string / object path: a u32 length then the bytes then a NUL (the NUL is not counted in the length).
w_string :: proc(w: ^Writer, s: string) {
	w_u32(w, u32(len(s)))
	append(&w.buf, s)
	append(&w.buf, 0)
}

// Raw bytes, no length prefix or alignment: the element bytes of a `y` array (the caller framed the array with
// w_array_begin / w_array_end at alignment 1).
w_bytes :: proc(w: ^Writer, b: []u8) { append(&w.buf, ..b) }

// A signature: a single-byte length then the bytes then a NUL.
w_signature :: proc(w: ^Writer, s: string) {
	w_u8(w, u8(len(s)))
	append(&w.buf, s)
	append(&w.buf, 0)
}

// Starts an array: reserves the u32 byte-count (filled by w_array_end), aligns to the element's alignment, and returns
// the offset where the content begins so the length can be computed.
w_array_begin :: proc(w: ^Writer, elem_align: int) -> (len_at: int, content_at: int) {
	w_align(w, 4)
	len_at = len(w.buf)
	append(&w.buf, 0, 0, 0, 0)   // placeholder for the length
	w_align(w, elem_align)
	content_at = len(w.buf)
	return
}

w_array_end :: proc(w: ^Writer, len_at, content_at: int) {
	n := u32(len(w.buf) - content_at)
	b := transmute([4]u8)n
	copy(w.buf[len_at:len_at + 4], b[:])
}

// Aligns to a struct / dict-entry boundary (8).
w_struct :: proc(w: ^Writer) { w_align(w, 8) }

// The alignment of the first element of a signature (for arrays). Pure.
sig_alignment :: proc(sig: string) -> int {
	if len(sig) == 0 { return 1 }
	switch sig[0] {
	case 'y', 'g', 'v': return 1
	case 'n', 'q':      return 2
	case 'b', 'i', 'u', 's', 'o', 'a', 'h': return 4
	case 'x', 't', 'd', '(', '{': return 8
	}
	return 1
}

////////////////////////////////
// Reader

// A little/big-endian reader over a message body, honouring D-Bus alignment from `base`.
Reader :: struct {
	buf:    []u8,
	pos:    int,
	base:   int,
	big:    bool,   // byte order
	err:    bool,   // set once anything ran past the end or was malformed; every read then returns a zero
}

reader_make :: proc(buf: []u8, big := false, base := 0) -> Reader {
	return Reader{buf = buf, base = base, big = big}
}

@(private)
r_align :: proc(r: ^Reader, a: int) {
	for (r.pos - r.base) % a != 0 {
		if r.pos >= len(r.buf) { r.err = true; return }
		r.pos += 1
	}
}

@(private)
r_need :: proc(r: ^Reader, n: int) -> bool {
	if r.err || r.pos + n > len(r.buf) { r.err = true; return false }
	return true
}

r_u8 :: proc(r: ^Reader) -> u8 {
	if !r_need(r, 1) { return 0 }
	v := r.buf[r.pos]; r.pos += 1
	return v
}
r_u16 :: proc(r: ^Reader) -> u16 {
	r_align(r, 2); if !r_need(r, 2) { return 0 }
	b := [2]u8{r.buf[r.pos], r.buf[r.pos + 1]}; r.pos += 2
	return r.big ? (u16(b[0]) << 8 | u16(b[1])) : transmute(u16)b
}
r_i16 :: proc(r: ^Reader) -> i16 { return cast(i16)r_u16(r) }
r_u32 :: proc(r: ^Reader) -> u32 {
	r_align(r, 4); if !r_need(r, 4) { return 0 }
	b := [4]u8{r.buf[r.pos], r.buf[r.pos + 1], r.buf[r.pos + 2], r.buf[r.pos + 3]}; r.pos += 4
	if r.big { return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3]) }
	return transmute(u32)b
}
r_i32 :: proc(r: ^Reader) -> i32 { return cast(i32)r_u32(r) }
r_u64 :: proc(r: ^Reader) -> u64 {
	r_align(r, 8); if !r_need(r, 8) { return 0 }
	b: [8]u8
	for i in 0 ..< 8 { b[i] = r.buf[r.pos + i] }
	r.pos += 8
	if r.big {
		v: u64
		for i in 0 ..< 8 { v = v << 8 | u64(b[i]) }
		return v
	}
	return transmute(u64)b
}
r_i64 :: proc(r: ^Reader) -> i64 { return cast(i64)r_u64(r) }
r_f64 :: proc(r: ^Reader) -> f64 { return transmute(f64)r_u64(r) }
r_bool :: proc(r: ^Reader) -> bool { return r_u32(r) != 0 }

// A string / object path: the length, then the bytes, then a NUL. Returns a view into the buffer.
r_string :: proc(r: ^Reader) -> string {
	n := int(r_u32(r))
	if !r_need(r, n + 1) { return "" }
	s := string(r.buf[r.pos:r.pos + n])
	r.pos += n + 1   // skip the trailing NUL
	return s
}

// A signature: a single-byte length, the bytes, a NUL.
r_signature :: proc(r: ^Reader) -> string {
	n := int(r_u8(r))
	if !r_need(r, n + 1) { return "" }
	s := string(r.buf[r.pos:r.pos + n])
	r.pos += n + 1
	return s
}

// Skips one complete value of the given signature (for values of a type we do not read). Advances the reader past it.
// `sig` is consumed from the front; returns how many signature characters one value took.
r_skip :: proc(r: ^Reader, sig: string) -> int {
	if len(sig) == 0 || r.err { return 0 }
	switch sig[0] {
	case 'y': r_u8(r); return 1
	case 'b': r_bool(r); return 1
	case 'n': r_i16(r); return 1
	case 'q': r_u16(r); return 1
	case 'i', 'h': r_i32(r); return 1
	case 'u': r_u32(r); return 1
	case 'x': r_i64(r); return 1
	case 't': r_u64(r); return 1
	case 'd': r_f64(r); return 1
	case 's', 'o': r_string(r); return 1
	case 'g': r_signature(r); return 1
	case 'v':
		vs := r_signature(r)
		r_skip(r, vs)
		return 1
	case 'a':
		inner := sig[1:]
		used := signature_one(inner)
		n := int(r_u32(r))
		r_align(r, sig_alignment(inner))
		end := r.pos + n
		for r.pos < end && !r.err { r_skip(r, inner) }
		r.pos = min(end, len(r.buf))
		return 1 + used
	case '(':
		r_align(r, 8)
		used := 1
		for used < len(sig) && sig[used] != ')' {
			used += r_skip(r, sig[used:])
		}
		return used + 1   // past the ')'
	case '{':
		r_align(r, 8)
		used := 1
		for used < len(sig) && sig[used] != '}' {
			used += r_skip(r, sig[used:])
		}
		return used + 1
	}
	return 1
}

// The number of signature characters one complete type takes at the front of `sig` (e.g. "a{sv}s" -> 5 for "a{sv}").
signature_one :: proc(sig: string) -> int {
	if len(sig) == 0 { return 0 }
	switch sig[0] {
	case 'a': return 1 + signature_one(sig[1:])
	case '(':
		depth, i := 1, 1
		for i < len(sig) && depth > 0 {
			if sig[i] == '(' { depth += 1 } else if sig[i] == ')' { depth -= 1 }
			i += 1
		}
		return i
	case '{':
		depth, i := 1, 1
		for i < len(sig) && depth > 0 {
			if sig[i] == '{' { depth += 1 } else if sig[i] == '}' { depth -= 1 }
			i += 1
		}
		return i
	}
	return 1
}

// Begins reading an array: returns the byte offset just past the array's content, and positions the reader at its
// first element. The caller reads elements while r.pos < end.
r_array_begin :: proc(r: ^Reader, elem_sig: string) -> (end: int) {
	n := int(r_u32(r))
	r_align(r, sig_alignment(elem_sig))
	return r.pos + n
}

// Opens a variant: reads its inner signature and returns it (the value follows, read with r_* for that signature).
r_variant_sig :: proc(r: ^Reader) -> string { return r_signature(r) }

_ :: mem
_ :: runtime
