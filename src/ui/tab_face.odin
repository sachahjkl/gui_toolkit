package ui

import "core:math"
import "../draw"

// The face of a tab in every row of tabs (src/md/features/tabs.md, tab-styles.md): `ui.tabs`, a dock's stack, a stack of
// views, a program's own strip. Its style and the surface it frames are the strip's (tabs_over); tab_style.odin draws
// every style but the Folder's chosen tab, drawn here: it rises out of the strip's line as one shape with its panel, its
// outline climbing from the line through a concave fillet at each foot, rounding over its top and coming down again;
// inside it the surface's ground, and no line under it.

// Above a Folder's tab, a share of the strip's height (the strip's own ground shows there).
@(private) TAB_TOP_SHARE :: 0.16
// A Folder's foot's fillet, a share of the tab's top radius.
@(private = "file") TAB_FOOT_SHARE :: 0.8
// A Folder's unchosen tab under the pointer: its fill's top this much lower than a chosen tab's (logical px).
@(private) TAB_HOVER_DROP_PX :: 2
// The accent of a marked chosen Folder tab (tab_face's `mark`): logical pixels along its top.
@(private = "file") TAB_MARK_PX :: 2

// The radius of a tab's top corners in the size in use: the theme's control radius (a dense scope's smaller em gives a
// tighter one; tab_draw keeps it under a third of the strip).
@(private)
tab_radius :: proc() -> f32 { return math.round(font_size() * shape_of(.Control)) }

// What a Folder's chosen tab's foot reaches beyond its box on each side.
@(private)
tab_foot :: proc() -> f32 { return math.round(font_size() * shape_of(.Control) * TAB_FOOT_SHARE) }

// A Folder's line, as the custom draw of the box its tabs stand in: along its bottom, in its border's colour (a
// Tab_Strip_Look as `user`: its edge, and nothing for a style with no line). Not .Draw_Side_Bottom: a box's sides are
// drawn after its children, and the chosen tab must cover the line under it.
tab_line_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	if user != nil { tab_strip_paint(b, (^Tab_Strip_Look)(user), dc, false); return }
	p := px1()
	bottom := math.round(b.rect.max.y)   // (on whole pixels, as tab_draw puts its own stroke of the line)
	draw.rect(dc, {{b.rect.min.x, bottom - p}, {b.rect.max.x, bottom}}, b.border)
}

// A strip's ground (and a Folder's line), as the custom draw of the box its tabs stand in (with .Draw_Background and
// .Custom_Ground: its background is the ground the boxes in it stand on, painted here). `user`: its Tab_Strip_Look
// (tab_strip_look: the style's ground, the surface under Underline and Segmented, the band under Header); nil: the
// bar's colour and the line. A strip is a bar, never a key: a bar's face in a finish with a relief has a lit rim, which
// framed the strip as a button (Tower's bottom terminal).
tab_strip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	if user != nil { tab_strip_paint(b, (^Tab_Strip_Look)(user), dc, true); return }
	draw.rect(dc, b.rect, b.bg)
	tab_line_draw(b, nil, dc)
}

// One tab, as wide as what the caller builds in it (`if parent(b)`): a Tab stop the strip's whole height. The caller
// pushes "weak" around the words of an unchosen tab. `flags` adds to the tab's own. In a strip too short for its tabs
// it gives way down to what its content keeps (its words sized by tab_title_width), before the strip scrolls.
@(private)
tab_box :: proc(id: string, on: bool, flags: Box_Flags = {}) -> ^Box {
	s := gs()
	if !s.has_next { s.next_mod = {} }
	s.next_mod.width = children_sum(0)
	s.next_mod.height = pct(1)
	s.has_next = true
	b := build_box(Box_Flags{.Clickable, .Focusable} + flags, id)
	tab_face(b, on)
	return b
}

