package ui

import "base:runtime"
import "core:math"
import "../font"

// The text of the licence card, RAISED: instead of plain text over the foil, the product, the edition, the name, the e-mail, the
// date and the order stand out of the metal like the embossed lettering of a bank card. Their glyphs' outlines are taken on the
// interface's thread (font.glyph_outline: the font state is that thread's; a few dozen glyphs), then filled by the toolkit's
// software rasterizer (font.colr_cover: the same shapes on every system) into a coverage field on a chore, at 3 texels per unit
// of the 440 wide design; a short blur of that field is the height of the lettering, and its gradient the normals of a real
// bevel (the same helpers raise the word and the tick of the seal: licence_card_seal.odin, and the back's line).
//
// The texture is RGBA8 (data), LICENCE_ENGRAVE_W x LICENCE_ENGRAVE_H over the whole card:
//     R, G   the normal of the bevel (x, y, y down), 128 = flat: the top of a letter is flat, its flanks slope outwards
//     B      the coverage of the letters (255 inside)
//     A      the blurred coverage, the height of the letters: 255 on the top of a wide stroke, less towards its edge

@(private) LICENCE_ENGRAVE_W :: 1320
@(private) LICENCE_ENGRAVE_H :: 832
// Texels per unit of the 440 wide design.
@(private) LICENCE_ENGRAVE_SCALE :: 3.0
// The box blur (radius, two passes) that makes the bevel: about 1.3 units wide at 3 texels to a unit; how steep the flanks are
// made (the steepest slope of a blurred edge is 1 / (2 * BEVEL_R) a texel).
@(private = "file") BEVEL_R :: 2
@(private = "file") BEVEL_K :: 5.0
// How far a glyph's curves may stray from their outline (texels), and the coverage samples per texel row (font.colr_cover:
// across a row it is exact).
@(private = "file") FLATNESS_TEXELS :: 0.05
@(private = "file") SAMPLES :: 4

// One glyph to fill: its outline (em units, y up; the heap's) and the map from em units to texels.
@(private)
Engrave_Shape :: struct {
	outline: font.Outline,
	m:       font.Mat,
}

// What a chore raises: the glyphs, the field's size, how steep the bevel is, and a stroke to add (the seal's tick).
@(private)
Engrave_Input :: struct {
	shapes: [dynamic]Engrave_Shape,   // the heap's
	w, h:   int,
	steep:  f32,
	tick:   bool,
}

@(private)
engrave_input_destroy :: proc(in_: ^Engrave_Input) {
	context.allocator = runtime.heap_allocator()
	for &sh in in_.shapes { font.outline_destroy(&sh.outline) }
	delete(in_.shapes)
	in_^ = {}
}

// The text's glyphs, shaped with `face` at `size` units (`track` em of letter spacing) on the baseline `baseline`, from `x` (its
// left edge, or its right one when `right`), `scale` texels to a unit: their outlines added to `in_`. On the interface's thread.
// False: the face has no outlines here (the backend gives none): the text cannot be raised.
@(private)
engrave_place :: proc(fs: ^font.State, face: font.Font_Id, in_: ^Engrave_Input, scale: f32, text: string, x, baseline, size, track: f32, right := false) -> bool {
	if text == "" { return true }
	heap := runtime.heap_allocator()
	if in_.shapes == nil { in_.shapes = make([dynamic]Engrave_Shape, heap) }
	em := size * scale
	sh := font.shape(fs, face, em, text, {letter_spacing = track * em}, context.temp_allocator)
	x0 := x * scale - (right ? sh.width - track * em : 0)
	y0 := math.round(baseline * scale)
	for g in sh.glyphs {
		o: font.Outline
		o.quads = make([dynamic]font.Quad, heap)
		o.ends = make([dynamic]int, heap)
		if !font.glyph_outline(fs, g.face, g.id, FLATNESS_TEXELS / em, &o) {
			font.outline_destroy(&o)
			return false
		}
		if len(o.quads) == 0 { font.outline_destroy(&o); continue }   // (a space)
		append(&in_.shapes, Engrave_Shape{outline = o, m = font.Mat{em, 0, 0, -em, x0 + g.x, y0 + g.y}})
	}
	return true
}

// The width of `text` at `size` units with `track` em of letter spacing (the last letter's spacing included).
@(private)
engrave_width :: proc(fs: ^font.State, face: font.Font_Id, text: string, size, track: f32) -> f32 {
	if text == "" { return 0 }
	return font.measure(fs, face, size, text, {letter_spacing = track * size})
}

