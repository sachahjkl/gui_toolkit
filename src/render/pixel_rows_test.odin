package render

import "core:testing"

// Texels in a test row: more than a register and not a multiple of one, so that the last ones take the path of single texels.
@(private = "file") ROW_TEXELS :: 4 * 5 + 3

// swap_red_blue exchanges bytes 0 and 2 of every texel, at every length around a register's.
@(test)
swap_red_blue_exchanges_every_texel :: proc(t: ^testing.T) {
	src, dst: [ROW_TEXELS * 4]u8
	for &b, i in src { b = u8(i * 7 + 1) }
	for n in 0 ..= ROW_TEXELS {
		dst = 0xEE
		swap_red_blue(raw_data(dst[:]), raw_data(src[:]), n)
		wrong := 0
		for i in 0 ..< n {
			s, d := src[i * 4:], dst[i * 4:]
			if d[0] != s[2] || d[1] != s[1] || d[2] != s[0] || d[3] != s[3] { wrong += 1 }
		}
		testing.expectf(t, wrong == 0, "%d texels: %d wrong", n, wrong)
		testing.expectf(t, n == ROW_TEXELS || dst[n * 4] == 0xEE, "%d texels: wrote beyond them", n)
	}
}

// straight_srgb_rows gives straight_srgb of each texel: for every color value under every alpha, in both byte orders and
// both blend spaces, with opaque and translucent texels in one register.
@(test)
straight_srgb_rows_match_straight_srgb :: proc(t: ^testing.T) {
	src, dst: [ROW_TEXELS * 4]u8
	for layout in ([2]Texel_Layout{.RGBA8, .BGRA8}) {
		for space in Blend_Space {
			wrong := 0
			for a in 0 ..< 256 {
				for c in 0 ..< 256 {
					for i in 0 ..< ROW_TEXELS {
						// (every third texel opaque, and a run of opaque ones at the end)
						alpha := i % 3 == 0 || i >= ROW_TEXELS - 9 ? 255 : a
						src[i * 4], src[i * 4 + 1], src[i * 4 + 2], src[i * 4 + 3] = u8(c), u8(c + 85 + i), u8(c + 170), u8(alpha)
					}
					straight_srgb_rows(raw_data(dst[:]), raw_data(src[:]), len(src), {ROW_TEXELS, 1}, layout, space)
					for i in 0 ..< ROW_TEXELS {
						s := src[i * 4:]
						px := [4]f32{f32(s[0]) / 255, f32(s[1]) / 255, f32(s[2]) / 255, f32(s[3]) / 255}
						if layout == .BGRA8 { px.r, px.b = px.b, px.r }
						r, g, b, al := straight_srgb(px, space)
						if dst[i * 4] != r || dst[i * 4 + 1] != g || dst[i * 4 + 2] != b || dst[i * 4 + 3] != al { wrong += 1 }
					}
				}
			}
			testing.expectf(t, wrong == 0, "%v in %v: %d texels wrong", layout, space, wrong)
		}
	}
}

// Halves go through straight_srgb one by one, and a row starts `pitch` bytes after the one before.
@(test)
straight_srgb_rows_read_halves_and_rows :: proc(t: ^testing.T) {
	// (2 rows of 1 texel, a texel of padding after each)
	src := [4][4]f16{{0.25, 0.5, 0, 0.5}, {9, 9, 9, 9}, {1, 0, 0.5, 1}, {9, 9, 9, 9}}
	dst: [2 * 4]u8
	straight_srgb_rows(raw_data(dst[:]), ([^]u8)(&src), 2 * size_of([4]f16), {1, 2}, .Half, .Srgb)
	testing.expect_value(t, dst, [8]u8{128, 255, 0, 128, 255, 0, 128, 255})
}
