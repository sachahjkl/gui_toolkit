package ui

import "core:math"
import "../draw"

// The look of every row of tabs of the toolkit (src/md/features/tabs.md): `ui.tabs`, a dock's stack, a stack of views.
//
// The strip's bottom edge is a line, its container's top border (the box the tabs stand in draws it: `tab_line_draw`). The chosen
// tab rises out of that line as one shape with the panel under it: its outline climbs from the line through a concave
// fillet at each foot, rounds over its top and comes down to the line again; inside it is the page (the panel's ground),
// with the finish's light at its top, and no line under it. The other tabs have no face: a faint rounded outline on the
// line, filled with the theme's hover step under the pointer.

// Above the chosen tab, a share of the strip's height (the strip's own ground shows there).
@(private = "file") TAB_TOP_SHARE :: 0.16
// A foot's fillet, a share of the tab's top radius.
@(private = "file") TAB_FOOT_SHARE :: 0.8
// An unchosen tab's outline: the border's alpha, and how much lower its top is than the chosen tab's (logical px).
@(private = "file") TAB_SOFT_EDGE_ALPHA :: 0.45
@(private = "file") TAB_SOFT_DROP_PX :: 2
@(private = "file") TAB_SOFT_GAP_PX :: 1   // between an unchosen tab's outline and a chosen tab's foot (logical px)
// The finish's light at the chosen tab's top: its face a step toward white at the top, its rim (machined, edged).
@(private = "file") TAB_TOP_LIGHTEN :: 0.05
@(private = "file") TAB_RIM_ALPHA :: 0.10

// The radius of a tab's top corners in the size in use: the theme's control radius (a dense scope's smaller em gives a
// tighter one; tab_draw keeps it under a third of the strip).
@(private)
tab_radius :: proc() -> f32 { return math.round(font_size() * shape_of(.Control)) }

// A row of tabs' line, as the custom draw of the box its tabs stand in: along its bottom, in its border's colour. Not
// .Draw_Side_Bottom: a box's sides are drawn after its children, and the chosen tab must cover the line under it.
tab_line_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	p := px1()
	draw.rect(dc, {{b.rect.min.x, b.rect.max.y - p}, b.rect.max}, b.border)
}

// What a chosen tab's foot reaches beyond its box on each side (none at the strip's ends: there its side is straight).
@(private)
tab_foot :: proc() -> f32 { return math.round(font_size() * shape_of(.Control) * TAB_FOOT_SHARE) }

// One tab, as wide as what the caller builds in it (`if parent(b)`): a Tab stop the strip's whole height. The caller
// pushes "weak" around the words of an unchosen tab. `flags` adds to the tab's own.
@(private)
tab_box :: proc(id: string, on: bool, flags: Box_Flags = {}) -> ^Box {
	s := gs()
	set_next_axis(.X, .End)   // (its content in tab_body, at its bottom: the visible part of its shape)
	s.next_mod.width = children_sum()
	s.next_mod.height = pct(1)
	s.next_mod.radius = 0
	push_tags(on ? "tab_on" : "tab")
	b := build_box(Box_Flags{.Clickable, .Focusable} + flags, id)
	pop_tags()
	td := frame_new(Tab_Draw)
	td^ = {on = on, radius = tab_radius(), foot = tab_foot()}
	b.custom, b.custom_user = tab_draw, td
	b.ring_at = tab_ring   // (the focus goes round the shape a person sees, not the strip's height)
	// (a strip's view as wide as its tabs would cut the chosen tab's feet at its ends: its clip lets them out)
	if on && b.parent != nil && .Clip in b.parent.flags { b.parent.clip_overhang = max(b.parent.clip_overhang, td.foot) }
	return b
}

// `if parent(tab) { if tab_body() { ... } }`: the row a tab's content goes in, as tall as the visible part of its shape
// (the strip's ground shows above the shape), the content centred across it: the words sit in the middle of the shape,
// not of the strip.
@(private, require_results, deferred_none = pop_parent)
tab_body :: proc() -> bool {
	next({width = children_sum(), height = pct(1 - TAB_TOP_SHARE)})
	set_next_axis(.X, .Center)
	push_parent(build_box({}, "###tab_body"))
	return true
}

@(private)
Tab_Draw :: struct { on: bool, radius, foot: f32 }

// A tab's visible shape for its focus ring: from its top (under the strip's ground) down to the line, its top corners
// rounded as the shape's.
@(private = "file")
tab_ring :: proc(b: ^Box) -> (ring: Rect, radii: [4]f32) {
	td := (^Tab_Draw)(b.custom_user)
	r := b.rect
	top := tab_top(r)
	rad := min(td.radius, (r.max.y - r.min.y) / 3)
	return {{r.min.x, top}, r.max}, {rad, 0, rad, 0}   // (Corner's order: top left, bottom left, top right, bottom right)
}

// The y of a tab's top edge (the strip's ground shows above it), on a whole pixel.
@(private = "file")
tab_top :: proc(r: Rect) -> f32 { return math.round(r.min.y + (r.max.y - r.min.y) * TAB_TOP_SHARE) }

