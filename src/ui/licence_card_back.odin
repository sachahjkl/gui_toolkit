package ui

import "base:runtime"
import "core:math"
import "../draw"
import "../font"
import "../qr"
import turn "../turn"

// The back of the licence card: what the card shows when it is turned over. It is the same foil as the front, struck from the
// other side:
//
//  - the relief is the front's turned inside out, as the other face of a struck piece is: the lip that stands out of the front
//    is a trough here, the guilloche's ridges are furrows and its furrows ridges, the micro-lettering stands up in the frame;
//    the grain is the same (licence_card_relief.odin, relief_map with an `emboss` field);
//  - in the middle, the program's logo RAISED out of the foil, big and quiet: the height of the figure (logo_height_field) is
//    the logo's own picture, its silhouette (its alpha) a plateau and its light parts standing higher, softened for the bevel;
//  - along the bottom, a line of lettering raised like the front's, in silver (Licence_Card.back_line: the vendor's name, never
//    the person's: nothing of the person is on this side);
//  - at the bottom right, a QR code cut into the foil (the seal below: src/md/features/licence-card.md, The engraved code).

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

////////////////////////////////
// The seal: the engraved code

// Where the code leads: the first step of the hunt across the programs. It must match the token of the site's hunt
// (froment.software, docs/intent/features/filigrane.md): a change on one side is a change on the other. Every program's
// card carries the same code, since the hunt spans the programs: no program sets it.
LICENCE_CARD_SEAL_URL :: "https://froment.software/filigrane?sceau=gf1MDAWPoTGY"
// Its modules a side: the address in bytes at level Medium is version 4. The place on the back is made for this size: an
// address that needs another version engraves no code (seal_encode), and tests/licence_card fails.
LICENCE_CARD_SEAL_MODULES :: 33
@(private) LICENCE_SEAL_ECC :: qr.Ecc.Medium
// A module, in units of the 440 wide design (2 texels of the relief a unit: 4 x 4 texels, on whole texels), and the code's
// top left. With its quiet zone of qr.QUIET_ZONE modules the square is (340, 158) to (422, 240): clear of the logo's room,
// of the lip and its groove, and above the line of lettering.
@(private) LICENCE_SEAL_MODULE :: 2.0
@(private) LICENCE_SEAL_X :: 348.0
@(private) LICENCE_SEAL_Y :: 166.0
// How deep a dark module is cut: shallower than the guilloche's waves (0.30), so that straight on the pits read as one more
// texture of the foil. The guilloche runs on across the plate and into the pits: it is the camouflage straight on, and it
// shows faintly in the dark modules at the turn.
@(private = "file") SEAL_DEPTH :: 0.12
// The plate under the code: the quiet zone's square with the card's corner radius at the plate's scale (14 units on a card
// 277 high, the plate 82: about 4), lifted a little with a bevel of a unit, and a thin rim just inside its edge. Low, so that
// straight on it is a hint of something, not a shape a reader takes for a code.
@(private) LICENCE_SEAL_PLATE_R :: 4.0
@(private = "file") SEAL_PLATE_LIFT :: 0.08
@(private = "file") SEAL_RIM :: 0.22
// How each module is drawn, in modules (the relief and the shader both, from seal_params' numbers): a dark data module a
// rounded dot 2 * SEAL_DOT_HALF wide; a finder pattern a punch's hallmark, its outer ring and centre square rounded (their
// edges on the axes through the centre stay where the square ones were: 1:1:3:1:1 along every row and column).
@(private = "file") SEAL_DOT_HALF :: 0.45
@(private = "file") SEAL_DOT_R :: 0.22
@(private = "file") SEAL_RING_R :: 1.0
@(private = "file") SEAL_HOLE_R :: 0.5
@(private = "file") SEAL_CENTRE_R :: 0.5
// The turn that reveals the code (rotateX, rotateY, turns): the back turned about 0.03 turns (11°) on each axis, its top left
// corner towards the eye. Within SEAL_WHOLE of that turn's eye the code shows whole; past SEAL_GONE not at all (turns).
// Straight on, the eye is 0.042 turns (15°) from it.
@(private) LICENCE_SEAL_RX :: -11.0 / 360
@(private) LICENCE_SEAL_RY :: 191.0 / 360
@(private = "file") SEAL_WHOLE :: 3.0 / 360
@(private = "file") SEAL_GONE :: 7.0 / 360
// The matrix in the shader's parameters: 24 modules a float (an f32 holds an integer of 24 bits exactly), four floats a slot.
// The back's draw gives LICENCE_SEAL_HEAD slots of place, ramp and shapes, then these.
@(private) LICENCE_SEAL_WORDS :: (LICENCE_CARD_SEAL_MODULES * LICENCE_CARD_SEAL_MODULES + 23) / 24
@(private) LICENCE_SEAL_SLOTS :: (LICENCE_SEAL_WORDS + 3) / 4
@(private) LICENCE_SEAL_HEAD :: 5
@(private) LICENCE_SEAL_PARAMS :: LICENCE_SEAL_HEAD + LICENCE_SEAL_SLOTS
@(private) Seal_Bits :: [LICENCE_SEAL_SLOTS][4]f32

