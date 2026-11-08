// The toolkit's logo and the icon made from it, drawn by the paint package (src/paint) on any system.
package tk

import "core:fmt"
import "core:os"
import paint "../../src/paint"

// Drawn 4 times larger, then made 512 px.
LOGO_SUPERSAMPLE :: 4
// The cobalt rounded square: lighter at the top, deeper at the bottom; a darker border just inside its edge (also a gradient, so it
// stays darker than the body everywhere); a faint highlight along the top inner edge.
LOGO_BOX_AT :: 56
LOGO_BOX_SIZE :: 400
LOGO_BOX_RADIUS :: 100
LOGO_BORDER :: 10
LOGO_HIGHLIGHT_WIDTH :: 2
LOGO_BODY_TOP :: 0x2F6FD8
LOGO_BODY_BOTTOM :: 0x0B3F9C
LOGO_EDGE_TOP :: 0x1A4FAE
LOGO_EDGE_BOTTOM :: 0x062A6E
LOGO_HIGHLIGHT_ALPHA :: 0x28
// A white switch (on), its knob a hole that shows the body; below it a white slider, its knob with a hole.
SWITCH_TRACK :: [5]f32{136, 150, 240, 104, 52}   // x, y, width, height, radius
SWITCH_KNOB :: [3]f32{324, 202, 38}               // centre, radius
SLIDER_TRACK :: [5]f32{136, 326, 240, 30, 15}
SLIDER_KNOB :: [3]f32{222, 341, 40}
SLIDER_HOLE :: 18

// The logo, LOGO_PIXELS square.
draw_logo :: proc(allocator := context.allocator) -> paint.Canvas {
	S :: LOGO_SUPERSAMPLE
	big := paint.canvas_make(LOGO_PIXELS * S, LOGO_PIXELS * S)
	defer paint.canvas_destroy(&big)
	// (the committed pictures were GDI+'s: this puts the shapes where it put them)
	big.transform = paint.scale(paint.translate(paint.IDENTITY, paint.GDIPLUS_OFFSET, paint.GDIPLUS_OFFSET), S, S)

	top, bottom := [2]f32{0, LOGO_BOX_AT}, [2]f32{0, LOGO_BOX_AT + LOGO_BOX_SIZE}
	body := paint.linear(top, bottom, paint.hex(LOGO_BODY_TOP), paint.hex(LOGO_BODY_BOTTOM), .Repeat)
	edge := paint.linear(top, bottom, paint.hex(LOGO_EDGE_TOP), paint.hex(LOGO_EDGE_BOTTOM), .Repeat)
	white := paint.solid(paint.hex(0xFFFFFF))

	round_rect :: proc(c: ^paint.Canvas, p: paint.Paint, r: [5]f32, pen: f32 = 0) {
		path: paint.Path
		defer paint.path_destroy(&path)
		paint.round_rect(&path, r[0], r[1], r[2], r[3], r[4])
		if pen > 0 { paint.stroke(c, path, {width = pen}, p) } else { paint.fill(c, path, p) }
	}
	circle :: proc(c: ^paint.Canvas, p: paint.Paint, k: [3]f32, r: f32) {
		path: paint.Path
		defer paint.path_destroy(&path)
		paint.ellipse(&path, k.x - r, k.y - r, 2 * r, 2 * r)
		paint.fill(c, path, p)
	}
	B :: f32(LOGO_BORDER)
	round_rect(&big, body, {LOGO_BOX_AT, LOGO_BOX_AT, LOGO_BOX_SIZE, LOGO_BOX_SIZE, LOGO_BOX_RADIUS})
	round_rect(&big, edge, {LOGO_BOX_AT + B / 2, LOGO_BOX_AT + B / 2, LOGO_BOX_SIZE - B, LOGO_BOX_SIZE - B, LOGO_BOX_RADIUS - B / 2}, B)
	round_rect(&big, paint.solid(paint.hex(0xFFFFFF, LOGO_HIGHLIGHT_ALPHA)), {LOGO_BOX_AT + B + 1, LOGO_BOX_AT + B + 1, LOGO_BOX_SIZE - 2 * B - 2, LOGO_BOX_SIZE - 2 * B - 2, LOGO_BOX_RADIUS - B}, LOGO_HIGHLIGHT_WIDTH)
	round_rect(&big, white, SWITCH_TRACK)
	circle(&big, body, SWITCH_KNOB, SWITCH_KNOB.z)
	round_rect(&big, white, SLIDER_TRACK)
	circle(&big, white, SLIDER_KNOB, SLIDER_KNOB.z)
	circle(&big, body, SLIDER_KNOB, SLIDER_HOLE)
	return paint.resize(big, LOGO_PIXELS, LOGO_PIXELS, .Cubic, allocator)
}

// The logo `png` cropped to its rounded square and drawn at each size, as PNG files.
icon_pngs :: proc(png: string, sizes: []int) -> (pngs: [][]byte, why: string) {
	data, err := os.read_entire_file(png, context.temp_allocator)
	if err != nil { return nil, fmt.tprintf("%s cannot be read", png) }
	logo, ok := paint.png_decode(data)
	if !ok { return nil, fmt.tprintf("%s is not a PNG file of 8 bits", png) }
	defer paint.canvas_destroy(&logo)
	pngs = make([][]byte, len(sizes))
	for s, i in sizes {
		icon := paint.canvas_make(s, s)
		paint.draw_canvas(&icon, logo, {0, 0, s, s}, {ICON_CROP_AT, ICON_CROP_AT, ICON_CROP_SIZE, ICON_CROP_SIZE})
		pngs[i] = paint.png_encode(icon)
		paint.canvas_destroy(&icon)
	}
	return pngs, ""
}
