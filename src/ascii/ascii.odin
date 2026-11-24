package ascii

// ASCII case, for names and protocols: HTTP header names and hosts, font family names as cache keys, CSS keywords,
// enum names, file extensions, the changelog's fields. Only A-Z and a-z change: the Kelvin sign U+212A and the long s
// U+017F stay what they are, where strings.to_lower, to_upper and equal_fold fold by Unicode ("K" is 'k' to them).
// Those are for user text (a search, find in page, type-ahead, display): tests/unicode_case fails on a call of them
// that tools/unicode_case_allowed.txt does not list.

import "base:intrinsics"
import "core:simd"

lower_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c }
upper_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c }

// `s` in ASCII lowercase, always a copy in `allocator`. (It returned `s` itself when nothing changed: a caller that owns
// what it gets freed `s` a second time, the What's new page's double free on Windows.)
lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for c, k in transmute([]u8)s { out[k] = lower_byte(c) }
	return string(out)
}

// `s` in ASCII uppercase, a copy.
upper :: proc(s: string, allocator := context.temp_allocator) -> string {
	out := make([]u8, len(s), allocator)
	for c, k in transmute([]u8)s { out[k] = upper_byte(c) }
	return string(out)
}

equal_fold :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) {
		if a[i] != b[i] && lower_byte(a[i]) != lower_byte(b[i]) { return false }
	}
	return true
}

has_prefix_fold :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && equal_fold(s[:len(prefix)], prefix)
}

contains_fold :: proc "contextless" (hay, needle: string) -> bool {
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		if equal_fold(hay[i:][:len(needle)], needle) { return true }
	}
	return false
}

// Orders `a` and `b` with case ignored (ASCII), then as they are: < 0 when `a` comes first, 0 when they are the same
// bytes. Names in a table sorted A to Z ("bash" before "Chrome" before "chrome").
compare_fold :: proc "contextless" (a, b: string) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		x, y := lower_byte(a[i]), lower_byte(b[i])
		if x != y { return int(x) - int(y) }
	}
	if len(a) != len(b) { return len(a) - len(b) }
	for i in 0 ..< len(a) {
		if a[i] != b[i] { return int(a[i]) - int(b[i]) }
	}
	return 0
}

// Orders two names as a person reads them: a run of digits compares by its value ("file 2" before "file 10"), the
// other bytes as compare_fold does (ASCII case ignored). Two names equal so far: the run with fewer leading zeros first
// ("a1" before "a01"), then compare_fold. 0 only when the bytes are the same. A run is never made a number: a run of any
// length compares, without its leading zeros by its length, then digit by digit.
compare_natural :: proc "contextless" (a, b: string) -> int {
	is_digit :: #force_inline proc "contextless" (c: u8) -> bool { return c >= '0' && c <= '9' }
	i, j := 0, 0
	zeros := 0   // (the first run whose leading zeros differ: decides only when all else is the same)
	for i < len(a) && j < len(b) {
		x, y := a[i], b[j]
		if is_digit(x) && is_digit(y) {
			ia, ib := i, j
			for ia < len(a) && a[ia] == '0' { ia += 1 }
			for ib < len(b) && b[ib] == '0' { ib += 1 }
			ea, eb := ia, ib
			for ea < len(a) && is_digit(a[ea]) { ea += 1 }
			for eb < len(b) && is_digit(b[eb]) { eb += 1 }
			if ea - ia != eb - ib { return (ea - ia) - (eb - ib) }
			for k in 0 ..< ea - ia {
				if a[ia + k] != b[ib + k] { return int(a[ia + k]) - int(b[ib + k]) }
			}
			if zeros == 0 { zeros = (ia - i) - (ib - j) }
			i, j = ea, eb
			continue
		}
		lx, ly := lower_byte(x), lower_byte(y)
		if lx != ly { return int(lx) - int(ly) }
		i += 1
		j += 1
	}
	if i < len(a) { return 1 }
	if j < len(b) { return -1 }
	if zeros != 0 { return zeros }
	return compare_fold(a, b)
}

// What the vector paths read at once: one SSE2 or NEON register (x86-64's baseline: no other is assumed).
@(private) LANES :: 16
@(private) Bytes :: #simd[LANES]u8

// Lowers the ASCII run at the start of `s` into `dst` (A-Z to a-z, the other bytes as they are) and returns its length:
// it stops at the first byte >= 0x80, where a text needs a Unicode fold (ui's fuzzy matching), or at the end of the
// shorter of the two. A register of bytes at a time, then one by one.
lower_run :: proc "contextless" (dst: []u8, s: string) -> int #no_bounds_check {
	n := min(len(dst), len(s))
	src, out := raw_data(s), raw_data(dst)
	i := 0
	for ; i + LANES <= n; i += LANES {
		v := intrinsics.unaligned_load((^Bytes)(&src[i]))
		// (a byte >= 0x80 in it: the ASCII bytes before that one are lowered one by one below)
		if transmute(u16)simd.extract_msbs(v) != 0 { break }
		// (A-Z: less 'A', the others wrap or stay above 25)
		upper := simd.lanes_lt(v - Bytes(0x41), Bytes(26))   // ('A' is 0x41)
		intrinsics.unaligned_store((^Bytes)(&out[i]), simd.select(upper, v + Bytes(0x20), v))   // ('a' - 'A')
	}
	for ; i < n && src[i] < 0x80; i += 1 { out[i] = lower_byte(src[i]) }
	return i
}

// The bytes of a set that index_any_byte compares a register with; a longer set is looked for one byte at a time.
INDEX_ANY_SET_MAX :: 8

// The index of the first byte of `s` that is in `set`, or below `below` (0x20: the control characters), or >= 0x80 when
// `non_ascii` (where a UTF-8 text needs a rune's handling); -1 when none is. A register of bytes at a time for a set of up
// to INDEX_ANY_SET_MAX bytes (a JSON string's quote and backslash), then one by one.
index_any_byte :: proc "contextless" (s: string, set: string, below: u8 = 0, non_ascii := false) -> int #no_bounds_check {
	src := raw_data(s)
	i := 0
	if len(set) <= INDEX_ANY_SET_MAX {
		wanted: [INDEX_ANY_SET_MAX]Bytes
		for k in 0 ..< len(set) { wanted[k] = set[k] }
		low: Bytes = below
		high: Bytes = 0x80
		for ; i + LANES <= len(s); i += LANES {
			v := intrinsics.unaligned_load((^Bytes)(&src[i]))
			hit := simd.lanes_lt(v, low)
			if non_ascii { hit |= simd.lanes_ge(v, high) }
			for k in 0 ..< len(set) { hit |= simd.lanes_eq(v, wanted[k]) }
			if m := transmute(u16)simd.extract_msbs(hit); m != 0 { return i + int(intrinsics.count_trailing_zeros(m)) }
		}
	}
	for ; i < len(s); i += 1 {
		c := src[i]
		if c < below || (non_ascii && c >= 0x80) { return i }
		for k in 0 ..< len(set) { if set[k] == c { return i } }
	}
	return -1
}