// The code as the card engraves it, in `allocator`; no modules when the address does not give LICENCE_CARD_SEAL_MODULES.
@(private)
seal_encode :: proc(allocator: runtime.Allocator) -> qr.Code {
	code, err := qr.encode(LICENCE_CARD_SEAL_URL, LICENCE_SEAL_ECC, allocator)
	if err != .None { return {} }
	if code.size != LICENCE_CARD_SEAL_MODULES { qr.destroy(&code, allocator); return {} }
	return code
}

// The matrix packed for the shader: module (x, y) is bit i % 24 of float i / 24, i = y * size + x; 1 is dark. All zero when
// there is no code.
@(private)
seal_pack :: proc() -> (bits: Seal_Bits) {
	heap := runtime.heap_allocator()
	code := seal_encode(heap)
	defer qr.destroy(&code, heap)
	if code.modules == nil { return }
	for dark, i in code.modules {
		if !dark { continue }
		w := i / 24
		bits[w / 4][w % 4] += f32(u32(1) << uint(i % 24))
	}
	return
}

// Whether module (x, y) of the packed matrix is dark (outside the code: light).
@(private)
seal_dark :: proc(bits: ^Seal_Bits, x, y: int) -> bool {
	n :: LICENCE_CARD_SEAL_MODULES
	if x < 0 || y < 0 || x >= n || y >= n { return false }
	i := y * n + x
	w := i / 24
	return (u32(bits[w / 4][w % 4]) >> uint(i % 24)) & 1 != 0
}

// Whether module (x, y) of the code engraved on the back is dark (outside the code: light), as the shader and the flat card
// read it: for a test or a tool.
licence_card_seal_module :: proc(x, y: int) -> bool {
	return seal_dark(kept_seal(), x, y)
}

// The eye's direction in the frame of the back turned by rotateX(rx) rotateY(ry), turns: x right, y down, z out of the
// face (licence_card.wgsl: to_face with `back`, of the eye (0, 0, 1)).
@(private = "file")
seal_eye :: proc(rx, ry: f32) -> [3]f32 {
	sx, cx := turn.sincos(rx)
	sy, cy := turn.sincos(ry)
	return {sy * cx, sx, -cy * cx}
}

// The cosines of the angles where the code is whole and where it is gone.
@(private = "file")
seal_cosines :: proc() -> (whole, gone: f32) {
	return turn.cos(f32(SEAL_WHOLE)), turn.cos(f32(SEAL_GONE))
}

// How much of the code's contrast the back shows turned by rotateX(rx) rotateY(ry), turns: 0, the foil alone; 1, its
// light modules polished silver on a brushed plate and its dark ones the foil's dark tone. The shader computes the same
// ramp from what seal_params gives it. For a test or a tool.
licence_card_seal_reveal :: proc(rx, ry: f32) -> f32 {
	e, t := seal_eye(rx, ry), seal_eye(LICENCE_SEAL_RX, LICENCE_SEAL_RY)
	whole, gone := seal_cosines()
	return smooth_step(gone, whole, e.x * t.x + e.y * t.y + e.z * t.z)
}

