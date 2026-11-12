package tk_image

import "core:math"

// Colour adjustments, in place. Alpha stays. Each is a table of 256 values or a 3 x 3 matrix in fixed point: no
// floating point per pixel.

// Each pixel its luma (BT.601: (77 r + 150 g + 29 b + 128) / 256), in grey.
grayscale :: proc(img: Image) #no_bounds_check {
	if !valid(img) { return }
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		y := u8(luma(p[0], p[1], p[2]))
		p[0], p[1], p[2] = y, y, y
	}
}

@(private)
luma :: #force_inline proc "contextless" (r, g, b: u8) -> u32 {
	return (77 * u32(r) + 150 * u32(g) + 29 * u32(b) + 128) >> 8
}

// Each colour 255 minus itself.
invert :: proc(img: Image) #no_bounds_check {
	if !valid(img) { return }
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		p[0], p[1], p[2] = 255 - p[0], 255 - p[1], 255 - p[2]
	}
}

// `brightness` from -1 (black) to 1 (white) is added; `contrast` from -1 (flat grey) to 1 (black and white) spreads the
// colours from the middle grey (GIMP's: the slope is tan((contrast + 1) * pi / 4)). 0 and 0 change nothing.
brightness_contrast :: proc(img: Image, brightness, contrast: f32) {
	if !valid(img) { return }
	c := clamp(contrast, -1, 0.999)
	slope := math.tan((c + 1) * math.PI / 4)
	table: [256]u8
	for &v, i in table {
		x := (f32(i) - 127.5) * slope + 127.5 + clamp(brightness, -1, 1) * 255
		v = u8(clamp(x, 0, 255) + 0.5)
	}
	apply_table(img, &table)
}

// Pixels whose luma is `level` or more become white, the others black.
threshold :: proc(img: Image, level: u8) #no_bounds_check {
	if !valid(img) { return }
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		v: u8 = luma(p[0], p[1], p[2]) >= u32(level) ? 255 : 0
		p[0], p[1], p[2] = v, v, v
	}
}

// Colours moved from their grey by `amount`: 0 grey, 1 unchanged, above 1 more vivid (CSS's saturate()).
saturation :: proc(img: Image, amount: f32) {
	s := max(amount, 0)
	m := [3][3]f32 {
		{0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s},
		{0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s},
		{0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s},
	}
	apply_matrix(img, m)
}

// Hues turned by `degrees` around the colour wheel, their luminance kept (CSS's hue-rotate()).
hue_rotate :: proc(img: Image, degrees: f32) {
	a := math.to_radians(degrees)
	c, s := math.cos(a), math.sin(a)
	m := [3][3]f32 {
		{0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928},
		{0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283},
		{0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072},
	}
	apply_matrix(img, m)
}

// The brown tones of an old photograph (CSS's sepia(1)).
sepia :: proc(img: Image) {
	m := [3][3]f32 {
		{0.393, 0.769, 0.189},
		{0.349, 0.686, 0.168},
		{0.272, 0.534, 0.131},
	}
	apply_matrix(img, m)
}

@(private = "file")
apply_table :: proc(img: Image, table: ^[256]u8) #no_bounds_check {
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		p[0], p[1], p[2] = table[p[0]], table[p[1]], table[p[2]]
	}
}

// (12 bits of fraction: the sum of 3 products of 255 stays far inside an i32)
@(private = "file")
FIXED :: 4096

// Each colour (r, g, b) becomes m * (r, g, b), cut to 0..255.
@(private = "file")
apply_matrix :: proc(img: Image, m: [3][3]f32) #no_bounds_check {
	if !valid(img) { return }
	k: [3][3]i32
	for row, j in m { for v, i in row { k[j][i] = i32(math.round(v * FIXED)) } }
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		r, g, b := i32(p[0]), i32(p[1]), i32(p[2])
		for c in 0 ..< 3 {
			v := (k[c][0] * r + k[c][1] * g + k[c][2] * b + FIXED / 2) / FIXED
			p[c] = u8(clamp(v, 0, 255))
		}
	}
}