@(private)
tab_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	td := (^Tab_Draw)(user)
	s := gs()
	p := px1()
	r := b.rect
	rad := min(td.radius, (r.max.y - r.min.y) / 3)
	line := r.max.y - p * 0.5   // the middle of the strip's line
	top := tab_top(r) + p * 0.5
	edge := color_from_tags(s, b.tags_key, "border")
	// (a tab at an end of its strip: no foot on that side, its side straight down the strip's end, in line with its panel's
	// edge: the first tab starts at the edge, no room is lost before it)
	first, last := tab_at_ends(b, p)
	// (everything of the shape stops at the line's top edge: a stroke's round end at the line's middle spilled into the
	// line and under it; the line is the strip's, only the chosen tab's own width covers it, below)
	reach := td.foot + 2 * p
	draw.push_clip(dc, {{r.min.x - reach, r.min.y}, {r.max.x + reach, r.max.y - p}})
	defer draw.pop_clip(dc)
	if td.on {
		foot := min(td.foot, rad)
		left, right := first ? 0 : foot, last ? 0 : foot
		outline := tab_outline(r.min.x, r.max.x, top, line, rad, left, right)
		// the face: the page, joined to the panel (down past the strip's line, which it covers), the finish's light at its top
		face := color_from_tags(s, b.tags_key, "background")
		face.a = 1
		fill := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&fill, {r.min.x - left, r.max.y})
		for q in outline.points { draw.path_line_to(&fill, q) }
		draw.path_line_to(&fill, {r.max.x + right, r.max.y})
		draw.path_close(&fill)
		lit := s.theme != nil && s.theme.relief.sheen
		if lit {
			draw.push_clip_polygon(dc, fill.points[:])
			hi := lighten(face, TAB_TOP_LIGHTEN)
			draw.rect_corners(dc, draw.path_bounds(&fill), {hi, face, hi, face}, {})
			draw.pop_clip(dc)
		} else {
			draw.path_fill(dc, &fill, face)
		}
		// under the tab itself (not its feet) the line goes: the tab and its panel are one shape
		draw.pop_clip(dc)
		draw.rect(dc, {{r.min.x, r.max.y - p}, r.max}, face)
		draw.push_clip(dc, {{r.min.x - reach, r.min.y}, {r.max.x + reach, r.max.y - p}})
		// the finish's rim along the inside of its top (machined, edged): the light a raised face catches. Every stroke here
		// is opaque, mixed over what it lies on: a translucent path_stroke draws through a layer of its own, a render target
		// a tab and a frame
		if machined() && rad > p {
			rim := draw.path_make(allocator = context.temp_allocator)
			draw.path_arc(&rim, {r.min.x + rad, top + rad}, {rad - p, rad - p}, 0.5, 0.75)
			draw.path_arc(&rim, {r.max.x - rad, top + rad}, {rad - p, rad - p}, 0.75, 1)
			draw.path_stroke(dc, &rim, p, face_over(relief_shine(TAB_RIM_ALPHA), lit ? lighten(face, TAB_TOP_LIGHTEN) : face, s.space))
		}
		draw.path_stroke(dc, &outline, p, face_over(edge, box_under(b), s.space))
		return
	}
	// an unchosen tab: its outline inside the room the chosen tabs' feet take, lower, no feet
	gap := td.foot + math.round(TAB_SOFT_GAP_PX * s.scale)
	x0, x1 := first ? r.min.x : r.min.x + gap, last ? r.max.x : r.max.x - gap
	if x1 - x0 <= 2 * rad { return }
	soft := tab_outline(x0, x1, top + math.round(TAB_SOFT_DROP_PX * s.scale), line, rad, 0, 0)
	if hot := max(box_hot(b), box_held(b)); hot > 0.01 {
		under := box_under(b)
		fill := draw.mix(under, state_fill(b, box_held(b) > 0.5 ? "press_fill" : "hover_fill", under), hot)
		shape := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&shape, soft.points[0])
		for q in soft.points[1:] { draw.path_line_to(&shape, q) }
		draw.path_close(&shape)
		draw.path_fill(dc, &shape, fill)
	}
	draw.path_stroke(dc, &soft, p, face_over(with_alpha(edge, TAB_SOFT_EDGE_ALPHA), box_under(b), s.space))
}

// Whether `b` stands at the start or the end of its row's line, where the panel under it has its edge (`p`: a device
// pixel's slack). The line is the outermost box on the tab's baseline that draws one: `ui.tabs` draws one under its
// own strip, as wide as its tabs, and a program's row around it draws the whole one (fidget, the debug window).
@(private = "file")
tab_at_ends :: proc(b: ^Box, p: f32) -> (first, last: bool) {
	line: ^Box
	for a := b.parent; a != nil; a = a.parent {
		draws := a.custom == tab_line_draw || a.custom == dock_strip_draw || a.custom == dense_header_draw
		if draws && abs(a.rect.max.y - b.rect.max.y) <= p { line = a }
	}
	if line == nil { return }
	return b.rect.min.x <= line.rect.min.x + p * 0.5, b.rect.max.x >= line.rect.max.x - p * 0.5
}

// A tab's outline, open, left to right: from the strip's line at `x0 - left` up through a concave fillet, round over its
// top at `top` with corners of `rad`, and down through the other fillet to the line at `x1 + right`; a foot of 0: that
// side straight down to the line (temp memory).
@(private = "file")
tab_outline :: proc(x0, x1, top, line, rad, left, right: f32) -> draw.Path {
	o := draw.path_make(allocator = context.temp_allocator)
	// (angles in turns from +x, y down: 0.25 points down, 0.5 left, 0.75 up)
	if left > 0 {
		draw.path_arc(&o, {x0 - left, line - left}, {left, left}, 0.25, 0)
	} else {
		draw.path_move_to(&o, {x0, line})
	}
	draw.path_arc(&o, {x0 + rad, top + rad}, {rad, rad}, 0.5, 0.75)
	draw.path_arc(&o, {x1 - rad, top + rad}, {rad, rad}, 0.75, 1)
	if right > 0 {
		draw.path_arc(&o, {x1 + right, line - right}, {right, right}, 0.5, 0.25)
	} else {
		draw.path_line_to(&o, {x1, line})
	}
	return o
}
