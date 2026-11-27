package tk_image

import "core:math"

// A table per channel (docs/image.md, "Tables"; src/md/features/lut.md): entry i is what each channel's value i becomes,
// [red, green, blue, alpha], on straight 8-bit values. The same table previews on the GPU (draw.filter_lut with
// draw.lut_texture) and is written into a picture here (lut_apply): what the person sees is what the file gets.
Lut :: [256][4]u8

Lut_Channel :: enum u8 { Red, Green, Blue, Alpha }
Lut_Channels :: bit_set[Lut_Channel; u8]

// The colours, not the alpha: what levels, exposure and a curve change unless told otherwise.
LUT_COLORS :: Lut_Channels{.Red, .Green, .Blue}

// Every value stays.
lut_identity :: proc() -> (l: Lut) {
	for &e, i in l { e = {u8(i), u8(i), u8(i), u8(i)} }
	return
}

// `f` (0..1 to 0..1) on `channels`, the others unchanged.
@(private = "file")
lut_of :: proc(f: proc(x: f32, user: rawptr) -> f32, user: rawptr, channels: Lut_Channels) -> (l: Lut) {
	l = lut_identity()
	for i in 0 ..< 256 {
		v := u8(math.round(clamp(f(f32(i) / 255, user), 0, 1) * 255))
		for c in Lut_Channel { if c in channels { l[i][int(c)] = v } }
	}
	return
}

// Levels: the input's `black` and `white` points (0..1) stretched to the whole range, then `gamma` (1: straight; above
// 1 lighter mid-tones, as an editor's middle slider). On `channels`.
lut_levels :: proc(black: f32 = 0, white: f32 = 1, gamma: f32 = 1, channels := LUT_COLORS) -> Lut {
	Levels :: struct { black, span, inv_gamma: f32 }
	lv := Levels{black, max(white - black, 1.0 / 255), 1 / max(gamma, 0.01)}
	return lut_of(proc(x: f32, user: rawptr) -> f32 {
		lv := (^Levels)(user)
		return math.pow(clamp((x - lv.black) / lv.span, 0, 1), lv.inv_gamma)
	}, &lv, channels)
}

// Exposure, in stops: each colour times 2^stops in linear light (decoded from sRGB, then encoded again), as a camera's.
lut_exposure :: proc(stops: f32, channels := LUT_COLORS) -> Lut {
	k := math.pow(2, stops)
	return lut_of(proc(x: f32, user: rawptr) -> f32 {
		return srgb_encode(srgb_decode(x) * (^f32)(user)^)
	}, &k, channels)
}

// A curve through `points` (input, output, 0..1, in the order of their inputs): smooth between them and monotone where
// they are (Fritsch and Carlson's cubic: no overshoot past a point, as an editor's curves), flat past the first and the
// last. Fewer than two points: the identity. On `channels`.
lut_curve :: proc(points: [][2]f32, channels := LUT_COLORS) -> Lut {
	n := len(points)
	if n < 2 { return lut_identity() }
	Curve :: struct { p: [][2]f32, m: []f32 }
	// the slopes at the points (Fritsch-Carlson): the secants' mean, zero at a peak, cut so that no segment overshoots
	d := make([]f32, n - 1, context.temp_allocator)
	m := make([]f32, n, context.temp_allocator)
	for k in 0 ..< n - 1 {
		dx := points[k + 1].x - points[k].x
		d[k] = dx > 0 ? (points[k + 1].y - points[k].y) / dx : 0
	}
	m[0], m[n - 1] = d[0], d[n - 2]
	for k in 1 ..< n - 1 { m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) * 0.5 }
	for k in 0 ..< n - 1 {
		if d[k] == 0 { m[k], m[k + 1] = 0, 0; continue }
		a, b := m[k] / d[k], m[k + 1] / d[k]
		if s := a * a + b * b; s > 9 {
			t := 3 / math.sqrt(s)
			m[k], m[k + 1] = t * a * d[k], t * b * d[k]
		}
	}
	cv := Curve{points, m}
	return lut_of(proc(x: f32, user: rawptr) -> f32 {
		cv := (^Curve)(user)
		p := cv.p
		if x <= p[0].x { return p[0].y }
		if x >= p[len(p) - 1].x { return p[len(p) - 1].y }
		k := 0
		for k < len(p) - 2 && x > p[k + 1].x { k += 1 }
		h := p[k + 1].x - p[k].x
		if h <= 0 { return p[k + 1].y }
		t := (x - p[k].x) / h
		t2, t3 := t * t, t * t * t
		return (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * cv.m[k] + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * cv.m[k + 1]
	}, &cv, channels)
}

// `a`, then `b`: one table that does both (levels, then a curve, then exposure: one pass over the pixels, one GPU pass).
lut_then :: proc(a, b: Lut) -> (l: Lut) {
	for i in 0 ..< 256 { for c in 0 ..< 4 { l[i][c] = b[a[i][c]][c] } }
	return
}

// In place: each channel of each pixel through its table.
lut_apply :: proc(img: Image, l: ^Lut) #no_bounds_check {
	if !valid(img) { return }
	n := img.width * img.height * 4
	for i := 0; i < n; i += 4 {
		p := img.pixels[i:][:4]
		p[0], p[1], p[2], p[3] = l[p[0]][0], l[p[1]][1], l[p[2]][2], l[p[3]][3]
	}
}

@(private = "file")
srgb_decode :: proc(c: f32) -> f32 { return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) }

@(private = "file")
srgb_encode :: proc(c0: f32) -> f32 {
	c := clamp(c0, 0, 1)
	return c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055
}
