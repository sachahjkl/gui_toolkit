package ui

import "core:math"
import turn "../turn"

// The relief of the licence card (licence_card.odin, licence_card.wgsl): a height field engraved like a banknote, turned into a
// NORMAL MAP the shader lights. Made on a chore (ui.task: the costly part of the card), uploaded to a texture of the renderer;
// nothing of it stays on the CPU.
//
// What is engraved (u in [0, 1.586], v in [0, 1], the card's units, 1 = its height):
//  - a guilloche: two rosettes of wavy concentric rings (the pattern of the notes' backgrounds), fading into each other;
//  - a frame: a rounded lip that rises to the edge, with a bevel, and a groove running inside it;
//  - micro-lettering: the product's name repeated in the frame along the top and the bottom edges, 7 texels tall, cut into the
//    lip as the microprint of a note is (a 5 x 7 face, two texels to a dot: only a tilt that rakes the light finds it);
//  - a grain: fine hash noise on everything, the tooth of the foil (the highlights need it).
//
// The texture is RGBA8, 2x the size the card shows at 100 % (880 x 556 for the 440 x 277 design), and its channels are the data
// the shader reads, not a colour:
//     R, G   the normal's x and y (tangent space, y down like the card), 128 = 0; z is rebuilt by the shader
//     B      the height, 0 (deepest) to 255 (the top of the lip)
//     A      the cavity: how much the point lies below its surroundings (the engraving's lines are dark)

@(private) LICENCE_RELIEF_W :: 880
@(private) LICENCE_RELIEF_H :: 556
// The licence card's width over its height: a bank card's (ISO/IEC 7810 ID-1).
LICENCE_CARD_ASPECT :: 1.586

// How steep the engraving is made (the height field has no unit: this scales its slopes into normals).
@(private = "file") SLOPE :: 2.0
// The cavity's box: 13 x 13 texels, in two passes.
@(private = "file") BLUR_R :: 6