// The face of a tab on a program's own box `b` (its size, its presses, its drags and its content stay the program's), in
// the style and on the surface of the tabs_over around it (none: .Folder on the page): the tab's colours whatever tags
// the box was built under, the focus ring round the visible shape, the box's children in a row (their place: tab_body).
// `mark`: the chosen tab of the panel that has the keyboard (a zero colour: none): a Folder's band along its top, an
// Underline's bar or a Header's accent in that colour. Call it right after building the box, in the same build. The
// strip: tab_strip_draw on it with tab_strip_look, tab_strip_start before its first tab (docs/widgets.md).
tab_face :: proc(b: ^Box, on: bool, mark := Color{}) {
	if b == nil { return }
	s := gs()
	push_tags(on ? "tab_on" : "tab")
	b.tags_key = current_tags_key(s)
	b.target_bg, b.target_border, b.target_text = color("background"), color("border"), color("text")
	pop_tags()
	sc := tab_scope_now()
	sf := tab_surface_now()
	folder := sc.style == .Folder
	b.layout_axis, b.cross = .X, folder ? .End : .Center   // (a Folder's content at its bottom: the visible part of its shape)
	b.radius = 0
	td := frame_new(Tab_Draw)
	td^ = {on = on, radius = tab_radius(), foot = tab_foot(), em = font_size(), mark = mark, style = sc.style, ground = sf.ground, edge = sf.edge, accent = color("accent")}
	td.under = tab_strip_ground(sc.style, sf, {})
	b.custom, b.custom_user = tab_draw, td
	b.ring_at = tab_ring   // (the focus goes round the shape a person sees, not the strip's height)
	if b.parent != nil && .Clip in b.parent.flags {
		// (a strip's view as wide as its tabs would cut a chosen Folder's feet, a track's ends: its clip lets them out)
		if on && folder { b.parent.clip_overhang = max(b.parent.clip_overhang, td.foot) }
		if sc.style == .Segmented { b.parent.clip_overhang = max(b.parent.clip_overhang, math.round(TAB_TRACK_PAD_PX * s.scale)) }
	}
}

// `if parent(tab) { if tab_body() { ... } }`: the row a tab's content goes in, its content centred across it: a Folder's
// as tall as the visible part of its shape (the strip's ground shows above it), the others' the strip's height. Its
// width is its content's (it gives way with the tab: children_sum(0)).
@(require_results, deferred_none = pop_parent)
tab_body :: proc() -> bool {
	next({width = children_sum(0), height = pct(tab_style_now() == .Folder ? 1 - TAB_TOP_SHARE : 1)})
	set_next_axis(.X, .Center)
	push_parent(build_box({}, "###tab_body"))
	return true
}

// A tab's words keep at least this much (ems) of their width when the strip is short; a shorter text keeps all of it.
TAB_TITLE_LEAST_EM :: 3

// The width of a tab's words `text` (an id's words: what shows of it), with `pad` on each side beyond the box's text
// pad, as text_size: their own, and in a strip too short for its tabs they give way, cut with an ellipsis, down to
// TAB_TITLE_LEAST_EM of text. `text_pad`: the one the caller gives the box in `next` (negative: the style's).
tab_title_width :: proc(text: string, pad: f32 = 0, text_pad: f32 = -1) -> Size {
	whole := font_text_width(text)
	sides := 2 * (pad + (text_pad >= 0 ? text_pad : top_style().text_pad))
	return {kind = .Text, value = pad, strictness = 0, least = math.ceil(min(whole, font_size() * TAB_TITLE_LEAST_EM) + sides)}
}

// What a tab's draw needs, read in the build (a draw has no tags: the colours are taken here).
@(private)
Tab_Draw :: struct {
	on:               bool,
	radius, foot, em: f32,
	mark:             Color,
	style:            Tab_Style,
	ground, edge:     Color,   // the surface it frames (tab_surface_now)
	under:            Color,   // the strip's ground under it (zero: the bar's, box_under)
	accent:           Color,   // the chosen tab's bar (Underline, Header)
}

// A tab's visible shape for its focus ring: a Folder's from its top (under the strip's ground) down to the line, its top
// corners rounded as the shape's; a Segmented's key; the others' box.
@(private = "file")
tab_ring :: proc(b: ^Box) -> (ring: Rect, radii: [4]f32) {
	td := (^Tab_Draw)(b.custom_user)
	r := b.rect
	switch td.style {
	case .Folder:
		rad := min(td.radius, (r.max.y - r.min.y) / 3)
		return {{r.min.x, tab_top(r)}, r.max}, {rad, 0, rad, 0}   // (Corner's order: top left, bottom left, top right, bottom right)
	case .Segmented:
		inset := math.round((r.max.y - r.min.y) * TAB_KEY_INSET_SHARE)
		kr := min(td.radius, (r.max.y - r.min.y - 2 * inset) / 2)
		return {{r.min.x, r.min.y + inset}, {r.max.x, r.max.y - inset}}, {kr, kr, kr, kr}
	case .Underline, .Header:
	}
	return r, {}
}

// The y of a Folder tab's top edge (the strip's ground shows above it), on a whole pixel.
@(private = "file")
tab_top :: proc(r: Rect) -> f32 { return math.round(r.min.y + (r.max.y - r.min.y) * TAB_TOP_SHARE) }