// The raised texture of `in_` (in.w x in.h RGBA8, the channels above), in the heap. On a chore.
@(private)
engrave_make :: proc(in_: ^Engrave_Input) -> []u8 {
	W, H := in_.w, in_.h
	heap := runtime.heap_allocator()
	cov := make([]f32, W * H, heap)
	defer delete(cov, heap)
	for &sh in in_.shapes {
		rect, part, ok := font.colr_cover(&sh.outline, sh.m, {0, 0, W, H}, SAMPLES, heap)
		if !ok { continue }
		w := rect[2] - rect[0]
		for y in rect[1] ..< rect[3] {
			for x in rect[0] ..< rect[2] {
				cov[y * W + x] = max(cov[y * W + x], part[(y - rect[1]) * w + (x - rect[0])])
			}
		}
		delete(part, heap)
	}
	if in_.tick { seal_tick_cover(cov, W, H) }
	return engrave_raise(cov, W, H, in_.steep > 0 ? in_.steep : BEVEL_K)
}

// The texture of raised lettering from a coverage field: the height is the coverage blurred (a box of 2 * BEVEL_R + 1, twice,
// in both directions), its slopes the bevel. The surface is RAISED where the letters are: its normal is (-dh/dx, -dh/dy, 1),
// so a flank facing up-left tilts up-left. Does not keep `cov`; the result is the heap's.
@(private = "file")
engrave_raise :: proc(cov: []f32, W, H: int, steep: f32) -> []u8 {
	heap := runtime.heap_allocator()
	h := make([]f32, W * H, heap)
	defer delete(h, heap)
	copy(h, cov)
	{
		context.allocator = heap
		licence_box_blur(h, W, H, BEVEL_R, 2)
	}
	out := make([]u8, W * H * 4, heap)
	for y in 0 ..< H {
		for x in 0 ..< W {
			xm, xp := max(x - 1, 0), min(x + 1, W - 1)
			ym, yp := max(y - 1, 0), min(y + 1, H - 1)
			gx := (h[ym * W + xp] + 2 * h[y * W + xp] + h[yp * W + xp] - h[ym * W + xm] - 2 * h[y * W + xm] - h[yp * W + xm]) / (8 * f32(xp - xm) * 0.5)
			gy := (h[yp * W + xm] + 2 * h[yp * W + x] + h[yp * W + xp] - h[ym * W + xm] - 2 * h[ym * W + x] - h[ym * W + xp]) / (8 * f32(yp - ym) * 0.5)
			nx, ny := -gx * steep, -gy * steep
			inv := 1 / math.sqrt(nx * nx + ny * ny + 1)
			i := (y * W + x) * 4
			out[i + 0] = u8(clamp(128 + nx * inv * 127, 0, 255))
			out[i + 1] = u8(clamp(128 + ny * inv * 127, 0, 255))
			out[i + 2] = u8(clamp(cov[y * W + x] * 255, 0, 255))
			out[i + 3] = u8(clamp(h[y * W + x] * 255, 0, 255))
		}
	}
	return out
}

// The faces the card's text is set in: the interface's, and its bold (ui.styled_face: the family's own, else simulated).
@(private)
Engrave_Faces :: struct {
	regular, bold: font.Font_Id,
}

// The front's lettering on the 440 x 277 design (the logo at the top left, the edition at the top right, the name and the
// e-mail in the middle, the date and the order at the bottom left, the seal at the bottom right). False: the faces give no
// outlines here. On the interface's thread.
@(private)
engrave_front :: proc(fs: ^font.State, faces: Engrave_Faces, c: Licence_Card, in_: ^Engrave_Input) -> bool {
	in_.w, in_.h = LICENCE_ENGRAVE_W, LICENCE_ENGRAVE_H
	k :: LICENCE_ENGRAVE_SCALE
	b := faces.bold
	l := licence_card_layout(fs, faces, c)
	engrave_place(fs, b, in_, k, c.product, l.product.x, l.product.y, LICENCE_PRODUCT_SIZE, LICENCE_PRODUCT_TRACK) or_return
	engrave_place(fs, b, in_, k, licence_upper(c.edition), l.edition.x, l.edition.y, LICENCE_EDITION_SIZE, LICENCE_EDITION_TRACK, right = true) or_return
	engrave_place(fs, b, in_, k, c.name, l.name.x, l.name.y, l.name_size, 0) or_return
	engrave_place(fs, b, in_, k, c.email, l.email.x, l.email.y, LICENCE_EMAIL_SIZE, 0) or_return
	for m in l.meta[:l.metas] {
		engrave_place(fs, b, in_, k, m.label, m.at.x, LICENCE_META_LABEL_Y, LICENCE_META_LABEL_SIZE, LICENCE_META_LABEL_TRACK) or_return
		engrave_place(fs, b, in_, k, m.value, m.at.x, LICENCE_META_VALUE_Y, LICENCE_META_VALUE_SIZE, 0) or_return
	}
	return true
}
