package ui

// The face of a row (.Row: a row of a list, a table, a menu, the palette, a sidebar): its hover and its selection are an
// inset, rounded face drawn in the finish, behind the row's content; consecutive selected rows are one block
// (src/md/features/interaction-states.md, "Rows").

import "core:math"
import "../draw"

// The face is this far in from each side of the row (ems of the row's font size), and this far from its top and bottom
// (logical pixels) where it does not join a selected row: two faces one under the other read as two.
ROW_FACE_INSET_EM :: 0.3
ROW_FACE_GAP_PX :: 1

// How a row's face meets the selected rows next to it: joined above, below.
Row_Joins :: struct { above, below: bool }

// The light of a row's face in the lit finishes: its top toward white and its bottom toward black (sRGB steps) and its
// lit line's alpha, for a selected face; a face under the pointer alone has this share of it (a hint, not a plate).
@(private = "file") ROW_GRADIENT_TOP_WHITE :: 0.05
@(private = "file") ROW_GRADIENT_BOTTOM_BLACK :: 0.05
@(private = "file") ROW_GRADIENT_RIM_ALPHA :: 0.12
@(private = "file") ROW_HOVER_SHARE :: 0.5
// Glass: the upper part this much whiter, the rim of light, the selection's edge of the accent (its alpha).
@(private = "file") ROW_GLASS_TOP_WHITE :: 0.22
@(private = "file") ROW_GLASS_RIM_ALPHA :: 0.45
@(private = "file") ROW_GLASS_EDGE_ALPHA :: 0.45
// Machined and edged: a low plate. Its top lit and bottom shaded (sRGB steps), its lit rim and its edge (relief alphas).
@(private = "file") ROW_PLATE_TOP_WHITE :: 0.06
@(private = "file") ROW_PLATE_BOTTOM_BLACK :: 0.08
@(private = "file") ROW_PLATE_RIM_ALPHA :: 0.12
@(private = "file") ROW_PLATE_EDGE_ALPHA :: 0.45
@(private = "file") ROW_EDGED_RIM_ALPHA :: 0.16
@(private = "file") ROW_EDGED_SHADE_ALPHA :: 0.30
// The accent's bar of a navigation's selected row: its width (logical px) and its share of the face's height.
@(private = "file") ROW_MARK_PX :: 3
@(private = "file") ROW_MARK_HEIGHT :: 0.5
// ... its gap from the face's edge (logical px), and the face's height past which it grows no more (a block of rows).
@(private = "file") ROW_MARK_INSET_PX :: 2
@(private = "file") ROW_MARK_TALLEST_PX :: 40
// Two rows touch when their edges are this close (frame px).
@(private = "file") ROW_TOUCH_PX :: 0.5
// Below this nothing shows.
@(private = "file") ROW_EPS :: 0.001

// The face's rect in row rect `r`: `inset` in from each side, `gap` in from the top and the bottom where it is not
// joined. Never inside out (a row narrower than its insets: a line at its middle).
row_face_rect :: proc(r: Rect, inset, gap: f32, joins: Row_Joins = {}) -> Rect {
	f := Rect{{r.min.x + inset, r.min.y + (joins.above ? 0 : gap)}, {r.max.x - inset, r.max.y - (joins.below ? 0 : gap)}}
	if f.max.x < f.min.x { f.min.x = (r.min.x + r.max.x) * 0.5; f.max.x = f.min.x }
	if f.max.y < f.min.y { f.min.y = (r.min.y + r.max.y) * 0.5; f.max.y = f.min.y }
	return f
}

// The radii of face `face` (draw.rect_corners' order) for `radius` (as drawn: box_drawn_radius): at most half its height
// and its width (a pill, not a blob), square where it joins a selected row.
row_face_radii :: proc(face: Rect, radius: f32, joins: Row_Joins = {}) -> [4]f32 {
	r := max(0, min(radius, (face.max.y - face.min.y) * 0.5, (face.max.x - face.min.x) * 0.5))
	top: f32 = joins.above ? 0 : r
	bottom: f32 = joins.below ? 0 : r
	return {top, bottom, top, bottom}
}

// Whether row `b` (above) touches row `a` (below) and is selected: one block with it.
@(private = "file")
row_joins_to :: proc(above, below: Rect) -> bool {
	return abs(above.max.y - below.min.y) <= ROW_TOUCH_PX && above.min.x < below.max.x && below.min.x < above.max.x
}

@(private = "file")
row_chosen :: proc(b: ^Box) -> bool {
	return b != nil && b.flags & {.Row, .Chosen, .Draw_Background} == {.Row, .Chosen, .Draw_Background} && b.bg.a > ROW_EPS
}

