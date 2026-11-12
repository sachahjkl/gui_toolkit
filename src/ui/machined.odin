package ui

// The machined finish (Finish.Machined): surfaces made like a machined panel. A raised surface is bevelled: a soft
// shadow, a dark outer edge, a face lit at the top, a rim of light along its top and a shade along its bottom; pressed,
// it sinks. A sunken one (a field, a well) has an inner shadow from above and a lit lip under its opening; focused, a
// ring of the accent. A separator is a groove: a dark cut with the light catching its lower edge. The reliefs are made
// for the dark; on a light palette (Theme.dark false) the same reliefs take lighter shades and stronger lights: every
// black of a relief is relief_shade's, every white relief_shine's, every face darkened relief_darken's.
//
// The built-in widgets take it from their boxes (machined_box): a box with a background and a sheen is raised (bevelled
// when it can be clicked), a .Sunken box is a well, a .Groove box a groove, a .Plate box a raised panel (machined_plate). A program draws its own boxes with the same
// primitives (machined_bevel, machined_well, machined_groove, machined_plate, machined_lamp, machined_pip); outside the
// machined finish each draws its flat form (a plain face, a thin edge), so one call serves every finish.
//
// What it draws reaches out of a box by up to MACHINED_OVERFLOW_PX (scaled): its shadow, a halo, the lip of a well. A
// damaged region must hold that much around the boxes it holds.

import "core:math"
import "../draw"

// How far the machined drawing of a box reaches outside it, in logical pixels.
MACHINED_OVERFLOW_PX :: 6
// The flat form of a raised face: under the pointer, held: this far toward the text.
@(private = "file") FLAT_HOT     :: 0.06
@(private = "file") FLAT_PRESSED :: 0.12
// A raised face (machined_bevel): how far its top goes toward white and its bottom toward black; its rim's light.
@(private = "file") BEVEL_TOP_LIGHTEN   :: 0.14
@(private = "file") BEVEL_BOTTOM_DARKEN :: 0.20
@(private = "file") BEVEL_RIM_ALPHA     :: 0.22
// A .Plate box: how far its face goes toward white at the top and toward black at the bottom; its shadow (logical pixels).
@(private = "file") PLATE_TOP_LIGHTEN   :: 0.05
@(private = "file") PLATE_BOTTOM_DARKEN :: 0.06
@(private = "file") PLATE_SHADOW_PX     :: 5
// Below this a state or a halo draws nothing.
@(private = "file") VISIBLE :: 0.01

// Whether the machined reliefs are drawn now: the machined finish, or the edged one (the same reliefs, crisp).
machined :: proc() -> bool {
	s := gs()
	return s != nil && s.theme != nil && (s.theme.finish == .Machined || s.theme.finish == .Edged)
}

// Whether the edged finish is the one drawn now: no blurred shadow under a raised face nor inside a well; hairlines say
// the relief (a lit one along a top, a dark one along a bottom, a dark one around).
edged :: proc() -> bool {
	s := gs()
	return s != nil && s.theme != nil && s.theme.finish == .Edged
}

// The edged finish: a raised face's top and bottom toward white and black; its lit top line, its dark bottom line; a well's
// dark lines under its opening's top edge (the first, then a fainter one), its lit lower lip.
@(private = "file") EDGED_TOP_LIGHTEN   :: 0.08
@(private = "file") EDGED_BOTTOM_DARKEN :: 0.10
@(private = "file") EDGED_RIM_ALPHA     :: 0.24
@(private = "file") EDGED_SHADE_ALPHA   :: 0.35
@(private = "file") EDGED_WELL_TOP      :: 0.55
@(private = "file") EDGED_WELL_TOP2     :: 0.22
@(private = "file") EDGED_LIP_ALPHA     :: 0.08
@(private = "file") EDGED_EDGE_ALPHA    :: 0.85
@(private = "file") EDGED_PLATE_EDGE_LIGHTEN :: 0.12   // a panel's outline: its border colour this much toward white

// A hairline `p` thick along the top of `r` (inside it), and one along its bottom, kept off the rounded corners.
@(private = "file")
edged_lines :: proc(dc: ^draw.Context, r: Rect, radius, p: f32, top, bottom: Color) {
	inset := max(p, radius * 0.6)
	if top.a > 0 { draw.rect(dc, {{r.min.x + inset, r.min.y + p}, {r.max.x - inset, r.min.y + 2 * p}}, top) }
	if bottom.a > 0 { draw.rect(dc, {{r.min.x + inset, r.max.y - 2 * p}, {r.max.x - inset, r.max.y - p}}, bottom) }
}

