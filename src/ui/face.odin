package ui

// The face of a box in its interaction state (src/md/features/interaction-states.md). Under the pointer the face lifts a
// step toward the theme's tint, held down it sinks, toggled it stays sunk; a face that has no colour at rest appears in
// the box's shape. The face is the box's own surface, on its own rect and radii, painted by the finish: never a layer
// over the box.

import "core:math"
import "../draw"

// How a box is in its states, each 0..1: under the pointer, the button held on it, on (.Held: a tool that is on).
Face_State :: struct { hot, pressing, toggled: f32 }

// A face in its state, as draw_face paints it.
Face :: struct {
	color:  Color,   // its colour (alpha 0: no face)
	sheen:  f32,     // the finish's light on it (0: a plain colour)
	sunk:   f32,     // 0..1: pressed in (a lit face inverts, glass loses its gloss, a key goes in)
	rim:    bool,    // the finish's lit line round it (box_rimmed)
	raised: bool,    // a face that appears under the pointer as a key (a ghost button: its tags' hover_sheen)
	appear: f32,     // 0..1: how far a face that has no colour at rest has appeared
}

// A toggled face under the pointer lifts this share of a hover step: it is sunk, it moves less.
@(private = "file") TOGGLED_HOT_SHARE :: 0.5
// Below this a state or an alpha changes nothing.
@(private = "file") FACE_EPS :: 0.001
// A face this opaque is stepped as it is; a fainter one is first made opaque over what is under it.
@(private = "file") FACE_OPAQUE :: 0.99
// A press shows at once, whatever the hover's ease: the pointer may have come just before it (a tap). Under this much of
// hot_t the press fades with it (the pointer leaves while the button is held).
@(private = "file") PRESS_HOT_FULL :: 0.5

// The states of `b`: box_hot's hover (all of it while .Lit), its press while the pointer is on it, .Held.
face_state :: proc(b: ^Box) -> Face_State {
	return {
		hot      = box_hot(b),
		pressing = b.active_t * min(1, b.hot_t / PRESS_HOT_FULL),
		toggled  = .Held in b.flags ? 1 : 0,
	}
}

// How far a face goes toward the tint in state `st`: `hover` under the pointer, `press` held down or toggled; a toggled
// face lifts half a hover step under the pointer; a press is the press step whatever was before.
face_step :: proc(st: Face_State, hover, press: f32) -> f32 {
	sunk := max(st.toggled, st.pressing)
	lift := hover * st.hot * (1 - st.pressing) * (1 - (1 - TOGGLED_HOT_SHARE) * st.toggled)
	return press * sunk + lift
}

// `c` (translucent) laid over `under` as the frame blends it: an opaque colour. (The theme's translucent entries are
// tuned for the blend space: draw.alpha_like_linear.)
face_over :: proc(c, under: Color, space: draw.Blend_Space) -> Color {
	o := Color{c.r, c.g, c.b, 1}
	u := Color{under.r, under.g, under.b, 1}
	m := space == .Linear ? draw.mix(u, o, c.a) : srgb_mix(u, o, c.a)
	m.a = 1
	return m
}

// The face of `rest` (its colour at rest, alpha 0: none) on `under` in state `st`: `tint` the theme's (Slot.Hover),
// `hover` and `press` its steps, `hover_sheen` the light of a face that appears (0: a flat one, a row). Pure: the tests
// call it.
face_of :: proc(rest, under, tint: Color, st: Face_State, hover, press, hover_sheen: f32, space: draw.Blend_Space) -> (f: Face) {
	f.color = rest
	k := face_step(st, hover, press)
	if k <= FACE_EPS { return }
	f.sunk = max(st.toggled, st.pressing)
	if rest.a >= FACE_OPAQUE {
		f.color = srgb_step(rest, tint, k)
		return
	}
	// (a face translucent at rest, a selected row's tint, or none, a ghost button's: opaque once it has appeared)
	f.appear = min(1, st.hot + st.pressing + st.toggled)
	f.color = srgb_step(face_over(rest, under, space), tint, k)
	f.color.a = math.lerp(rest.a, 1, f.appear)
	if rest.a <= FACE_EPS && hover_sheen > FACE_EPS {
		f.raised = true
		f.sheen = hover_sheen
	}
	return
}

// The face `b` draws: its background, and with .Draw_Hot_Effects its state's (face_of, with its tags' steps).
box_face :: proc(s: ^State, b: ^Box) -> Face {
	rest := .Draw_Background in b.flags ? b.bg : Color{}
	f := Face{color = rest}
	if .Draw_Hot_Effects in b.flags {
		hover := color_from_tags(s, b.tags_key, "hover_fill")
		press := color_from_tags(s, b.tags_key, "press_fill")
		sheen := color_from_tags(s, b.tags_key, "hover_sheen").a
		under := b.parent != nil ? box_under(b.parent) : s.backdrop
		f = face_of(rest, under, {hover.r, hover.g, hover.b, 1}, face_state(b), hover.a, press.a, sheen, s.space)
	}
	if !f.raised {
		f.sheen = box_sheen(s, b)
		// (a translucent face made opaque keeps the light it had at rest: the finish's light goes with the face's alpha,
		// and a selected row under the pointer grew a full rim, a plate's, that it never had)
		if rest.a > 0 && rest.a < FACE_OPAQUE && f.color.a > rest.a { f.sheen *= rest.a / f.color.a }
	}
	f.rim = box_rimmed(s, b)
	return f
}

// Paints face `f` on `r`: the finish's, sunk as far as it is; a raised face that appears is a key rising out of the
// surface in the machined and edged finishes.
draw_face :: proc(s: ^State, dc: ^draw.Context, r: Rect, radii: [4]f32, f: Face) {
	if f.color.a <= FACE_EPS { return }
	if s.theme == nil || s.theme.finish == .Flat {
		draw.rect_corners(dc, r, colors4(f.color), radii)
		return
	}
	if f.raised && machined() {
		draw.push_alpha(dc, f.appear)
		machined_bevel(dc, r, radii[0], {f.color.r, f.color.g, f.color.b, 1}, 0, f.sunk)
		draw.pop_alpha(dc)
		return
	}
	paint_rect_corners(dc, r, f.color, radii, f.sheen, rim = f.rim, sunk = f.sunk)
}

// The theme's tint of the states (Slot.Hover: white on a dark palette, black on a light one), opaque.
state_tint :: proc() -> Color {
	c := color_from_tags(gs(), 0, "hover_fill")
	return {c.r, c.g, c.b, 1}
}
