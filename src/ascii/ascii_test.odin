package ascii

import "core:strings"
import "core:testing"

// A-Z and a-z alone change case: the Kelvin sign U+212A and the long s U+017F are no 'k' and no 's'.
@(test)
ascii_case_leaves_other_letters :: proc(t: ^testing.T) {
	testing.expect_value(t, lower("Sec-WebSocket-Key"), "sec-websocket-key")
	testing.expect_value(t, lower("\u212Aey \u017Fet"), "\u212Aey \u017Fet")
	testing.expect_value(t, upper("div \u017F"), "DIV \u017F")
	testing.expect(t, equal_fold("HOST", "host"))
	testing.expect(t, !equal_fold("Ho\u017Ft", "Host"))
	testing.expect(t, !equal_fold("\u212Aey", "key"))
	testing.expect(t, has_prefix_fold("# Version: 16", "# version"))
	testing.expect(t, !has_prefix_fold("# Ver\u017Fion", "# vers"))
	testing.expect(t, contains_fold("Adwaita-DARK", "dark") && contains_fold("x", ""))
	testing.expect(t, !contains_fold("Dar\u212A", "dark") && !contains_fold("da", "dark"))
}

// compare_fold: the case ignored first, then the bytes; a prefix comes first.
@(test)
compare_fold_orders_names :: proc(t: ^testing.T) {
	testing.expect(t, compare_fold("bash", "Chrome") < 0)
	testing.expect(t, compare_fold("Chrome", "chrome") < 0)
	testing.expect(t, compare_fold("chrome", "Chrome") > 0)
	testing.expect(t, compare_fold("fire", "Firefox") < 0)
	testing.expect_value(t, compare_fold("same", "same"), 0)
	testing.expect(t, compare_fold("Key", "key") > 0)
}

// A generator of test bytes that gives the same ones on every run.
@(private = "file")
Bytes_Gen :: struct { state: u64 }

@(private = "file")
next_byte :: proc(g: ^Bytes_Gen) -> u8 {
	g.state = g.state * 6364136223846793005 + 1442695040888963407
	return u8(g.state >> 56)
}

// lower_run as one byte at a time does it: the reference of its vector path.
@(private = "file")
lower_run_scalar :: proc(dst: []u8, s: string) -> int {
	n := min(len(dst), len(s))
	i := 0
	for ; i < n && s[i] < 0x80; i += 1 { dst[i] = lower_byte(s[i]) }
	return i
}

@(private = "file")
expect_lower_run :: proc(t: ^testing.T, s: string, room: int) {
	got := make([]u8, room, context.temp_allocator)
	want := make([]u8, room, context.temp_allocator)
	n, m := lower_run(got, s), lower_run_scalar(want, s)
	testing.expectf(t, n == m && string(got[:n]) == string(want[:m]), "lower_run of % x (room %d): %d % x, not %d % x", transmute([]u8)s, room, n, got[:n], m, want[:m])
}

// Every length up to 64 (four registers and every tail), a byte >= 0x80 at every place, every byte value, and a
// destination shorter than the text: the vector path gives what the scalar one gives.
@(test)
lower_run_is_the_scalar_one :: proc(t: ^testing.T) {
	g := Bytes_Gen{1}
	for n in 0 ..= 64 {
		buf := make([]u8, n, context.temp_allocator)
		for &c in buf { c = next_byte(&g) & 0x7F }
		expect_lower_run(t, string(buf), n)
		expect_lower_run(t, string(buf), n / 2)
		for at in 0 ..< n {
			kept := buf[at]
			buf[at] = 0x80 | next_byte(&g)
			expect_lower_run(t, string(buf), n)
			buf[at] = kept
		}
	}
	all: [256]u8
	for &c, i in all { c = u8(i) }
	expect_lower_run(t, string(all[:]), len(all))
	expect_lower_run(t, string(all[:0x80]), 0x80)
	for c in 0 ..< 256 {
		line: [40]u8
		for &x in line { x = 'Q' }
		line[33] = u8(c)
		expect_lower_run(t, string(line[:]), len(line))
	}
	ab := "ABCDEFGHIJKLMNOPQRSTUVWXYZ@[`{ abcdefghijklmnopqrstuvwxyz"
	out := make([]u8, len(ab), context.temp_allocator)
	testing.expect_value(t, lower_run(out, ab), len(ab))
	testing.expect_value(t, string(out), "abcdefghijklmnopqrstuvwxyz@[`{ abcdefghijklmnopqrstuvwxyz")
}

// index_any_byte as one byte at a time does it.
@(private = "file")
index_any_byte_scalar :: proc(s, set: string, below: u8, non_ascii: bool) -> int {
	for i in 0 ..< len(s) {
		c := s[i]
		if c < below || (non_ascii && c >= 0x80) || strings.index_byte(set, c) >= 0 { return i }
	}
	return -1
}

// Sets of every size around INDEX_ANY_SET_MAX (past it: the scalar path), with and without the control characters and the
// bytes >= 0x80, a byte of the set at every place of every length up to 64, every byte value.
@(test)
index_any_byte_is_the_scalar_one :: proc(t: ^testing.T) {
	g := Bytes_Gen{2}
	sets := [?]string{"", "\"", "\"\\", ",;\t", "abcdefgh", "abcdefghi", "\x00\xff"}
	for set in sets {
		for below in ([]u8{0, 0x20}) {
			for non_ascii in ([]bool{false, true}) {
				for n in 0 ..= 64 {
					buf := make([]u8, n, context.temp_allocator)
					// (bytes none of the sets has, and none of the classes: then one that is, at every place)
					for &c in buf { c = 'm' + next_byte(&g) % 8 }
					got, want := index_any_byte(string(buf), set, below, non_ascii), index_any_byte_scalar(string(buf), set, below, non_ascii)
					testing.expectf(t, got == want, "%q in %q (below %x, non-ASCII %v): %d, not %d", set, string(buf), below, non_ascii, got, want)
					for at in 0 ..< n {
						kept := buf[at]
						for c in ([]u8{0x01, 0x1F, 0x20, '"', '\\', 'a', 'h', 'i', 0x7F, 0x80, 0xC3, 0xFF, 0x00, ',', '\t'}) {
							buf[at] = c
							got, want = index_any_byte(string(buf), set, below, non_ascii), index_any_byte_scalar(string(buf), set, below, non_ascii)
							testing.expectf(t, got == want, "%q in % x (below %x, non-ASCII %v): %d, not %d", set, buf, below, non_ascii, got, want)
						}
						buf[at] = kept
					}
				}
				all: [256]u8
				for &c, i in all { c = u8(255 - i) }
				for from in 0 ..< len(all) {
					got, want := index_any_byte(string(all[from:]), set, below, non_ascii), index_any_byte_scalar(string(all[from:]), set, below, non_ascii)
					testing.expectf(t, got == want, "%q from %d (below %x, non-ASCII %v): %d, not %d", set, from, below, non_ascii, got, want)
				}
			}
		}
	}
	testing.expect_value(t, index_any_byte(`a long run of plain text, then "a quote"`, "\"\\", 0x20), 31)
	testing.expect_value(t, index_any_byte("plain text all along, nothing to find in it at all", "\"\\", 0x20, true), -1)
	testing.expect_value(t, index_any_byte("plain text all along, then café", "\"\\", 0x20, true), 30)
}