// Draws a tab. A Folder's chosen tab: every coordinate of a stroke sits on its pixel centre (snap: a half pixel for a
// 1 px stroke, a whole one for 2 px), so the line stays crisp and the arcs, whose radii are whole pixels, land on it. The
// line and its outline are one path, stroked once, from the strip's left end along the line, up the left fillet (tangent
// to the line, then to the side), over the top, down the right fillet and along the line to the strip's right end; round
// joins inside, no cap at a foot (the ends are cut by the strip's clip). Its fill, the surface's ground, is the same shape
// closed along the line's bottom edge, drawn before the stroke: it covers the line under the tab and nothing below. No
// light of the finish: the tab is its panel's surface, and a lighter top was not its colour.
@(private)
tab_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	td := (^Tab_Draw)(user)
	if td.under.a <= 0 { td.under = box_under(b) }
	if td.style != .Folder || !td.on {
		tab_draw_style(b, td, dc)
		return
	}
	s := gs()
	p := px1()
	r := b.rect
	rad := min(td.radius, (r.max.y - r.min.y) / 3)
	strip := tab_line_rect(b, td.foot + 2 * p)
	bottom := math.round(strip.max.y)   // the line's bottom edge
	line := bottom - p * 0.5            // the line's middle: its stroke's centre
	top := tab_snap(tab_top(r) + p * 0.5, p)
	edge := face_over(td.edge, box_under(b), s.space)
	foot := min(td.foot, rad)
	xl, xr := tab_snap(r.min.x + p * 0.5, p), tab_snap(r.max.x - p * 0.5, p)
	shape := tab_shape(xl, xr, top, line, rad, foot)
	draw.push_clip(dc, {{strip.min.x, r.min.y}, {strip.max.x, bottom}})
	defer draw.pop_clip(dc)
	face := td.ground
	face.a = 1
	fill := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&fill, shape.points[0])
	for q in shape.points[1:] { draw.path_line_to(&fill, q) }
	draw.path_line_to(&fill, {xr + foot, bottom})
	draw.path_line_to(&fill, {xl - foot, bottom})
	draw.path_close(&fill)
	draw.path_fill(dc, &fill, face)
	// (the mark: a band along the top, inside the shape: its rounded corners keep it)
	if td.mark.a > 0 {
		draw.push_clip_polygon(dc, fill.points[:])
		band := max(p, math.round(TAB_MARK_PX * s.scale))
		draw.rect(dc, {{xl - p, top - p}, {xr + p, top + band}}, td.mark)
		draw.pop_clip(dc)
	}
	// the line and the outline, one path (opaque, mixed over what it lies on: a translucent path_stroke draws through a
	// layer of its own)
	outline := draw.path_make(allocator = context.temp_allocator)
	draw.path_move_to(&outline, {strip.min.x - p, line})
	for q in shape.points { draw.path_line_to(&outline, q) }
	draw.path_line_to(&outline, {strip.max.x + p, line})
	draw.path_stroke(dc, &outline, p, edge)
}

// `v` moved to the nearest centre of a `p`-wide stroke: a half pixel when `p` is odd, a whole one when it is even.
@(private = "file")
tab_snap :: proc(v, p: f32) -> f32 { return math.round(v - p * 0.5) + p * 0.5 }

// The rect of the box that draws a Folder's line (its strip): the outermost on the tab's baseline whose custom draw is
// a line (`ui.tabs` draws one under its own strip, a program's row around it the whole one). None: the tab's own rect,
// `reach` wider on each side (a tab_panel: its frame draws the line, the tab strokes its own part of it).
@(private = "file")
tab_line_rect :: proc(b: ^Box, reach: f32) -> Rect {
	r := Rect{{b.rect.min.x - reach, b.rect.min.y}, {b.rect.max.x + reach, b.rect.max.y}}
	for a := b.parent; a != nil; a = a.parent {
		draws := a.custom == tab_line_draw || a.custom == tab_strip_draw
		if draws && abs(a.rect.max.y - b.rect.max.y) <= 1 { r = a.rect }
	}
	return r
}

// The room before a row's first tab, in the style of the tabs_over around it (tab_style_inset).
@(private)
tab_strip_inset :: proc() -> f32 { return tab_style_inset(tab_style_now()) }

// Built first in a row of tabs' strip (a program's own too): the room before its first tab (a Folder's foot and a short
// run of the line, a Segmented track's pad, nothing for the others).
tab_strip_start :: proc() { spacer(px(tab_strip_inset())) }

// A Folder tab's shape, open, left to right (temp memory): from the line at `x0 - foot` up through a concave fillet
// tangent to the line and to the side, round over its top at `top` with corners of `rad`, down through the other fillet
// to the line at `x1 + foot`. `line` and the sides are stroke centres (tab_snap); `rad` and `foot` whole pixels.
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