// One device pixel at least, rounded.
@(private)
px1 :: proc() -> f32 { return max(1, math.round(scale())) }

@(private = "file")
radii4 :: proc(r: f32) -> [4]f32 { return {r, r, r, r} }

@(private = "file")
with_alpha :: proc(c: Color, a: f32) -> Color { return {c.r, c.g, c.b, c.a * a} }

@(private = "file")
lighten :: proc(c: Color, t: f32) -> Color { return srgb_step(c, {1, 1, 1, c.a}, t) }

@(private = "file")
darken :: proc(c: Color, t: f32) -> Color { return srgb_step(c, {0, 0, 0, c.a}, t) }

// How a relief's shades and lights are drawn on the palette shown: made for the dark, a light palette takes lighter shades
// and stronger lights (a relief on paper is drawn by its light).
Relief_Light :: struct { shade_scale: f32, shine_scale: f32, shine_floor: f32, shine_max: f32, darken_scale: f32 }
RELIEF_ON_LIGHT :: Relief_Light{shade_scale = 0.3, shine_scale = 3.5, shine_floor = 0.25, shine_max = 0.9, darken_scale = 0.45}

// The black of a relief (a shadow, an edge, an inner shadow, a groove) of alpha `a` as written for the dark, on a dark
// palette (`dark`) or a light one. Public for a program's own reliefs and for the tests; the toolkit's use relief_shade.
relief_shade_for :: proc(a: f32, dark: bool) -> Color {
	return dark ? Color{0, 0, 0, a} : Color{0, 0, 0, a * RELIEF_ON_LIGHT.shade_scale}
}

// The white of a relief (a rim, a lip, a highlight) of alpha `a` as written for the dark, on a dark palette or a light
// one: there the light draws the relief, so even a faint rim shows (none stays none: a rim fading to 0 still fades).
relief_shine_for :: proc(a: f32, dark: bool) -> Color {
	if dark { return {1, 1, 1, a} }
	return {1, 1, 1, a <= 0 ? 0 : min(RELIEF_ON_LIGHT.shine_max, RELIEF_ON_LIGHT.shine_floor + a * RELIEF_ON_LIGHT.shine_scale)}
}

// Whether the reliefs are drawn for a dark palette now (no theme: as they are made, for the dark).
@(private = "file")
relief_dark :: proc() -> bool {
	s := gs()
	return s.theme == nil || s.theme.dark
}

// relief_shade_for and relief_shine_for on the palette shown.
@(private)
relief_shade :: proc(a: f32) -> Color { return relief_shade_for(a, relief_dark()) }
@(private)
relief_shine :: proc(a: f32) -> Color { return relief_shine_for(a, relief_dark()) }

// A face's bottom or a pressed face toward black by `t` (as written for the dark): less on a light palette.
@(private)
relief_darken :: proc(c: Color, t: f32) -> Color { return darken(c, relief_dark() ? t : t * RELIEF_ON_LIGHT.darken_scale) }

// The halos' strength (Theme.glow).
@(private = "file")
glow_of :: proc() -> f32 {
	s := gs()
	return s.theme != nil ? s.theme.glow : 0
}

// The edge of a flat surface: the theme's line, lit a little under the pointer.
@(private = "file")
flat_edge :: proc(hot: f32) -> Color {
	line := color_from_tags(gs(), 0, "border")
	return draw.mix(line, lighten(line, 0.25), hot)
}