// The micro-lettering's face: 5 x 7 dots for the letters and the digits (a name's other characters are a gap).
@(private = "file", rodata)
MICRO_GLYPHS := [36][7]string{
	{".XXX.", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X"},   // A
	{"XXXX.", "X...X", "X...X", "XXXX.", "X...X", "X...X", "XXXX."},
	{".XXX.", "X...X", "X....", "X....", "X....", "X...X", ".XXX."},
	{"XXXX.", "X...X", "X...X", "X...X", "X...X", "X...X", "XXXX."},
	{"XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "XXXXX"},
	{"XXXXX", "X....", "X....", "XXXX.", "X....", "X....", "X...."},
	{".XXX.", "X...X", "X....", "X.XXX", "X...X", "X...X", ".XXXX"},
	{"X...X", "X...X", "X...X", "XXXXX", "X...X", "X...X", "X...X"},
	{".XXX.", "..X..", "..X..", "..X..", "..X..", "..X..", ".XXX."},
	{"..XXX", "...X.", "...X.", "...X.", "...X.", "X..X.", ".XX.."},
	{"X...X", "X..X.", "X.X..", "XX...", "X.X..", "X..X.", "X...X"},
	{"X....", "X....", "X....", "X....", "X....", "X....", "XXXXX"},
	{"X...X", "XX.XX", "X.X.X", "X.X.X", "X...X", "X...X", "X...X"},
	{"X...X", "X...X", "XX..X", "X.X.X", "X..XX", "X...X", "X...X"},
	{".XXX.", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX."},
	{"XXXX.", "X...X", "X...X", "XXXX.", "X....", "X....", "X...."},
	{".XXX.", "X...X", "X...X", "X...X", "X.X.X", "X..X.", ".XX.X"},
	{"XXXX.", "X...X", "X...X", "XXXX.", "X.X..", "X..X.", "X...X"},
	{".XXXX", "X....", "X....", ".XXX.", "....X", "....X", "XXXX."},
	{"XXXXX", "..X..", "..X..", "..X..", "..X..", "..X..", "..X.."},
	{"X...X", "X...X", "X...X", "X...X", "X...X", "X...X", ".XXX."},
	{"X...X", "X...X", "X...X", "X...X", "X...X", ".X.X.", "..X.."},
	{"X...X", "X...X", "X...X", "X.X.X", "X.X.X", "XX.XX", "X...X"},
	{"X...X", "X...X", ".X.X.", "..X..", ".X.X.", "X...X", "X...X"},
	{"X...X", "X...X", ".X.X.", "..X..", "..X..", "..X..", "..X.."},
	{"XXXXX", "....X", "...X.", "..X..", ".X...", "X....", "XXXXX"},   // Z
	{".XXX.", "X...X", "X..XX", "X.X.X", "XX..X", "X...X", ".XXX."},   // 0
	{"..X..", ".XX..", "..X..", "..X..", "..X..", "..X..", ".XXX."},
	{".XXX.", "X...X", "....X", "...X.", "..X..", ".X...", "XXXXX"},
	{"XXXXX", "...X.", "..X..", "...X.", "....X", "X...X", ".XXX."},
	{"...X.", "..XX.", ".X.X.", "X..X.", "XXXXX", "...X.", "...X."},
	{"XXXXX", "X....", "XXXX.", "....X", "....X", "X...X", ".XXX."},
	{"..XX.", ".X...", "X....", "XXXX.", "X...X", "X...X", ".XXX."},
	{"XXXXX", "....X", "...X.", "..X..", ".X...", ".X...", ".X..."},
	{".XXX.", "X...X", "X...X", ".XXX.", "X...X", "X...X", ".XXX."},
	{".XXX.", "X...X", "X...X", ".XXXX", "....X", "...X.", ".XX.."},   // 9
}

// Texels per dot, columns per letter (5 and a gap), the gap after the word, in columns.
@(private = "file") DOT :: 2
@(private = "file") PITCH :: 6
@(private = "file") WORD_GAP :: 3
// The longest word the lip carries (a longer name is cut: microprint is a texture, not a sentence).
@(private = "file") MICRO_MOST :: 24

// The glyph of a byte of the name: 0 .. 35, or -1 (a gap).
@(private = "file")
micro_glyph :: proc(c: u8) -> int {
	switch c {
	case 'A' ..= 'Z': return int(c - 'A')
	case 'a' ..= 'z': return int(c - 'a')
	case '0' ..= '9': return 26 + int(c - '0')
	}
	return -1
}

// The relief's inputs: the name of the microprint, and for the back the height of what is raised on it (LICENCE_RELIEF_W x
// LICENCE_RELIEF_H, 0 .. 1; nil: the front).
@(private)
Relief_Input :: struct {
	word:   string,
	emboss: []f32,
}

// Whether texel (x, y) of a band of micro-lettering is a dot of the word. `x`: texels from the start of the line.
@(private = "file")
letter_dot :: proc(word: []int, x, y: int) -> bool {
	if len(word) == 0 || x < 0 || y < 0 || y >= 7 * DOT { return false }
	span := len(word) * PITCH + WORD_GAP
	col := (x / DOT) % span
	if col >= len(word) * PITCH { return false }
	c, within := col / PITCH, col % PITCH
	if within >= 5 || word[c] < 0 { return false }
	return MICRO_GLYPHS[word[c]][y / DOT][within] == 'X'
}

@(private = "file")
hash2 :: proc(x, y: int) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h & 0xffff) / 65535
}

// The height of the engraving at a texel (the pattern above, without the grain).
@(private = "file")
height_at :: proc(word: []int, x, y: int) -> f32 {
	u := (f32(x) + 0.5) / LICENCE_RELIEF_H
	v := (f32(y) + 0.5) / LICENCE_RELIEF_H
	ring :: proc(u, v, cx, cy, rings, wobble, lobes, phase: f32) -> (h, w: f32) {
		dx, dy := u - cx, v - cy
		r := math.sqrt(dx * dx + dy * dy)
		// (`wobble` and `phase` are radians: the pattern's numbers as designed)
		a := turn.atan2(dy, dx)
		h = turn.sin(rings * r + turn.from_radians(wobble * turn.sin(lobes * a + turn.from_radians(phase))))
		w = math.exp(-r * r / 0.30)
		return
	}
	h1, w1 := ring(u, v, 0.46, 0.50, 58, 3.2, 9, 1.3)
	h2, w2 := ring(u, v, 1.22, 0.64, 46, 2.4, 7, 0.4)
	h := (h1 * w1 + h2 * w2) / (w1 + w2 + 0.05) * 0.30
	edge := min(min(u, LICENCE_CARD_ASPECT - u), min(v, 1 - v))
	// the lip: a rounded rise to the edge
	bevel := 1 - clamp(edge / 0.04, 0, 1)
	h += bevel * bevel * 1.8
	// the groove inside the lip
	g := (edge - 0.055) / 0.006
	h -= 0.55 * math.exp(-g * g)
	// the micro-lettering, cut into the lip along the top and the bottom edges (clear of the corners' radius)
	if u > 0.075 && u < LICENCE_CARD_ASPECT - 0.075 {
		band :: 8     // texels from the edge to the first row of the lettering (0.0135 of the height)
		start :: 42   // and from the left edge to the first letter
		if letter_dot(word, x - start, y - band) || letter_dot(word, x - start + 3 * DOT, (LICENCE_RELIEF_H - 1 - y) - band) { h -= 0.7 }
	}
	return h
}

// The relief of the card, or of its back when `in.emboss` holds the figure raised on it: LICENCE_RELIEF_W x LICENCE_RELIEF_H
// texels of RGBA8 (see above), in `allocator`. The same bytes every time for the same input. Runs on a chore.
@(private)
relief_map :: proc(in_: Relief_Input, allocator := context.allocator) -> []u8 {
	W, H :: LICENCE_RELIEF_W, LICENCE_RELIEF_H
	word := make([]int, min(len(in_.word), MICRO_MOST))
	defer delete(word)
	for i in 0 ..< len(word) { word[i] = micro_glyph(in_.word[i]) }
	hf := make([]f32, W * H)
	defer delete(hf)
	tmp := make([]f32, W * H)
	defer delete(tmp)
	blur := make([]f32, W * H)
	defer delete(blur)
	for y in 0 ..< H {
		for x in 0 ..< W {
			h := height_at(word, x, y)
			if in_.emboss != nil {
				// the other face of a struck piece: what stands out on the front is hollow here, and the guilloche is calmed
				// where the raised figure stands (LICENCE_BACK_RELIEF tall, its bevel the blur of the figure's mask)
				e := in_.emboss[y * W + x]
				h = -h * (1 - clamp(2 * e, 0, 1)) + LICENCE_BACK_RELIEF * e
			}
			hf[y * W + x] = h + (hash2(x, y) - 0.5) * 0.10   // the grain
		}
	}
	// (the back carries the hunt's code, cut through its guilloche: licence_card_back.odin)
	if in_.emboss != nil { seal_engrave(hf) }
	for y in 0 ..< H {
		for x in 0 ..< W {
			s: f32
			for k in -BLUR_R ..= BLUR_R { s += hf[y * W + clamp(x + k, 0, W - 1)] }
			tmp[y * W + x] = s / (2 * BLUR_R + 1)
		}
	}
	for y in 0 ..< H {
		for x in 0 ..< W {
			s: f32
			for k in -BLUR_R ..= BLUR_R { s += tmp[clamp(y + k, 0, H - 1) * W + x] }
			blur[y * W + x] = s / (2 * BLUR_R + 1)
		}
	}
	lo, hi: f32 = 1e9, -1e9
	for h in hf { lo, hi = min(lo, h), max(hi, h) }
	out := make([]u8, W * H * 4, allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			xm, xp := max(x - 1, 0), min(x + 1, W - 1)
			ym, yp := max(y - 1, 0), min(y + 1, H - 1)
			// a 3 x 3 Sobel: the grain would make a one-texel difference too rough to light
			gx := (hf[ym * W + xp] + 2 * hf[y * W + xp] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[y * W + xm] - hf[yp * W + xm]) / (8 * f32(xp - xm) * 0.5)
			gy := (hf[yp * W + xm] + 2 * hf[yp * W + x] + hf[yp * W + xp] - hf[ym * W + xm] - 2 * hf[ym * W + x] - hf[ym * W + xp]) / (8 * f32(yp - ym) * 0.5)
			nx, ny := -gx * SLOPE, -gy * SLOPE
			inv := 1 / math.sqrt(nx * nx + ny * ny + 1)
			i := (y * W + x) * 4
			out[i + 0] = u8(clamp(128 + nx * inv * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * inv * 127, 0, 255))
			out[i + 2] = u8(clamp((hf[y * W + x] - lo) / (hi - lo) * 255, 0, 255))
			out[i + 3] = u8(clamp((blur[y * W + x] - hf[y * W + x]) * 2.4 * 255, 0, 255))
		}
	}
	return out
}

// A box blur of `field` (w x h) in place: `radius` texels, `passes` times in both directions (two passes: a smooth bevel).
@(private)
licence_box_blur :: proc(field: []f32, w, h, radius, passes: int) {
	tmp := make([]f32, w * h)
	defer delete(tmp)
	for _ in 0 ..< passes {
		for y in 0 ..< h {
			for x in 0 ..< w {
				s: f32
				for k in -radius ..= radius { s += field[y * w + clamp(x + k, 0, w - 1)] }
				tmp[y * w + x] = s / f32(2 * radius + 1)
			}
		}
		for y in 0 ..< h {
			for x in 0 ..< w {
				s: f32
				for k in -radius ..= radius { s += tmp[clamp(y + k, 0, h - 1) * w + x] }
				field[y * w + x] = s / f32(2 * radius + 1)
			}
		}
	}
}
