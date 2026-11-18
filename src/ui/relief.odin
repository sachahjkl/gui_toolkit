package ui

// Relief as data (src/md/features/theme-design.md, layer 6): how raised and sunken surfaces are drawn, said by a
// `Relief`. A relief of rings (`extra = .None`) is drawn wholly from its data by the routines here: each ring has its
// width, the tone of its top and left sides and of its bottom and right sides (a step of the face toward white or
// black) and its blur. The finishes are the named presets (relief_of): each one's flags are its data, and what of its
// look does not reduce to rings is its `extra`, the code that draws it (machined.odin, draw_ui.odin, row_face.odin).
// A theme can give its own relief (Theme_Look.relief); it wins over the program's finish, as a theme's own finish does.

import "core:math"
import "../draw"

// The rings a relief draws around a surface, the outermost first; a ring of width 0 ends them.
RELIEF_RINGS :: 2

Relief_Ring :: struct {
	width:        f32,   // in device pixels of px1 (1: one pixel at any scale, rounded); 0: no ring
	top_left:     f32,   // the tone of its top and left sides: a step of the face toward white (> 0) or black (< 0)
	bottom_right: f32,   // the tone of its bottom and right sides
	blur:         f32,   // logical pixels; 0: crisp
}

Relief_Rings :: [RELIEF_RINGS]Relief_Ring

// What a finish draws by code of its own, beside or in place of rings: what of its look is not rings (blurred shadows,
// alphas of black and white over what is under, edges drawn as filled rounded shapes, glossy halves).
Relief_Extra :: enum u8 { None, Gradient, Glass, Machined, Edged }

// How a surface a widget paints itself (paint_rect: an accent fill, a raised face of the flat path) is lit.
Face_Paint :: enum u8 {
	Plain,    // a plain fill
	Lit,      // a lit face, softly (the gradient finish's)
	Strong,   // a lit face, a little stronger (the machined and edged finishes' accent fills)
	Gloss,    // a glossy upper half (glass)
}

// How a row's face (row_face.odin) is painted.
Row_Paint :: enum u8 { Plain, Gradient, Glass, Machined, Edged }

// A relief. Its zero value is the flat finish: plain faces, a thin edge, no light.
Relief :: struct {
	carved:  bool,         // wells, keys, grooves and plates are drawn by the relief (machined())
	square:  bool,         // square corners whatever the rounding (rounding() is 0); a shape's own radius stays
	sheen:   bool,         // raised faces take the light of their "sheen" entry; a ring of focus glows
	engrave: bool,         // the text on a raised face is engraved
	face:    Face_Paint,
	row:     Row_Paint,
	extra:   Relief_Extra,
	no_glow:  bool,        // no halo whatever Theme.glow
	no_hover: bool,        // no light under the pointer in a well or a key
	no_shadow: bool,       // no drop shadow under a menu nor a dim behind a dialog (their palette entries)
	surface_tones: bool,   // a well's, a groove's and a panel's rings take the tones of the raised face ("button background")
	// the rings of a relief of rings: a key at rest, pressed; a well; a groove (its lines, each ring's top-left tone);
	// a panel's frame; a bar's or a key cap's rim
	raised, pressed, sunken, groove, frame, bar: Relief_Rings,
}

RELIEF_FLAT     :: Relief{}
RELIEF_GRADIENT :: Relief{sheen = true, face = .Lit, row = .Gradient, extra = .Gradient}
RELIEF_GLASS    :: Relief{sheen = true, face = .Gloss, row = .Glass, extra = .Glass}
RELIEF_MACHINED :: Relief{carved = true, sheen = true, engrave = true, face = .Strong, row = .Machined, extra = .Machined}
RELIEF_EDGED    :: Relief{carved = true, square = true, sheen = true, face = .Strong, row = .Edged, extra = .Edged}

// Windows 95's bevel, a relief of rings alone: two rings of one pixel, white and the face's light along the top and
// left, black and its shadow along the bottom and right; pressed and sunken, turned over. Its wells, grooves and frames
// in the tones of the theme's grey; plain faces and rows, no halo, no light under the pointer, no shadow.
RELIEF_BEVEL :: Relief{
	carved = true, square = true, sheen = true, face = .Plain, row = .Plain, extra = .None,
	no_glow = true, no_hover = true, no_shadow = true, surface_tones = true,
	raised  = {{width = 1, top_left = 1, bottom_right = -1}, {width = 1, top_left = BEVEL_LIGHT, bottom_right = -BEVEL_SHADOW}},
	pressed = {{width = 1, top_left = -1, bottom_right = 1}, {width = 1, top_left = -BEVEL_SHADOW, bottom_right = BEVEL_LIGHT}},
	sunken  = {{width = 1, top_left = -BEVEL_SHADOW, bottom_right = 1}, {width = 1, top_left = -1, bottom_right = BEVEL_LIGHT}},
	groove  = {{width = 1, top_left = -BEVEL_SHADOW}, {width = 1, top_left = 1}},
	frame   = {{width = 1, top_left = BEVEL_LIGHT, bottom_right = -1}, {width = 1, top_left = 1, bottom_right = -BEVEL_SHADOW}},
	bar     = {{width = 1, top_left = 1, bottom_right = -BEVEL_SHADOW}, {}},
}

