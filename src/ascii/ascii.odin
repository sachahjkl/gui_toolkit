package ascii

// ASCII case, for names and protocols: HTTP header names and hosts, font family names as cache keys, CSS keywords,
// enum names, file extensions, the changelog's fields. Only A-Z and a-z change: the Kelvin sign U+212A and the long s
// U+017F stay what they are, where strings.to_lower, to_upper and equal_fold fold by Unicode ("K" is 'k' to them).
// Those are for user text (a search, find in page, type-ahead, display): tests/unicode_case fails on a call of them
// that tools/unicode_case_allowed.txt does not list.

lower_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c }
upper_byte :: #force_inline proc "contextless" (c: u8) -> u8 { return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c }

// `s` in ASCII lowercase: `s` itself when it has no uppercase ASCII letter (no allocation), else a copy.
lower :: proc(s: string, allocator := context.temp_allocator) -> string {
	i := 0
	for i < len(s) && !(s[i] >= 'A' && s[i] <= 'Z') { i += 1 }
	if i == len(s) { return s }
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
