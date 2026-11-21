package tk_utf8

import "core:testing"

EXHAUSTIVE :: #config(EXHAUSTIVE, false)

@(test)
valid_and_invalid_sequences :: proc(t: ^testing.T) {
	Case :: struct {
		bytes:     []u8,
		rfc:       bool,   // valid RFC 3629 UTF-8
		no_ctrl:   bool,   // valid with reject_controls = true
	}
	cases := [?]Case{
		{{}, true, true},
		{transmute([]u8)string("Hello, world!"), true, true},
		{transmute([]u8)string("line1\nline2\t\r"), true, false},
		{{0x00}, true, false},
		{{0x7F}, true, false},
		{{0xC2, 0x80}, true, false},    // U+0080 C1 control
		{{0xC2, 0x9F}, true, false},    // U+009F C1 control
		{{0xC2, 0xA0}, true, true},     // U+00A0 NBSP
		{transmute([]u8)string("Français 日本語 🎉"), true, true},
		{{0x80}, false, false},                           // lone continuation
		{{0xC0, 0xAF}, false, false},                     // overlong '/'
		{{0xC1, 0xBF}, false, false},                     // overlong
		{{0xE0, 0x9F, 0xBF}, false, false},               // overlong 3-byte
		{{0xE0, 0xA0, 0x80}, true, true},                 // min 3-byte U+0800
		{{0xED, 0x9F, 0xBF}, true, true},                 // U+D7FF before surrogates
		{{0xED, 0xA0, 0x80}, false, false},               // U+D800 surrogate
		{{0xED, 0xBF, 0xBF}, false, false},               // U+DFFF surrogate
		{{0xEE, 0x80, 0x80}, true, true},                 // U+E000 after surrogates
		{{0xF0, 0x8F, 0xBF, 0xBF}, false, false},         // overlong 4-byte
		{{0xF0, 0x90, 0x80, 0x80}, true, true},           // min 4-byte U+10000
		{{0xF4, 0x8F, 0xBF, 0xBF}, true, true},           // max U+10FFFF
		{{0xF4, 0x90, 0x80, 0x80}, false, false},         // U+110000 out of range
		{{0xF5, 0x80, 0x80, 0x80}, false, false},         // invalid lead
		{{0xFF}, false, false},
		{{0xC2}, false, false},                           // truncated 2-byte
		{{0xE2, 0x82}, false, false},                     // truncated 3-byte
		{{0xF0, 0x9F, 0x8E}, false, false},               // truncated 4-byte
	}
	for c in cases {
		testing.expect_value(t, valid_scalar(c.bytes, false), c.rfc)
		testing.expect_value(t, valid(c.bytes, false), c.rfc)
		testing.expect_value(t, valid_scalar(c.bytes, true), c.no_ctrl)
		testing.expect_value(t, valid(c.bytes, true), c.no_ctrl)
	}
}

// Every length around 16-byte group boundaries, and every unaligned start offset 0..15.
@(test)
group_boundaries_and_unaligned_starts :: proc(t: ^testing.T) {
	buf: [64]u8
	for &b in buf { b = 'a' }
	// 4-byte emoji placed at every offset 0..32, followed by ASCII groups (catches truncated leads across ASCII fast path)
	emoji := [4]u8{0xF0, 0x9F, 0x8E, 0x89}
	for start in 0 ..< 16 {
		for off in 0 ..< 24 {
			for &b in buf { b = 'a' }
			for k in 0 ..< 4 { buf[start + off + k] = emoji[k] }
			for end in start + off ..= start + off + 20 {
				s := buf[start:end]
				testing.expect_value(t, valid(s, false), valid_scalar(s, false))
				testing.expect_value(t, valid(s, true), valid_scalar(s, true))
			}
		}
	}
}

// Three-byte windows crossing a 16-byte boundary: 1 in 251 by default (~66k windows), all 2^24 with -define:EXHAUSTIVE=true.
@(test)
three_byte_windows_across_boundary :: proc(t: ^testing.T) {
	step := EXHAUSTIVE ? 1 : 251
	buf: [32]u8 = 'a'
	for v := 0; v < (1 << 24); v += step {
		buf[14] = u8(v >> 16)
		buf[15] = u8(v >> 8)
		buf[16] = u8(v)
		for ctrl in ([]bool{false, true}) {
			if valid(buf[:], ctrl) != valid_scalar(buf[:], ctrl) {
				testing.expectf(t, false, "mismatch at %02x %02x %02x (ctrl=%v)", buf[14], buf[15], buf[16], ctrl)
				return
			}
		}
	}
}

// Deterministic fuzz test: 400 000 texts of valid, mutated, boundary-biased and random bytes, in both modes.
@(test)
simd_matches_scalar_on_400k_texts :: proc(t: ^testing.T) {
	state: u64 = 0x9E37_79B9_7F4A_7C15
	next_u64 :: proc(s: ^u64) -> u64 {
		x := s^
		x ~= x << 13
		x ~= x >> 7
		x ~= x << 17
		s^ = x
		return x
	}
	// Biased alphabet covering ASCII, controls, leads, continuations, overlong/surrogate edges
	interesting := [?]u8{0x00, 0x0A, 0x1F, 0x20, 'A', 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xED, 0xEE, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF}
	buf: [80]u8
	for round in 0 ..< 400_000 {
		n := int(next_u64(&state) % 80)
		mode := round % 4
		switch mode {
		case 0:
			// random bytes from the interesting edge alphabet
			for i in 0 ..< n { buf[i] = interesting[next_u64(&state) % len(interesting)] }
		case 1:
			// valid UTF-8 with occasional single-byte corruption
			i := 0
			for i < n {
				r := next_u64(&state) % 10
				switch {
				case r < 5 || n - i < 2: buf[i] = u8(0x20 + (next_u64(&state) % 95)); i += 1
				case r < 7 || n - i < 3: buf[i] = 0xC3; buf[i + 1] = u8(0x80 + (next_u64(&state) % 64)); i += 2
				case r < 9 || n - i < 4: buf[i] = 0xE2; buf[i + 1] = 0x82; buf[i + 2] = 0xAC; i += 3
				case:                    buf[i] = 0xF0; buf[i + 1] = 0x9F; buf[i + 2] = 0x8E; buf[i + 3] = 0x89; i += 4
				}
			}
			if n > 0 && next_u64(&state) % 2 == 0 {
				buf[next_u64(&state) % u64(n)] = interesting[next_u64(&state) % len(interesting)]
			}
		case 2:
			// mostly ASCII with one late multi-byte or control
			for i in 0 ..< n { buf[i] = 'x' }
			if n > 0 { buf[next_u64(&state) % u64(n)] = interesting[next_u64(&state) % len(interesting)] }
			if n > 1 { buf[next_u64(&state) % u64(n)] = interesting[next_u64(&state) % len(interesting)] }
		case 3:
			// uniform random bytes
			for i in 0 ..< n { buf[i] = u8(next_u64(&state)) }
		}
		ctrl := (round & 1) == 1
		s := buf[:n]
		if valid(s, ctrl) != valid_scalar(s, ctrl) {
			testing.expectf(t, false, "round %d (len=%d, ctrl=%v): mismatch", round, n, ctrl)
			return
		}
	}
}
