package ui

import "base:runtime"
import "core:math"
import "../font"

// The certification seal of the licence card, in relief: a medal of 88 units that the shader (licence_card.wgsl, seal_shade)
// lights with the card's own lights. Both of its textures are LICENCE_SEAL_TEX x LICENCE_SEAL_TEX texels (4 to a unit):
//
//  - the relief (seal_normal_map, on a chore): a height field turned into normals, like the card's. From the edge in:
//        the reeded edge   r 37.6 .. 44    SEAL_FLUTES flutes round it, rounded off at the outer rim; gold
//        the lip           r 34.4 .. 37.6  a smooth rounded ring above the edge's valleys; gold
//        the rib           r 30.2 .. 32.2  a thin ring standing on the face; gold
//        the face          r < 34.4        a dome, with fine concentric rings (a groove every 2 units) that fade in towards
//                                          the middle; green
//    R G the normal (x, y, y down), B how open the point is (255 in the open, less in a groove: the shader darkens it), A how
//    gold it is.
//  - the lettering: the word and the tick, raised like the card's text (licence_card_engrave.odin has the channels).
//
// The medal is a disc: the texture is the square that holds it, the shader sees the plane's own 0 .. 1.

@(private) LICENCE_SEAL_TEX :: 352
@(private) LICENCE_SEAL_DESIGN :: 88.0       // the medal's diameter, units
@(private = "file") SEAL_FLUTES :: 45
@(private = "file") SEAL_SCALE :: f32(LICENCE_SEAL_TEX) / LICENCE_SEAL_DESIGN   // texels to a unit (4)

// The tick, in units of the medal: a polyline stroked SEAL_TICK_W wide with round caps and joins (the flat medal draws the
// same one).
@(private) LICENCE_SEAL_TICK :: [3][2]f32{{31.75, 27.5}, {40.25, 36}, {56.25, 17}}
@(private) LICENCE_SEAL_TICK_W :: 4.0
@(private = "file") SEAL_BEVEL_K :: 9.0   // steeper than the card's text: the word is small

// The word: its size, tracking and baseline, units of the medal; it is centred, and made smaller to fit SEAL_WORD_MOST.
@(private) LICENCE_SEAL_WORD_SIZE :: 9.0
@(private) LICENCE_SEAL_WORD_TRACK :: 0.08
@(private) LICENCE_SEAL_WORD_BASELINE :: 56.5
@(private) LICENCE_SEAL_WORD_MOST :: 62.0