// The geometry of `b`'s face: its own (`face`, `radii`) and, for a selected row joined to others, the whole block's
// (`run`, `run_radii`; else the same as its own). The block is looked for among its siblings while they are in their
// parent's view (a list's rows out of view are not walked: the cost is the rows shown).
row_face_of :: proc(s: ^State, b: ^Box) -> (face: Rect, radii: [4]f32, run: Rect, run_radii: [4]f32, joins: Row_Joins) {
	r := b.rect
	em := b.font_size > 0 ? b.font_size : font_size()
	inset := math.round(em * ROW_FACE_INSET_EM)
	gap := ROW_FACE_GAP_PX * max(1, math.round(s.scale))
	radius := box_drawn_radius(s, b)
	top, bottom := r.min.y, r.max.y
	if row_chosen(b) {
		view := b.parent != nil ? b.parent.rect : r
		for p := b.prev; row_chosen(p) && row_joins_to(p.rect, {{r.min.x, top}, {r.max.x, top}}); p = p.prev {
			joins.above = true
			top = p.rect.min.y
			if top < view.min.y { break }
		}
		for n := b.next; row_chosen(n) && row_joins_to({{r.min.x, bottom}, {r.max.x, bottom}}, n.rect); n = n.next {
			joins.below = true
			bottom = n.rect.max.y
			if bottom > view.max.y { break }
		}
	}
	face = row_face_rect(r, inset, gap, joins)
	radii = row_face_radii(face, radius, joins)
	run = row_face_rect({{r.min.x, top}, {r.max.x, bottom}}, inset, gap)
	run_radii = row_face_radii(run, radius)
	return
}

// The face a row draws: its selection (.Chosen: its background) or none at rest, in its state (face_of, with its tags'
// steps), over its ground and what is under it.
row_face :: proc(s: ^State, b: ^Box) -> Face {
	chosen := row_chosen(b)
	rest := chosen ? b.bg : Color{}
	under := b.parent != nil ? box_under(b.parent) : s.backdrop
	if !chosen && .Draw_Background in b.flags && b.bg.a > ROW_EPS { under = face_over(b.bg, under, s.space) }
	if .Draw_Hot_Effects not_in b.flags { return {color = rest} }
	hover := color_from_tags(s, b.tags_key, "hover_fill")
	press := color_from_tags(s, b.tags_key, "press_fill")
	return face_of(rest, under, {hover.r, hover.g, hover.b, 1}, face_state(b), hover.a, press.a, 0, s.space)
}

// Draws row `b`'s ground (its background when it is not selected: a zebra's stripe, a row's tint; square, edge to edge)
// and its face, in the finish; a navigation's selected row its accent's bar.
@(private)
row_draw :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	r := b.rect
	chosen := row_chosen(b)
	if !chosen && .Draw_Background in b.flags && b.bg.a > ROW_EPS { draw.rect(dc, r, b.bg) }
	f := row_face(s, b)
	if f.color.a <= ROW_EPS { return }
	_, _, run, run_radii, joins := row_face_of(s, b)
	// (a piece of a block paints the block clipped to its own rect: the finish's light runs over the block once)
	joined := joins.above || joins.below
	if joined { draw.push_clip(dc, r) }
	defer if joined { draw.pop_clip(dc) }
	// a selected face is a plate, one under the pointer alone a hint of it
	k: f32 = chosen ? 1 : ROW_HOVER_SHARE
	accent := color_from_tags(s, b.tags_key, "accent")
	row_face_paint(dc, run, run_radii, f.color, k, f.sunk, chosen ? accent : Color{})
	if chosen {
		if mark := color_from_tags(s, b.tags_key, "row_mark"); mark.a > ROW_EPS {
			// (it fades with the selection: the share of the selection's colour shown)
			if b.target_bg.a > ROW_EPS { mark.a *= clamp(b.bg.a / b.target_bg.a, 0, 1) }
			row_mark_paint(dc, run, mark)
		}
	}
}

