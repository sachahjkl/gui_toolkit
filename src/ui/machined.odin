package ui

// The machined finish (Finish.Machined): surfaces made like a machined panel. A raised surface is bevelled: a soft
// shadow, a dark outer edge, a face lit at the top, a rim of light along its top and a shade along its bottom; pressed,
// it sinks. A sunken one (a field, a well) has an inner shadow from above and a lit lip under its opening; focused, a
// ring of the accent. A separator is a groove: a dark cut with the light catching its lower edge. The reliefs are made
// for the dark: a light palette is drawn flat (apply_palette).
//
// The built-in widgets take it from their boxes (machined_box): a box with a background and a sheen is raised (bevelled
// when it can be clicked), a .Sunken box is a well, a .Groove box a groove. A program draws its own boxes with the same
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
// Below this a state or a halo draws nothing.
@(private = "file") VISIBLE :: 0.01

// Whether the machined finish is the one drawn now.
machined :: proc() -> bool {
	s := gs()
	return s != nil && s.theme != nil && s.theme.finish == .Machined
}

// One device pixel at least, rounded.
@(private = "file")
px1 :: proc() -> f32 { return max(1, math.round(scale())) }

@(private = "file")
radii4 :: proc(r: f32) -> [4]f32 { return {r, r, r, r} }

@(private = "file")
with_alpha :: proc(c: Color, a: f32) -> Color { return {c.r, c.g, c.b, c.a * a} }

@(private = "file")
lighten :: proc(c: Color, t: f32) -> Color { return srgb_step(c, {1, 1, 1, c.a}, t) }

@(private = "file")
darken :: proc(c: Color, t: f32) -> Color { return srgb_step(c, {0, 0, 0, c.a}, t) }

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
	if pressed < 0.5 {
		draw.box_shadow(dc, draw.rect_shift(r, {0, 1.5 * s}), rr, 2.2 * s, {0, 0, 0, 0.65})
		// (under the pointer only, and tight: a wide halo reached what is above it)
		if g := glow_of(); glow.a > 0 && hot > VISIBLE && g > 0 { draw.box_shadow(dc, r, rr, 2.5 * s, with_alpha(glow, 0.2 * hot * g)) }
		top, bot := lighten(face, 0.10), darken(face, 0.16)
		draw.rect_corners(dc, r, {top, bot, top, bot}, rr)
		// the rim: light along the top, dark along the bottom
		draw.rect_corners(dc, draw.rect_pad(r, -p), {{1, 1, 1, 0.16}, {1, 1, 1, 0.03}, {1, 1, 1, 0.16}, {1, 1, 1, 0.03}}, radii4(max(0, radius - p)), p)
		draw.rect(dc, {{r.min.x + radius * 0.8, r.max.y - 2 * p}, {r.max.x - radius * 0.8, r.max.y - p}}, {0, 0, 0, 0.25})
	} else {
		draw.rect(dc, r, darken(face, 0.22), radius)
		draw.inset_shadow(dc, r, rr, draw.rect_shift(draw.rect_pad(r, -1 * s), {0, 2 * s}), rr, 2.5 * s, {0, 0, 0, 0.8})
		// the lip of the hole catches the light below
		draw.rect(dc, {{r.min.x + radius * 0.7, r.max.y}, {r.max.x - radius * 0.7, r.max.y + p}}, {1, 1, 1, 0.06})
	}
	draw.rect(dc, r, {0, 0, 0, 0.85}, radius, p)
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
	draw.rect(dc, r, base, radius)
	draw.inset_shadow(dc, r, rr, draw.rect_shift(draw.rect_pad(r, -0.5 * s), {0, 2.5 * s}), rr, 3.5 * s, {0, 0, 0, 0.85})
	draw.rect(dc, {{r.min.x + radius * 0.6, r.max.y}, {r.max.x - radius * 0.6, r.max.y + p}}, {1, 1, 1, 0.07})
	edge := focus > VISIBLE ? draw.mix(Color{0, 0, 0, 0.9}, with_alpha(accent, 0.85), focus) : Color{0, 0, 0, 0.9}
	draw.rect(dc, r, edge, radius, p)
	// the rim of the opening, lit: without it a dark well on a dark panel has no edge (the accent's ring replaces it)
	if focus < 0.99 { draw.rect(dc, draw.rect_pad(r, p), {1, 1, 1, 0.1 * (1 - focus)}, radius + p, p) }
}

