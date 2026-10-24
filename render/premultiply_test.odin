package render

import "core:testing"

// premultiply_word against the formula it replaces, for every color value and every alpha.
@(test)
premultiply_word_matches_the_formula :: proc(t: ^testing.T) {
	wrong := 0
	for a in 0 ..< 256 {
		for c in 0 ..< 256 {
			// the three channels carry different values so that a lane leaking into its neighbour shows
			px := u32(c) | u32((c + 85) & 255) << 8 | u32((c + 170) & 255) << 16 | u32(a) << 24
			out := premultiply_word(px)
			for k in 0 ..< 3 {
				v := int((px >> (8 * uint(k))) & 255)
				want := (v * a + 127) / 255
				if int((out >> (8 * uint(k))) & 255) != want { wrong += 1 }
			}
			if int(out >> 24) != a { wrong += 1 }
		}
	}
	testing.expect_value(t, wrong, 0)
}
