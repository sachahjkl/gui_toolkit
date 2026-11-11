package flate

import "core:testing"

// Bytes compared: 3 registers and a few more, so that the last ones take the path of single bytes.
@(private = "file") SAME_BYTES :: 3 * 16 + 5

// `same` stops at the first byte that differs, wherever it is, and at its limit.
@(test)
same_stops_at_the_first_difference :: proc(t: ^testing.T) {
	p, q: [SAME_BYTES]u8
	for &b, i in p { b = u8(i * 31 + 7) }
	for limit in 0 ..= SAME_BYTES {
		q = p
		testing.expect_value(t, same(raw_data(p[:]), raw_data(q[:]), limit), limit)
		for at in 0 ..< limit {
			q = p
			q[at] ~= 0x80
			if at + 1 < SAME_BYTES { q[at + 1] ~= 1 }   // (a second difference after the first changes nothing)
			got := same(raw_data(p[:]), raw_data(q[:]), limit)
			testing.expectf(t, got == at, "limit %d, a difference at %d: %d", limit, at, got)
		}
	}
}