// Paints a row's face `c` on `r` in the finish shown: `k` its strength (1 selected, less under the pointer alone),
// `sunk` pressed in, `edge` the accent's fine edge of a selection in glass (alpha 0: none).
row_face_paint :: proc(dc: ^draw.Context, r: Rect, radii: [4]f32, c: Color, k, sunk: f32, edge := Color{}) {
	s := gs()
	finish := s.theme != nil ? s.theme.finish : .Flat
	if r.max.y - r.min.y < 2 || c.a <= ROW_EPS { return }
	p := max(1, math.round(s.scale))
	switch finish {
	case .Flat, .Bevel:   // (Windows 95's selected row is a plain block)
		draw.rect_corners(dc, r, colors4(c), radii)
	case .Gradient:
		lit_face(dc, r, c, radii, ROW_GRADIENT_TOP_WHITE * k, ROW_GRADIENT_BOTTOM_BLACK * k, ROW_GRADIENT_RIM_ALPHA * k, sunk)
	case .Glass:
		// a calm gloss: the upper part a little whiter, the lower the colour itself; a rim of light; a selection's
		// fine edge of the accent (the full plate of a button, its gloss and its white rim, shouted behind text)
		top := srgb_step(c, {1, 1, 1, 1}, ROW_GLASS_TOP_WHITE * k * (1 - sunk))
		mid := draw.mix(top, c, 0.6)
		h := r.max.y - r.min.y
		split := math.round(r.min.y + h * 0.5)
		draw.rect_corners(dc, {r.min, {r.max.x, split}}, {top, mid, top, mid}, {radii[0], 0, radii[2], 0})
		draw.rect_corners(dc, {{r.min.x, split}, r.max}, colors4(c), {0, radii[1], 0, radii[3]})
		if sunk < 1 && h >= 4 {
			lit := tuned({1, 1, 1, ROW_GLASS_RIM_ALPHA * k * c.a * (1 - sunk)}, top)
			draw.rect_corners(dc, draw.rect_pad(r, -p), {lit, {1, 1, 1, 0}, lit, {1, 1, 1, 0}}, radii_grown(radii, -p), p)
		}
		if edge.a > ROW_EPS {
			e := Color{edge.r, edge.g, edge.b, ROW_GLASS_EDGE_ALPHA * c.a}
			draw.rect_corners(dc, r, colors4(tuned(e, c)), radii, p)
		}
	case .Machined:
		top := srgb_step(c, {1, 1, 1, 1}, ROW_PLATE_TOP_WHITE * k)
		bot := relief_darken(c, ROW_PLATE_BOTTOM_BLACK * k)
		if sunk > ROW_EPS { top, bot = draw.mix(top, bot, sunk), draw.mix(bot, top, sunk * 0.5) }
		draw.rect_corners(dc, r, {top, bot, top, bot}, radii)
		if r.max.y - r.min.y < 4 { return }
		// a lit line along its top, off the corners: a low plate, not a key. (A rim down its sides, and a dark edge round
		// a face under the pointer, outlined it as a field.) Selected, a faint edge of the relief's dark sets the block
		// off the surface.
		rim := relief_shine(ROW_PLATE_RIM_ALPHA * k * (1 - sunk))
		rim.a *= c.a
		inset := max(p, max(radii[0], radii[2]) * 0.8)
		draw.rect(dc, {{r.min.x + inset, r.min.y + p}, {r.max.x - inset, r.min.y + 2 * p}}, rim)
		if k >= 1 {
			e := relief_shade(ROW_PLATE_EDGE_ALPHA)
			e.a *= c.a
			draw.rect_corners(dc, r, colors4(e), radii, p)
		}
	case .Edged:
		top := srgb_step(c, {1, 1, 1, 1}, ROW_PLATE_TOP_WHITE * k)
		bot := relief_darken(c, ROW_PLATE_BOTTOM_BLACK * k)
		if sunk > ROW_EPS { top, bot = draw.mix(top, bot, sunk), draw.mix(bot, top, sunk * 0.5) }
		draw.rect_corners(dc, r, {top, bot, top, bot}, radii)
		if r.max.y - r.min.y < 4 { return }
		// crisp: a lit hairline along its top, a shade line along its bottom (the turn over when pressed)
		hi, lo := relief_shine(ROW_EDGED_RIM_ALPHA * k), relief_shade(ROW_EDGED_SHADE_ALPHA * k)
		if sunk >= 0.5 { hi, lo = relief_shade(ROW_EDGED_SHADE_ALPHA * k), Color{} }
		hi.a *= c.a
		lo.a *= c.a
		inset := max(p, radii[0] * 0.6)
		draw.rect(dc, {{r.min.x + inset, r.min.y}, {r.max.x - inset, r.min.y + p}}, hi)
		if lo.a > 0 { draw.rect(dc, {{r.min.x + inset, r.max.y - p}, {r.max.x - inset, r.max.y}}, lo) }
	}
}

// The accent's bar of a navigation's selected row: short, rounded, just inside the face's leading edge (on the edge,
// it read as a part of the face sticking out of it), centred on its height.
@(private = "file")
row_mark_paint :: proc(dc: ^draw.Context, face: Rect, c: Color) {
	p := max(1, math.round(gs().scale))
	w := math.round(ROW_MARK_PX * max(1, gs().scale))
	h := math.round(min(face.max.y - face.min.y, gs().scale * ROW_MARK_TALLEST_PX) * ROW_MARK_HEIGHT)
	cy := (face.min.y + face.max.y) * 0.5
	y0 := math.round(cy - h * 0.5)
	x0 := face.min.x + ROW_MARK_INSET_PX * p
	draw.rect(dc, {{x0, y0}, {x0 + w, y0 + h}}, c, w * 0.5)
}