// The back's shader parameters of the code (LICENCE_SEAL_PARAMS slots, from slot 5 of its draw), `px_per_unit` the card's
// pixels per unit of the design (the width of an edge's smoothing):
//   0  the code's top left, a module and its modules a side (design units)
//   1  the eye of the turn that reveals it, the cosine of the angle where it is whole
//   2  the cosine where it is gone, the quiet zone (modules), the edge's half width (design units), the plate's corner radius
//   3  a dot's half width and corner radius, a finder's outer and inner ring radius (modules)
//   4  a finder's centre radius (modules)
//   5 ..  the matrix
// The shapes are numbers given here, not constants of the shader: the relief cuts the same shapes the light paints.
@(private)
seal_params :: proc(out: [][4]f32, px_per_unit: f32) {
	t := seal_eye(LICENCE_SEAL_RX, LICENCE_SEAL_RY)
	whole, gone := seal_cosines()
	out[0] = {LICENCE_SEAL_X, LICENCE_SEAL_Y, LICENCE_SEAL_MODULE, LICENCE_CARD_SEAL_MODULES}
	out[1] = {t.x, t.y, t.z, whole}
	// (about three quarters of a pixel each side: smooth at 100 %, still sharp at 200 %)
	out[2] = {gone, qr.QUIET_ZONE, 0.75 / max(px_per_unit, 0.25), LICENCE_SEAL_PLATE_R}
	out[3] = {SEAL_DOT_HALF, SEAL_DOT_R, SEAL_RING_R, SEAL_HOLE_R}
	out[4] = {SEAL_CENTRE_R, 0, 0, 0}
	bits := kept_seal()
	copy(out[LICENCE_SEAL_HEAD:], bits^[:])
}

// The signed distance from `p` to a square of half width `half` with corners of radius `r` about the origin: negative inside.
// (licence_card.wgsl: seal_box)
@(private = "file")
seal_box :: proc(p: [2]f32, half, r: f32) -> f32 {
	dx, dy := abs(p.x) - (half - r), abs(p.y) - (half - r)
	ox, oy := max(dx, 0), max(dy, 0)
	return math.sqrt(ox * ox + oy * oy) + min(max(dx, dy), 0) - r
}

// The signed distance from `q` (modules from the code's top left, inside the code) to the ink, in modules: negative on a
// dark dot or on a finder's ring or centre. A finder is drawn from its place, not from its bits (they are its pattern
// anyway); a data module from its bit. `dark` tells module (x, y). (licence_card.wgsl: seal_ink)
@(private = "file")
seal_ink :: proc(q: [2]f32, n: int, dark: proc(user: rawptr, x, y: int) -> bool, user: rawptr) -> f32 {
	fn := f32(n)
	o := [2]f32{-1, -1}
	if q.x < 7 && q.y < 7 {
		o = {0, 0}
	} else if q.x >= fn - 7 && q.y < 7 {
		o = {fn - 7, 0}
	} else if q.x < 7 && q.y >= fn - 7 {
		o = {0, fn - 7}
	}
	if o.x >= 0 {
		r := q - o - [2]f32{3.5, 3.5}
		ring := max(seal_box(r, 3.5, SEAL_RING_R), -seal_box(r, 2.5, SEAL_HOLE_R))
		return min(ring, seal_box(r, 1.5, SEAL_CENTRE_R))
	}
	x, y := int(q.x), int(q.y)
	if !dark(user, x, y) { return 1 }
	return seal_box(q - [2]f32{f32(x) + 0.5, f32(y) + 0.5}, SEAL_DOT_HALF, SEAL_DOT_R)
}