// A carved line from `a` to `b` (horizontal, or `vertical`).
machined_groove :: proc(dc: ^draw.Context, a, b: Vec2, vertical := false) {
	p := px1()
	if !machined() {
		draw.rect(dc, vertical ? Rect{a, {a.x + p, b.y}} : Rect{a, {b.x, a.y + p}}, color_from_tags(gs(), 0, "border"))
		return
	}
	if vertical {
		draw.rect(dc, {a, {a.x + p, b.y}}, {0, 0, 0, 0.9})
		draw.rect(dc, {{a.x + p, a.y}, {a.x + 2 * p, b.y}}, {1, 1, 1, 0.05})
	} else {
		draw.rect(dc, {a, {b.x, a.y + p}}, {0, 0, 0, 0.9})
		draw.rect(dc, {{a.x, a.y + p}, {b.x, a.y + 2 * p}}, {1, 1, 1, 0.05})
	}
}

// A raised panel (cards, popover bodies): a face from `top` to `bottom`, a lit rim of `rim` (alpha), a soft shadow of
// `shadow` logical pixels, an edge of `border`, a halo of `glow`.
machined_plate :: proc(dc: ^draw.Context, r: Rect, radius: f32, top, bottom: Color, shadow: f32 = 6, rim: f32 = 0.07, border := Color{0, 0, 0, 0.85}, glow := Color{}) {
	s := scale()
	p := px1()
	rr := radii4(radius)
	if !machined() {
		draw.rect(dc, r, draw.mix(top, bottom, 0.5), radius)
		if border.a > 0 { draw.rect(dc, r, flat_edge(0), radius, p) }
		return
	}
	if shadow > 0 { draw.box_shadow(dc, draw.rect_shift(r, {0, 2 * s}), rr, shadow * s, {0, 0, 0, 0.6}) }
	if g := glow_of(); glow.a > 0 && g > 0 { draw.box_shadow(dc, r, rr, 6 * s, with_alpha(glow, glow.a * 0.5 * g)) }
	draw.rect_corners(dc, r, {top, bottom, top, bottom}, rr)
	if rim > 0 { draw.rect_corners(dc, draw.rect_pad(r, -p), {{1, 1, 1, rim}, {1, 1, 1, 0}, {1, 1, 1, rim}, {1, 1, 1, 0}}, radii4(max(0, radius - p)), p) }
	if border.a > 0 { draw.rect(dc, r, border, radius, p) }
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
	draw.rect(dc, draw.rect_pad(r, 1 * s), {0, 0, 0, 0.8}, d * 0.5 + s)
	body := draw.mix(darken(col, 0.3), col, lit)   // (dimmed, not browned: the colour stays clean through a pulse)
	draw.rect_corners(dc, r, {lighten(body, 0.25), darken(body, 0.2), lighten(body, 0.25), darken(body, 0.2)}, rr)
	hl := Rect{{c.x - d * 0.26, c.y - d * 0.36}, {c.x + d * 0.10, c.y - d * 0.10}}
	draw.rect(dc, hl, {1, 1, 1, 0.22 + 0.2 * lit}, d * 0.18, 0, d * 0.12)
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
	draw.rect(dc, r, {0, 0, 0, 0.75}, d * 0.5)
	draw.rect(dc, {{r.min.x, r.max.y - p}, {r.max.x, r.max.y + p}}, {1, 1, 1, 0.05}, d * 0.5)   // the lit lower lip
	in_r := draw.rect_pad(r, -max(p, math.round(d * 0.22)))
	draw.rect(dc, in_r, with_alpha(col, 0.8), (in_r.max.x - in_r.min.x) * 0.5)
}

// How a box of the built-in widgets is drawn in the machined finish. `face`: this drew its background (draw_box draws
// no other); `whole`: also its edge and its focus (draw_box draws neither). A .Groove box is a groove along its length; a .Sunken box with a
// background a well (a clear one sits in a well: a bare field); an opaque background with a sheen is raised: bevelled
// when it can be clicked, else a face with a lit rim.
@(private)
machined_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, r: Rect, radius: f32, keyboard_focus: bool) -> (face, whole: bool) {
	if s.theme == nil || s.theme.finish != .Machined { return }
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
	draw.rect(dc, r, b.bg, radius)
	draw.rect_corners(dc, draw.rect_pad(r, -px1()), {{1, 1, 1, 0.07}, {1, 1, 1, 0}, {1, 1, 1, 0.07}, {1, 1, 1, 0}}, radii4(max(0, radius - px1())), px1())
	return true, false   // (its edge is the theme's: draw_box draws it)
}
