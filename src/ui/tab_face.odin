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
// The line's straight run between a pane's edge and the first tab's left foot (logical px).
@(private = "file") TAB_LINE_LEAD_PX :: 3
// A foot's fillet, a share of the tab's top radius.
@(private = "file") TAB_FOOT_SHARE :: 0.8
// An unchosen tab's outline: the border's alpha, and how much lower its top is than the chosen tab's (logical px).
@(private = "file") TAB_SOFT_EDGE_ALPHA :: 0.45
@(private = "file") TAB_SOFT_DROP_PX :: 2
@(private = "file") TAB_SOFT_FOOT_SHARE :: 0.5   // an unchosen tab's fillets, a share of the chosen tab's
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
	bottom := math.round(b.rect.max.y)   // (on whole pixels, as tab_draw puts its own stroke of the line)
	draw.rect(dc, {{b.rect.min.x, bottom - p}, {b.rect.max.x, bottom}}, b.border)
}

// A strip of tabs' ground and line, as the custom draw of the box its tabs stand in (with .Draw_Background and
// .Custom_Ground: its background is the ground the boxes in it stand on, painted here): the bar's colour, flat, then the
// line. A strip is a bar, never a key: the bar's face in a finish with a relief has a lit rim, which framed the strip as
// a button (Tower's bottom terminal).
tab_strip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	draw.rect(dc, b.rect, b.bg)
	tab_line_draw(b, user, dc)
}

// What a chosen tab's foot reaches beyond its box on each side.
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

// Draws a tab. Every coordinate of a stroke sits on its pixel centre (snap: a half pixel for a 1 px stroke, a whole one for
// 2 px), so the line stays crisp and the arcs, whose radii are whole pixels, land on it.
//
// The chosen tab: the line and its outline are one path, stroked once, from the strip's left end along the line, up the
// left fillet (tangent to the line, then to the side), over the top, down the right fillet and along the line to the
// strip's right end; round joins inside, no cap at a foot (the ends are cut by the strip's clip). Its fill is the same
// shape closed along the line's bottom edge, drawn before the stroke: it covers the line under the tab and nothing below.
// An unchosen tab: its outline ends tangent on the line through small fillets, cut at the line's top edge: it flows into
// the line and never draws on it (the line is the strip's colour, the outline a fainter one).
@(private)
tab_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	td := (^Tab_Draw)(user)
	s := gs()
	p := px1()
	r := b.rect
	rad := min(td.radius, (r.max.y - r.min.y) / 3)
	strip := tab_line_rect(b, td.foot + 2 * p)
	bottom := math.round(strip.max.y)   // the line's bottom edge
	line := bottom - p * 0.5            // the line's middle: its stroke's centre
	top := tab_snap(tab_top(r) + p * 0.5, p)
	edge := face_over(color_from_tags(s, b.tags_key, "border"), box_under(b), s.space)
	if td.on {
		foot := min(td.foot, rad)
		xl, xr := tab_snap(r.min.x + p * 0.5, p), tab_snap(r.max.x - p * 0.5, p)
		shape := tab_shape(xl, xr, top, line, rad, foot)
		draw.push_clip(dc, {{strip.min.x, r.min.y}, {strip.max.x, bottom}})
		defer draw.pop_clip(dc)
		// the face: the page, joined to the panel, the finish's light at its top
		face := color_from_tags(s, b.tags_key, "background")
		face.a = 1
		fill := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&fill, shape.points[0])
		for q in shape.points[1:] { draw.path_line_to(&fill, q) }
		draw.path_line_to(&fill, {xr + foot, bottom})
		draw.path_line_to(&fill, {xl - foot, bottom})
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
		// the finish's rim along the inside of its top (machined, edged): the light a raised face catches. (Every stroke here
		// is opaque, mixed over what it lies on: a translucent path_stroke draws through a layer of its own.)
		if machined() && rad > p {
			rim := draw.path_make(allocator = context.temp_allocator)
			draw.path_arc(&rim, {xl + rad, top + rad}, {rad - p, rad - p}, 0.5, 0.75)
			draw.path_arc(&rim, {xr - rad, top + rad}, {rad - p, rad - p}, 0.75, 1)
			draw.path_stroke(dc, &rim, p, face_over(relief_shine(TAB_RIM_ALPHA), lit ? lighten(face, TAB_TOP_LIGHTEN) : face, s.space))
		}
		// the line and the outline, one path
		outline := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&outline, {strip.min.x - p, line})
		for q in shape.points { draw.path_line_to(&outline, q) }
		draw.path_line_to(&outline, {strip.max.x + p, line})
		draw.path_stroke(dc, &outline, p, edge)
		return
	}
	// an unchosen tab: inside the room the chosen tabs' feet take, lower, its own small feet
	soft_foot := max(math.round(td.foot * TAB_SOFT_FOOT_SHARE), p)
	gap := td.foot + math.round(TAB_SOFT_GAP_PX * s.scale) + soft_foot
	xl, xr := tab_snap(r.min.x + gap + p * 0.5, p), tab_snap(r.max.x - gap - p * 0.5, p)
	if xr - xl <= 2 * rad { return }
	soft := tab_shape(xl, xr, top + math.round(TAB_SOFT_DROP_PX * s.scale), line, rad, soft_foot)
	draw.push_clip(dc, {{strip.min.x, r.min.y}, {strip.max.x, bottom - p}})
	defer draw.pop_clip(dc)
	if hot := max(box_hot(b), box_held(b)); hot > 0.01 {
		under := box_under(b)
		fill := draw.mix(under, state_fill(b, box_held(b) > 0.5 ? "press_fill" : "hover_fill", under), hot)
		shape := draw.path_make(allocator = context.temp_allocator)
		draw.path_move_to(&shape, soft.points[0])
		for q in soft.points[1:] { draw.path_line_to(&shape, q) }
		draw.path_line_to(&shape, {xr + soft_foot, bottom})
		draw.path_line_to(&shape, {xl - soft_foot, bottom})
		draw.path_close(&shape)
		draw.path_fill(dc, &shape, fill)
	}
	draw.path_stroke(dc, &soft, p, face_over(with_alpha(edge, TAB_SOFT_EDGE_ALPHA), box_under(b), s.space))
}