// The bevel's light (half way to white: #dfdfdf on #c0c0c0) and shadow (a third of the way to black: #808080).
@(private = "file") BEVEL_LIGHT  :: 0.5
@(private = "file") BEVEL_SHADOW :: 1.0 / 3.0

// The preset of a finish: what the program's finish setting picks.
relief_of :: proc(f: Finish) -> Relief {
	switch f {
	case .Flat:     return RELIEF_FLAT
	case .Gradient: return RELIEF_GRADIENT
	case .Glass:    return RELIEF_GLASS
	case .Machined: return RELIEF_MACHINED
	case .Edged:    return RELIEF_EDGED
	}
	return RELIEF_FLAT
}

// The relief drawn now (Theme.relief, apply_palette's), nil with no theme: the flat one.
@(private)
relief_shown :: proc() -> ^Relief {
	s := current
	if s == nil || s.theme == nil { return nil }
	return &s.theme.relief
}

// The relief drawn now when it is one of rings, drawn from its data; nil otherwise.
@(private)
relief_ringed :: proc() -> ^Relief {
	rl := relief_shown()
	return rl != nil && rl.carved && rl.extra == .None ? rl : nil
}

// The tone `t` of `face`: a step toward white (t > 0) or black (t < 0) in sRGB values, its alpha kept.
relief_tone :: proc(face: Color, t: f32) -> Color {
	if t > 0 { return srgb_step(face, {1, 1, 1, face.a}, t) }
	if t < 0 { return srgb_step(face, {0, 0, 0, face.a}, -t) }
	return face
}

// The face a relief with surface_tones takes the tones of its wells, grooves and frames from: the theme's raised face,
// opaque. (A well's own colour is its inside, white for a field: its tones would be white on white.)
@(private)
relief_surface :: proc(rl: ^Relief, own: Color) -> Color {
	if !rl.surface_tones { return own }
	c := color_from_tags(gs(), 0, "button background")
	return {c.r, c.g, c.b, 1}
}

// Draws `rings` inside `r`, the first outermost, in tones of `face`. The bottom and right sides run to the corners over
// the top and left ones: the top-right and bottom-left pixels are the shade's, as Windows drew them.
relief_rings :: proc(dc: ^draw.Context, r: Rect, rings: Relief_Rings, face: Color) {
	p := px1()
	q := r
	for ring in rings {
		if ring.width <= 0 { return }
		w := math.round(ring.width * p)
		if q.max.x - q.min.x < 2 * w || q.max.y - q.min.y < 2 * w { return }
		tl, br := relief_tone(face, ring.top_left), relief_tone(face, ring.bottom_right)
		soft: f32 = ring.blur > 0 ? max(1, ring.blur * scale()) : 1
		draw.rect(dc, {q.min, {q.max.x - w, q.min.y + w}}, tl, 0, 0, soft)
		draw.rect(dc, {q.min, {q.min.x + w, q.max.y - w}}, tl, 0, 0, soft)
		draw.rect(dc, {{q.min.x, q.max.y - w}, q.max}, br, 0, 0, soft)
		draw.rect(dc, {{q.max.x - w, q.min.y}, q.max}, br, 0, 0, soft)
		q = draw.rect_pad(q, -w)
	}
}

// A round shape (a radio, a switch's knob: shape_rad) cannot take rings of straight lines: its first ring's two tones
// are two discs a ring's width apart, `fill` over them, so the light still falls from the top left.
relief_round :: proc(dc: ^draw.Context, r: Rect, radius: f32, rings: Relief_Rings, face, fill: Color) {
	w := math.round(max(rings[0].width, 1) * px1())
	draw.rect(dc, {r.min, r.max - Vec2{w, w}}, relief_tone(face, rings[0].top_left), radius)
	draw.rect(dc, {r.min + Vec2{w, w}, r.max}, relief_tone(face, rings[0].bottom_right), radius)
	draw.rect(dc, draw.rect_pad(r, -w), fill, max(0, radius - w))
}

// A groove from `a` to `b` (horizontal, or `vertical`): each ring a line beside the one before, in its top-left tone.
relief_lines :: proc(dc: ^draw.Context, a, b: Vec2, vertical: bool, rings: Relief_Rings, face: Color) {
	p := px1()
	at: f32 = 0
	for ring in rings {
		if ring.width <= 0 { return }
		w := math.round(ring.width * p)
		c := relief_tone(face, ring.top_left)
		if vertical {
			draw.rect(dc, {{a.x + at, a.y}, {a.x + at + w, b.y}}, c)
		} else {
			draw.rect(dc, {{a.x, a.y + at}, {b.x, a.y + at + w}}, c)
		}
		at += w
	}
}