// A raised face: `hot` under the pointer (0..1), `pressed` held (0..1); `glow`: a halo of that colour under the pointer
// (an accent button). `radius` in frame pixels.
machined_bevel :: proc(dc: ^draw.Context, r: Rect, radius: f32, face_color: Color, hot, pressed: f32, glow := Color{}) {
	s := scale()
	p := px1()
	rr := radii4(radius)
	if !machined() {
		text := color_from_tags(gs(), 0, "text")
		face := draw.mix(face_color, text, FLAT_HOT * hot)
		draw.rect(dc, r, pressed < 0.5 ? face : draw.mix(face_color, text, FLAT_PRESSED), radius)
		draw.rect(dc, r, flat_edge(hot), radius, p)
		return
	}
	face := lighten(face_color, 0.06 * hot)
	if edged() {
		// (filled shapes from the outside in, as the machined bevel: the dark hairline, then the face inside it, then its lines)
		inner, ir := draw.rect_pad(r, -p), max(0, radius - p)
		draw.rect(dc, r, relief_shade(EDGED_EDGE_ALPHA), radius)
		if pressed < 0.5 {
			if g := glow_of(); glow.a > 0 && hot > VISIBLE && g > 0 { draw.box_shadow(dc, r, rr, 2.5 * s, with_alpha(glow, 0.2 * hot * g)) }
			top, bot := lighten(face, EDGED_TOP_LIGHTEN), relief_darken(face, EDGED_BOTTOM_DARKEN)
			draw.rect_corners(dc, inner, {top, bot, top, bot}, radii4(ir))
			edged_lines(dc, r, radius, p, relief_shine(EDGED_RIM_ALPHA), relief_shade(EDGED_SHADE_ALPHA))
		} else {   // pushed in: darker, the shade now along its top
			draw.rect(dc, inner, relief_darken(face, 0.18), ir)
			edged_lines(dc, r, radius, p, relief_shade(EDGED_WELL_TOP), {})
		}
		return
	}
	// (filled shapes from the outside in, each over the antialiased edge of the one under it: the edge, then the face
	// inside it. Strokes side by side left gaps in the curves at a small size, and their greys changed along them)
	inner, ir := draw.rect_pad(r, -p), max(0, radius - p)
	if pressed < 0.5 {
		draw.box_shadow(dc, draw.rect_shift(r, {0, 1.5 * s}), rr, 2.2 * s, relief_shade(0.65))
		// (under the pointer only, and tight: a wide halo reached what is above it)
		if g := glow_of(); glow.a > 0 && hot > VISIBLE && g > 0 { draw.box_shadow(dc, r, rr, 2.5 * s, with_alpha(glow, 0.2 * hot * g)) }
		draw.rect(dc, r, relief_shade(0.85), radius)
		top, bot := lighten(face, BEVEL_TOP_LIGHTEN), relief_darken(face, BEVEL_BOTTOM_DARKEN)
		draw.rect_corners(dc, inner, {top, bot, top, bot}, radii4(ir))
		// the rim: light along the top, dark along the bottom, on the face's own edge
		draw.rect_corners(dc, inner, {relief_shine(BEVEL_RIM_ALPHA), relief_shine(0.03), relief_shine(BEVEL_RIM_ALPHA), relief_shine(0.03)}, radii4(ir), p)
		draw.rect(dc, {{r.min.x + radius * 0.8, r.max.y - 2 * p}, {r.max.x - radius * 0.8, r.max.y - p}}, relief_shade(0.25))
	} else {
		draw.rect(dc, r, relief_shade(0.85), radius)
		draw.rect(dc, inner, relief_darken(face, 0.22), ir)
		draw.inset_shadow(dc, inner, radii4(ir), draw.rect_shift(draw.rect_pad(inner, -1 * s), {0, 2 * s}), radii4(ir), 2.5 * s, relief_shade(0.8))
		// the lip of the hole catches the light below
		draw.rect(dc, {{r.min.x + radius * 0.7, r.max.y}, {r.max.x - radius * 0.7, r.max.y + p}}, relief_shine(0.06))
	}
}

