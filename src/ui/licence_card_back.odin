package ui

import "base:runtime"
import "core:math"
import "../font"

// The back of the licence card: what the card shows when it is turned over. It is the same foil as the front, struck from the
// other side:
//
//  - the relief is the front's turned inside out, as the other face of a struck piece is: the lip that stands out of the front
//    is a trough here, the guilloche's ridges are furrows and its furrows ridges, the micro-lettering stands up in the frame;
//    the grain is the same (licence_card_relief.odin, relief_map with an `emboss` field);
//  - in the middle, the program's logo RAISED out of the foil, big and quiet: the height of the figure (logo_height_field) is
//    the logo's own picture, its silhouette (its alpha) a plateau and its light parts standing higher, softened for the bevel;
//  - along the bottom, a line of lettering raised like the front's, in silver (Licence_Card.back_line: the vendor's name, never
//    the person's: nothing of the person is on this side).

// How tall the figure stands, in the units of the relief's height field (the front's lip is 1.8).
@(private) LICENCE_BACK_RELIEF :: 1.7
// The logo is drawn at most LICENCE_BACK_LOGO units wide and high (its aspect kept) with its middle LICENCE_BACK_LOGO_LIFT
// units above the card's, on the 440 wide design.
@(private = "file") LICENCE_BACK_LOGO :: 196.0
@(private = "file") LICENCE_BACK_LOGO_LIFT :: 8.0
@(private = "file") BACK_BEVEL_R :: 4   // the box blur (radius, two passes) that makes the figure's bevel, texels (2 to a unit)
// How high the plateau of the silhouette stands, and how much higher its lightest parts go (the white of a mark on its tile).
@(private = "file") BACK_PLATEAU :: 0.55

// The line along the bottom: size and tracking (units, em), its baseline from the top of the design.
@(private) LICENCE_BACK_TEXT_SIZE :: 10.0
@(private) LICENCE_BACK_TEXT_TRACK :: 0.28
@(private) LICENCE_BACK_TEXT_BASELINE :: 252.0

@(private = "file")
smooth_step :: proc(a, b, x: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

// The raised figure on the back: LICENCE_RELIEF_W x LICENCE_RELIEF_H values in 0 .. 1 (1 on the flat top of the figure, falling
// to 0 over its bevel) from the logo's straight RGBA pixels (w x h); all zero without them. In the heap. On a chore.
@(private)
logo_height_field :: proc(rgba: []u8, w, h: int) -> []f32 {
	context.allocator = runtime.heap_allocator()
	W, H :: LICENCE_RELIEF_W, LICENCE_RELIEF_H
	field := make([]f32, W * H)
	if w <= 0 || h <= 0 || len(rgba) < w * h * 4 { return field }
	mask := make([]f32, w * h)
	defer delete(mask)
	for i in 0 ..< w * h {
		r, g, b, a := f32(rgba[i * 4]), f32(rgba[i * 4 + 1]), f32(rgba[i * 4 + 2]), f32(rgba[i * 4 + 3])
		light := smooth_step(0.45, 0.9, min(r, min(g, b)) / 255)
		mask[i] = (a / 255) * (BACK_PLATEAU + (1 - BACK_PLATEAU) * light)
	}
	texels_per_unit := f32(W) / 440
	cx, cy := f32(440) / 2, 440 / f32(LICENCE_CARD_ASPECT) / 2 - LICENCE_BACK_LOGO_LIFT
	// (the picture's pixels per unit of the design: the larger side fits the figure's room)
	units_per_px := LICENCE_BACK_LOGO / f32(max(w, h))
	at :: proc(mask: []f32, w, h, x, y: int) -> f32 {
		if x < 0 || y < 0 || x >= w || y >= h { return 0 }
		return mask[y * w + x]
	}
	for y in 0 ..< H {
		for x in 0 ..< W {
			u := ((f32(x) + 0.5) / texels_per_unit - cx) / units_per_px + f32(w) / 2 - 0.5
			v := ((f32(y) + 0.5) / texels_per_unit - cy) / units_per_px + f32(h) / 2 - 0.5
			x0, y0 := int(math.floor(u)), int(math.floor(v))
			fx, fy := u - f32(x0), v - f32(y0)
			field[y * W + x] = (at(mask, w, h, x0, y0) * (1 - fx) + at(mask, w, h, x0 + 1, y0) * fx) * (1 - fy) +
				(at(mask, w, h, x0, y0 + 1) * (1 - fx) + at(mask, w, h, x0 + 1, y0 + 1) * fx) * fy
		}
	}
	licence_box_blur(field, W, H, BACK_BEVEL_R, 2)
	for &v in field { v = clamp(v, 0, 1) }
	return field
}

// The lettering of the back: `text` centred along the bottom, raised. False: the face gives no outlines here. On the
// interface's thread.
@(private)
engrave_back :: proc(fs: ^font.State, faces: Engrave_Faces, text: string, in_: ^Engrave_Input) -> bool {
	in_.w, in_.h = LICENCE_ENGRAVE_W, LICENCE_ENGRAVE_H
	w := engrave_width(fs, faces.bold, text, LICENCE_BACK_TEXT_SIZE, LICENCE_BACK_TEXT_TRACK) - LICENCE_BACK_TEXT_TRACK * LICENCE_BACK_TEXT_SIZE
	return engrave_place(fs, faces.bold, in_, LICENCE_ENGRAVE_SCALE, text, 220 - w / 2, LICENCE_BACK_TEXT_BASELINE, LICENCE_BACK_TEXT_SIZE, LICENCE_BACK_TEXT_TRACK)
}