// `v` moved to the nearest centre of a `p`-wide stroke: a half pixel when `p` is odd, a whole one when it is even.
@(private = "file")
tab_snap :: proc(v, p: f32) -> f32 { return math.round(v - p * 0.5) + p * 0.5 }

// The rect of the box that draws a tab's line (its strip): the outermost on the tab's baseline whose custom draw is a
// line (`ui.tabs` draws one under its own strip, a program's row around it the whole one). None: the tab's own rect,
// `reach` wider on each side.
@(private = "file")
tab_line_rect :: proc(b: ^Box, reach: f32) -> Rect {
	r := Rect{{b.rect.min.x - reach, b.rect.min.y}, {b.rect.max.x + reach, b.rect.max.y}}
	for a := b.parent; a != nil; a = a.parent {
		draws := a.custom == tab_line_draw || a.custom == tab_strip_draw || a.custom == dock_strip_draw || a.custom == dense_header_draw
		if draws && abs(a.rect.max.y - b.rect.max.y) <= 1 { r = a.rect }
	}
	return r
}

// The room before a row's first tab: its left foot's (tab_foot) and a short run of the line before the foot curves up
// (TAB_LINE_LEAD_PX), as the owner's sketch draws it. Every tab has its whole silhouette, the first included; this room
// is all a strip gives before it.
@(private)
tab_strip_inset :: proc() -> f32 { return tab_foot() + math.round(TAB_LINE_LEAD_PX * scale()) }

// Built first in a row of tabs' strip: the room before its first tab.
@(private)
tab_strip_start :: proc() { spacer(px(tab_strip_inset())) }

// A tab's shape, open, left to right (temp memory): from the line at `x0 - foot` up through a concave fillet tangent to the
// line and to the side, round over its top at `top` with corners of `rad`, down through the other fillet to the line at
// `x1 + foot`. `line` and the sides are stroke centres (tab_snap); `rad` and `foot` whole pixels.
@(private = "file")
tab_shape :: proc(x0, x1, top, line, rad, foot: f32) -> draw.Path {
	o := draw.path_make(allocator = context.temp_allocator)
	// (angles in turns from +x, y down: 0.25 points down, 0.5 left, 0.75 up)
	draw.path_arc(&o, {x0 - foot, line - foot}, {foot, foot}, 0.25, 0)
	draw.path_arc(&o, {x0 + rad, top + rad}, {rad, rad}, 0.5, 0.75)
	draw.path_arc(&o, {x1 - rad, top + rad}, {rad, rad}, 0.75, 1)
	draw.path_arc(&o, {x1 + foot, line - foot}, {foot, foot}, 0.5, 0.25)
	return o
}