// A sunken surface of colour `base`; `focus` (0..1) lights a ring of `accent` around it.
machined_well :: proc(dc: ^draw.Context, r: Rect, radius: f32, base: Color, focus: f32 = 0, accent := Color{}) {
	s := scale()
	p := px1()
	rr := radii4(radius)
	if !machined() {
		draw.rect(dc, r, base, radius)
		draw.rect(dc, r, draw.mix(flat_edge(0), with_alpha(accent, 0.9), focus), radius, p)
		return
	}
	if g := glow_of(); focus > VISIBLE && g > 0 { draw.box_shadow(dc, r, rr, 4 * s, with_alpha(accent, 0.12 * focus * g)) }
	if edged() {
		// (filled shapes from the outside in, as the machined well: the dark hairline (the accent's when focused), the
		// surface inside it, then the dark lines under its top and the lit lip under it)
		draw.rect(dc, r, draw.mix(relief_shade(0.9), with_alpha(accent, 0.9), focus), radius)
		draw.rect(dc, draw.rect_pad(r, -p), base, max(0, radius - p))
		edged_lines(dc, r, radius, p, relief_shade(EDGED_WELL_TOP), {})
		edged_lines(dc, draw.rect_shift(r, {0, p}), radius, p, relief_shade(EDGED_WELL_TOP2), {})
		draw.rect(dc, {{r.min.x + radius * 0.6, r.max.y}, {r.max.x - radius * 0.6, r.max.y + p}}, relief_shine(EDGED_LIP_ALPHA))
		return
	}
	// (filled shapes from the outside in, each over the antialiased edge of the one under it: the lit rim of the opening,
	// the dark edge, the surface. Three strokes side by side left gaps in the curves at a small size, their greys
	// changing along them; and the surface stops inside the edge, so a lit colour spills nothing onto the rim)
	// the rim of the opening, lit: without it a dark well on a dark panel has no edge (the accent's ring replaces it)
	if focus < 0.99 { draw.rect(dc, draw.rect_pad(r, p), relief_shine(0.1 * (1 - focus)), radius + p) }
	edge := focus > VISIBLE ? draw.mix(relief_shade(0.9), with_alpha(accent, 0.85), focus) : relief_shade(0.9)
	draw.rect(dc, r, edge, radius)
	inner, ir := draw.rect_pad(r, -p), max(0, radius - p)
	draw.rect(dc, inner, base, ir)
	draw.inset_shadow(dc, inner, radii4(ir), draw.rect_shift(draw.rect_pad(inner, -0.5 * s), {0, 2.5 * s}), radii4(ir), 3.5 * s, relief_shade(0.85))
	draw.rect(dc, {{r.min.x + radius * 0.6, r.max.y}, {r.max.x - radius * 0.6, r.max.y + p}}, relief_shine(0.07))
}

// A carved line from `a` to `b` (horizontal, or `vertical`).
machined_groove :: proc(dc: ^draw.Context, a, b: Vec2, vertical := false) {
	p := px1()
	if !machined() {
		draw.rect(dc, vertical ? Rect{a, {a.x + p, b.y}} : Rect{a, {b.x, a.y + p}}, color_from_tags(gs(), 0, "border"))
		return
	}
	if vertical {
		draw.rect(dc, {a, {a.x + p, b.y}}, relief_shade(0.9))
		draw.rect(dc, {{a.x + p, a.y}, {a.x + 2 * p, b.y}}, relief_shine(0.05))
	} else {
		draw.rect(dc, {a, {b.x, a.y + p}}, relief_shade(0.9))
		draw.rect(dc, {{a.x, a.y + p}, {b.x, a.y + 2 * p}}, relief_shine(0.05))
	}
}

// A raised panel (cards, popover bodies): a face from `top` to `bottom`, a lit rim of `rim` (alpha), a soft shadow of
// `shadow` logical pixels, an edge of `border`, a halo of `glow`. `border` zero (the default): the relief's own edge,
// relief_shade(0.85) (a dark edge on a dark palette, a light one on paper); another colour of alpha 0: no edge.
// `frame` false: the face alone; its rim and edge come after what is in it (machined_plate_frame), a box's children drawn
// over the face and under the frame (draw_box does it for a .Plate box).
machined_plate :: proc(dc: ^draw.Context, r: Rect, radius: f32, top, bottom: Color, shadow: f32 = 6, rim: f32 = 0.07, border := Color{}, glow := Color{}, frame := true) {
	machined_plate_corners(dc, r, radii4(radius), top, bottom, shadow, rim, border, glow, frame)
}

// machined_plate with a radius per corner (draw.rect_corners' order): a dialog's square corner under its resize grip.
machined_plate_corners :: proc(dc: ^draw.Context, r: Rect, rr: [4]f32, top, bottom: Color, shadow: f32 = 6, rim: f32 = 0.07, border := Color{}, glow := Color{}, frame := true) {
	s := scale()
	p := px1()
	if !machined() {
		draw.rect_corners(dc, r, colors4(draw.mix(top, bottom, 0.5)), rr)
		if (border == Color{} || border.a > 0) && frame { draw.rect_corners(dc, r, colors4(flat_edge(0)), rr, p) }
		return
	}
	if shadow > 0 { draw.box_shadow(dc, draw.rect_shift(r, {0, 2 * s}), rr, shadow * s, relief_shade(0.6)) }
	if g := glow_of(); glow.a > 0 && g > 0 { draw.box_shadow(dc, r, rr, 6 * s, with_alpha(glow, glow.a * 0.5 * g)) }
	draw.rect_corners(dc, r, {top, bottom, top, bottom}, rr)
	if frame { machined_plate_frame_corners(dc, r, rr, rim, border) }
}