// The code engraved in the back's height field (LICENCE_RELIEF_W x LICENCE_RELIEF_H, the grain included): the plate lifted
// with its bevel and its rim, the ink cut as pits, through the guilloche. The shapes are the shader's (seal_ink): the light
// it paints at the turn falls on the same cells. On a chore.
@(private)
seal_engrave :: proc(hf: []f32) {
	heap := runtime.heap_allocator()
	code := seal_encode(heap)
	defer qr.destroy(&code, heap)
	if code.modules == nil { return }
	W :: LICENCE_RELIEF_W
	texels_per_unit :: f32(W) / 440
	n := code.size
	m := f32(LICENCE_SEAL_MODULE)
	quiet := f32(qr.QUIET_ZONE) * m
	half := f32(n) * m * 0.5 + quiet
	centre := [2]f32{LICENCE_SEAL_X, LICENCE_SEAL_Y} + f32(n) * m * 0.5
	// (half a texel of smoothing on each side of an edge, in modules)
	soft := 0.5 / texels_per_unit / m
	module_of :: proc(user: rawptr, x, y: int) -> bool { return qr.module((^qr.Code)(user)^, x, y) }
	lo_x, lo_y := int((centre.x - half - 2) * texels_per_unit), int((centre.y - half - 2) * texels_per_unit)
	hi_x, hi_y := int((centre.x + half + 2) * texels_per_unit), int((centre.y + half + 2) * texels_per_unit)
	for y in lo_y ..< hi_y {
		for x in lo_x ..< hi_x {
			p := [2]f32{(f32(x) + 0.5) / texels_per_unit, (f32(y) + 0.5) / texels_per_unit}
			dp := seal_box(p - centre, half, LICENCE_SEAL_PLATE_R)
			if dp > 2 { continue }
			rim := (dp + 0.75) / 0.5
			h := hf[y * W + x] + SEAL_PLATE_LIFT * (1 - smooth_step(-1, 0, dp)) + SEAL_RIM * math.exp(-rim * rim)
			q := (p - [2]f32{LICENCE_SEAL_X, LICENCE_SEAL_Y}) / m
			if q.x >= 0 && q.y >= 0 && q.x < f32(n) && q.y < f32(n) {
				ink := 1 - smooth_step(-soft, soft, seal_ink(q, n, module_of, &code))
				h -= SEAL_DEPTH * ink
			}
			hf[y * W + x] = h
		}
	}
}

// The code on the flat back (no shader): the plate a breath lighter than the ground, the ink a shade darker, in the shapes
// of the foil's. A few levels of grey: an eye that looks closely finds it, a reader takes it for no code (it shows only at
// its turn, on the foil). One rounded rectangle a dark module: about 550, a fixed cost while the flat back shows.
@(private)
seal_draw_flat :: proc(dc: ^draw.Context) {
	bits := kept_seal()
	n :: LICENCE_CARD_SEAL_MODULES
	m :: f32(LICENCE_SEAL_MODULE)
	at := Vec2{LICENCE_SEAL_X, LICENCE_SEAL_Y}
	quiet := f32(qr.QUIET_ZONE) * m
	draw.rect(dc, {at - quiet, at + n * m + quiet}, {1, 1, 1, 0.035}, LICENCE_SEAL_PLATE_R)
	ink :: draw.Color{0, 0, 0, 0.1}
	for o in ([3][2]int{{0, 0}, {n - 7, 0}, {0, n - 7}}) {
		c := at + Vec2{f32(o.x), f32(o.y)} * m
		// (an outline is drawn inside its rectangle, as the card's edge is)
		draw.rect(dc, {c, c + 7 * m}, ink, SEAL_RING_R * m, m)
		draw.rect(dc, {c + 2 * m, c + 5 * m}, ink, SEAL_CENTRE_R * m)
	}
	finder :: proc(x, y: int) -> bool { return (x < 7 && y < 7) || (x >= n - 7 && y < 7) || (x < 7 && y >= n - 7) }
	for y in 0 ..< n {
		for x in 0 ..< n {
			if finder(x, y) || !seal_dark(bits, x, y) { continue }
			c := at + (Vec2{f32(x), f32(y)} + 0.5) * m
			draw.rect(dc, {c - SEAL_DOT_HALF * m, c + SEAL_DOT_HALF * m}, ink, SEAL_DOT_R * m)
		}
	}
}