@(private = "file")
smooth :: proc(a, b, x: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

// A rounded rib: cos² across `w` centred on `c`, `h` tall.
@(private = "file")
rib :: proc(r, c, w, h: f32) -> f32 {
	d := abs(r - c) / (w * 0.5)
	if d >= 1 { return 0 }
	k := math.cos(d * math.PI * 0.5)
	return h * k * k
}

// The height of the medal (units) at `r` from its centre and `a` radians round it, and how gold the point is (0 .. 1).
@(private = "file")
seal_height :: proc(r, a: f32) -> (h, gold: f32) {
	if r >= 44 { return 0, 1 }
	// the reeded edge: flutes from 38 out, the outer rim falling away in the last unit
	flute := 0.5 + 0.5 * math.cos(SEAL_FLUTES * a)
	edge := (1.3 + 0.55 * flute) * (1 - smooth(42.6, 44.0, r)) * smooth(37.0, 38.4, r)
	// the lip, standing above the edge's valleys
	lip := rib(r, 36.0, 3.4, 2.3)
	// the face: a dome that rises above its rim, and fine rings that fade in from the middle and out towards the rib
	dome := 0.4 + 11.0 * max(1 - (r / 34.4) * (r / 34.4), 0)
	fine := 0.14 * math.cos(2 * math.PI * r / 2.0) * smooth(2.0, 7.0, r) * (1 - smooth(27.5, 29.0, r))
	face := (dome + fine) * (1 - smooth(33.8, 34.8, r))
	h = max(max(edge, lip), face) + rib(r, 31.2, 2.0, 0.9)
	gold = max(max(smooth(37.0, 38.0, r), clamp(rib(r, 36.0, 3.4, 1) * 1.6, 0, 1)), clamp(rib(r, 31.2, 2.0, 1) * 1.7, 0, 1))
	return h, gold
}

// The relief of the seal: LICENCE_SEAL_TEX x LICENCE_SEAL_TEX texels of RGBA8 (see the top of the file), in the heap. The same
// bytes every time. On a chore.
@(private)
seal_normal_map :: proc() -> []u8 {
	context.allocator = runtime.heap_allocator()
	N :: LICENCE_SEAL_TEX
	hf := make([]f32, N * N)
	defer delete(hf)
	gold := make([]f32, N * N)
	defer delete(gold)
	for y in 0 ..< N {
		for x in 0 ..< N {
			px, py := (f32(x) + 0.5) / SEAL_SCALE - LICENCE_SEAL_DESIGN / 2, (f32(y) + 0.5) / SEAL_SCALE - LICENCE_SEAL_DESIGN / 2
			hf[y * N + x], gold[y * N + x] = seal_height(math.sqrt(px * px + py * py), math.atan2(py, px))
		}
	}
	// the cavity: how far the point lies below its surroundings (a box of 9 x 9 texels, twice)
	blur := make([]f32, N * N)
	defer delete(blur)
	copy(blur, hf)
	licence_box_blur(blur, N, N, 4, 2)
	out := make([]u8, N * N * 4)
	for y in 0 ..< N {
		for x in 0 ..< N {
			xm, xp := max(x - 1, 0), min(x + 1, N - 1)
			ym, yp := max(y - 1, 0), min(y + 1, N - 1)
			gx := (hf[ym * N + xp] + 2 * hf[y * N + xp] + hf[yp * N + xp] - hf[ym * N + xm] - 2 * hf[y * N + xm] - hf[yp * N + xm]) / (8 * f32(xp - xm) * 0.5) * SEAL_SCALE
			gy := (hf[yp * N + xm] + 2 * hf[yp * N + x] + hf[yp * N + xp] - hf[ym * N + xm] - 2 * hf[ym * N + x] - hf[ym * N + xp]) / (8 * f32(yp - ym) * 0.5) * SEAL_SCALE
			nx, ny := -gx, -gy
			inv := 1 / math.sqrt(nx * nx + ny * ny + 1)
			i := (y * N + x) * 4
			out[i + 0] = u8(clamp(128 + nx * inv * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * inv * 127, 0, 255))
			out[i + 2] = u8(clamp((1 - (blur[y * N + x] - hf[y * N + x]) * 0.7) * 255, 90, 255))
			out[i + 3] = u8(clamp(gold[y * N + x] * 255, 0, 255))
		}
	}
	return out
}

// The distance from (px, py) to the segment a-b.
@(private)
segment_distance :: proc(px, py: f32, a, b: [2]f32) -> f32 {
	dx, dy := b.x - a.x, b.y - a.y
	t := clamp(((px - a.x) * dx + (py - a.y) * dy) / (dx * dx + dy * dy), 0, 1)
	ex, ey := px - (a.x + t * dx), py - (a.y + t * dy)
	return math.sqrt(ex * ex + ey * ey)
}

// The tick added to a coverage field of the seal (w x h texels at SEAL_SCALE): from the distance to the polyline, one texel of
// antialiasing.
@(private)
seal_tick_cover :: proc(cov: []f32, w, h: int) {
	tick := LICENCE_SEAL_TICK
	for y in 0 ..< h {
		for x in 0 ..< w {
			px, py := (f32(x) + 0.5) / SEAL_SCALE, (f32(y) + 0.5) / SEAL_SCALE
			d := min(segment_distance(px, py, tick[0], tick[1]), segment_distance(px, py, tick[1], tick[2]))
			c := clamp((LICENCE_SEAL_TICK_W * 0.5 - d) * SEAL_SCALE + 0.5, 0, 1)
			cov[y * w + x] = max(cov[y * w + x], c)
		}
	}
}

// The size the seal's word is set at: LICENCE_SEAL_WORD_SIZE, smaller when the word (a translation) is wider than the face.
@(private)
seal_word_size :: proc(fs: ^font.State, face: font.Font_Id, word: string) -> f32 {
	w := engrave_width(fs, face, word, LICENCE_SEAL_WORD_SIZE, LICENCE_SEAL_WORD_TRACK)
	if w <= LICENCE_SEAL_WORD_MOST { return LICENCE_SEAL_WORD_SIZE }
	return LICENCE_SEAL_WORD_SIZE * LICENCE_SEAL_WORD_MOST / w
}

// The seal's lettering: `word` centred, then the tick (added by the chore), raised. False: the face gives no outlines here. On
// the interface's thread.
@(private)
engrave_seal :: proc(fs: ^font.State, faces: Engrave_Faces, word: string, in_: ^Engrave_Input) -> bool {
	in_.w, in_.h, in_.steep, in_.tick = LICENCE_SEAL_TEX, LICENCE_SEAL_TEX, SEAL_BEVEL_K, true
	size := seal_word_size(fs, faces.bold, word)
	w := engrave_width(fs, faces.bold, word, size, LICENCE_SEAL_WORD_TRACK) - LICENCE_SEAL_WORD_TRACK * size
	return engrave_place(fs, faces.bold, in_, SEAL_SCALE, word, LICENCE_SEAL_DESIGN / 2 - w / 2, LICENCE_SEAL_WORD_BASELINE, size, LICENCE_SEAL_WORD_TRACK)
}