// A raised panel's frame: its lit rim (edged: a line of light along its top and a shade along its bottom) and its edge.
// Drawn over what is in the panel, a child's background or line does not cover it. `border` as machined_plate's.
machined_plate_frame :: proc(dc: ^draw.Context, r: Rect, radius: f32, rim: f32 = 0.07, border := Color{}) {
	machined_plate_frame_corners(dc, r, radii4(radius), rim, border)
}

// machined_plate_frame with a radius per corner (draw.rect_corners' order).
machined_plate_frame_corners :: proc(dc: ^draw.Context, r: Rect, rr: [4]f32, rim: f32 = 0.07, border := Color{}) {
	p := px1()
	if edged() {   // (a line along its top, of light at once, not a rim fading down its sides)
		edged_lines(dc, r, max(rr[0], rr[1], rr[2], rr[3]), p, relief_shine(max(rim, 0.10)), relief_shade(EDGED_SHADE_ALPHA * 0.6))
	} else if rim > 0 {
		inner: [4]f32
		for v, i in rr { inner[i] = max(0, v - p) }
		draw.rect_corners(dc, draw.rect_pad(r, -p), {relief_shine(rim), relief_shine(0), relief_shine(rim), relief_shine(0)}, inner, p)
	}
	// (a default parameter cannot ask the palette: zero stands for the relief's edge)
	edge := border == Color{} ? relief_shade(0.85) : border
	if edge.a > 0 { draw.rect_corners(dc, r, colors4(edge), rr, p) }
}

// A status lamp at `c`, `d` across: a glass bead, its halo `glow` (a pulse: the halo breathes, the lamp stays lit; < 0:
// as `lit`).
machined_lamp :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color, lit: f32 = 1, glow: f32 = -1) {
	halo := glow >= 0 ? glow : lit
	s := scale()
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	r := Rect{c - d * 0.5, c + d * 0.5}
	rr := radii4(d * 0.5)
	if !machined() {   // a dot, its halo a ring that breathes
		if halo > VISIBLE && glow >= 0 { draw.rect(dc, draw.rect_pad(r, d * 0.08), with_alpha(col, 0.35 * halo), d * 0.5) }
		draw.rect(dc, draw.rect_pad(r, -d * 0.12), draw.mix(darken(col, 0.45), col, lit), d * 0.5)
		return
	}
	if g := glow_of(); halo > VISIBLE && g > 0 { draw.box_shadow(dc, r, rr, d * 0.45, with_alpha(col, 0.4 * halo * g)) }
	draw.rect(dc, draw.rect_pad(r, 1 * s), relief_shade(0.8), d * 0.5 + s)
	body := draw.mix(darken(col, 0.3), col, lit)   // (dimmed, not browned: the colour stays clean through a pulse)
	draw.rect_corners(dc, r, {lighten(body, 0.25), darken(body, 0.2), lighten(body, 0.25), darken(body, 0.2)}, rr)
	hl := Rect{{c.x - d * 0.26, c.y - d * 0.36}, {c.x + d * 0.10, c.y - d * 0.10}}
	draw.rect(dc, hl, relief_shine(0.22 + 0.2 * lit), d * 0.18, 0, d * 0.12)
}

// A pip at `c`, `d` across: a small hole drilled in the surface with a dab of colour at its bottom, unlit (what is
// over; a lamp is what is live).
machined_pip :: proc(dc: ^draw.Context, c: Vec2, d: f32, col: Color) {
	prev := draw.set_circular_corners(dc, true)
	defer draw.set_circular_corners(dc, prev)
	p := px1()
	r := Rect{c - d * 0.5, c + d * 0.5}
	if !machined() {
		in_f := draw.rect_pad(r, -max(p, math.round(d * 0.25)))
		draw.rect(dc, in_f, with_alpha(col, 0.8), (in_f.max.x - in_f.min.x) * 0.5)
		return
	}
	draw.rect(dc, r, relief_shade(0.75), d * 0.5)
	draw.rect(dc, {{r.min.x, r.max.y - p}, {r.max.x, r.max.y + p}}, relief_shine(0.05), d * 0.5)   // the lit lower lip
	in_r := draw.rect_pad(r, -max(p, math.round(d * 0.22)))
	draw.rect(dc, in_r, with_alpha(col, 0.8), (in_r.max.x - in_r.min.x) * 0.5)
}

// How a box of the built-in widgets is drawn in the machined finish. `face`: this drew its background (draw_box draws
// no other); `whole`: also its edge and its focus (draw_box draws neither). A .Groove box is a groove along its length; a .Sunken box with a
// background a well (a clear one sits in a well: a bare field); an opaque background with a sheen is raised: bevelled
// when it can be clicked, else a face with a lit rim.
// A .Plate box's frame, after its children (machined_box drew its face): its rim and edge over what fills it.
// (edged: its edge is its own border's colour, lit a little, as a console's window is outlined: a dark one was lost on
// the dimmed page around a dialog)
@(private)
machined_plate_over :: proc(s: ^State, dc: ^draw.Context, b: ^Box, r: Rect, radii: [4]f32) {
	if !machined() || .Plate not_in b.flags || .Draw_Background not_in b.flags || b.bg.a < 0.99 { return }
	edge := relief_shade(0.85)
	if edged() { edge = lighten(b.border.a > VISIBLE ? b.border : color_from_tags(s, b.tags_key, "border"), EDGED_PLATE_EDGE_LIGHTEN) }
	machined_plate_frame_corners(dc, r, radii, border = edge)
}

@(private)
machined_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, r: Rect, radii: [4]f32, keyboard_focus: bool) -> (face, whole: bool) {
	radius := radii[0]   // (a well or a bevel: one radius; a raised panel takes each corner's)
	if !machined() { return }
	if .Groove in b.flags {
		p := px1()
		if r.max.x - r.min.x < r.max.y - r.min.y {
			x := math.round((r.min.x + r.max.x) * 0.5) - p
			machined_groove(dc, {x, r.min.y}, {x, r.max.y}, true)
		} else {
			y := math.round((r.min.y + r.max.y) * 0.5) - p
			machined_groove(dc, {r.min.x, y}, {r.max.x, y})
		}
		return true, true
	}
	if .Draw_Background not_in b.flags || b.bg.a < VISIBLE { return }
	if .Plate in b.flags && b.bg.a >= 0.99 {
		// a raised panel: its face a shade lighter at the top, a lit rim, a dark edge; a shadow under it unless it has its own
		// (.Draw_Shadow: a dialog, a menu)
		// (edged: its edge is its own border's colour, lit a little, as a console's window is outlined: a dark one was lost on
		// the dimmed page around a dialog)
		// (its frame after its children: machined_plate_over)
		machined_plate_corners(dc, r, radii, lighten(b.bg, PLATE_TOP_LIGHTEN), relief_darken(b.bg, PLATE_BOTTOM_DARKEN), .Draw_Shadow in b.flags ? 0 : PLATE_SHADOW_PX, frame = false)
		return true, true
	}
	if .Sunken in b.flags {
		focus := keyboard_focus ? 1 : b.focus_t
		machined_well(dc, r, radius, color_from_tags(s, b.tags_key, "well"), focus, color_from_tags(s, b.tags_key, "focus border"))
		return true, true
	}
	if b.bg.a < 0.99 || box_sheen(s, b) <= VISIBLE { return }
	if .Clickable in b.flags {
		machined_bevel(dc, r, radius, b.bg, b.hot_t, b.active_t * b.hot_t)
		return true, !keyboard_focus   // (a keyboard's focus keeps the theme's ring)
	}
	// a raised panel (a bar, a key cap): its face, a lit rim along its top
	draw.rect_corners(dc, r, colors4(b.bg), radii)
	if edged() {
		edged_lines(dc, r, radius, px1(), relief_shine(0.09), relief_shade(EDGED_SHADE_ALPHA * 0.6))
		return true, false
	}
	draw.rect_corners(dc, draw.rect_pad(r, -px1()), {relief_shine(0.07), relief_shine(0), relief_shine(0.07), relief_shine(0)}, radii_grown(radii, -px1()), px1())
	return true, false   // (its edge is the theme's: draw_box draws it)
}
