package ui

import "core:math"
import "../draw"
import "../font"
import "../platform"

// Paints the box tree built by the last build. Parents first, then children (later siblings on top);
// borders, focus rings and the disabled overlay are drawn after the children so they land above them.
// Opacity kept by disabled widgets. Tuned for blending in linear light, where the same alpha looks far more opaque over
// a dark background than over a light one, so it depends on the theme (and is adapted by `tuned` in an sRGB frame).
// Disabled boxes also switch to neutral colours (see build_box), so this only has to dim them a little.
DISABLED_KEEP_DARK :: 0.4
DISABLED_KEEP_LIGHT :: 0.65

// Rec. 709 luma of a colour.
@(private = "file") LUMA_R :: 0.2126
@(private = "file") LUMA_G :: 0.7152
@(private = "file") LUMA_B :: 0.0722
// A box lit by set_inspected.
@(private = "file") INSPECTED_FILL_COLOR :: Color{0.24, 0.55, 1, 0.28}
@(private = "file") INSPECTED_EDGE_COLOR :: Color{0.24, 0.55, 1, 0.9}

// The UI's translucent colors (hover tints, glows, sheens, scrollbars, theme entries with an alpha) are tuned for
// blending in linear light. Drawn into an sRGB target (render.Blend_Space.Srgb, a web browser's choice), `tuned`
// changes their alpha so they look the same over the theme's background (or `over`); corner gradients of the UI are
// interpolated in linear light in both spaces. The tree therefore looks the same in both spaces, except for
// antialiased edges and text, which follow the space.
tuned :: proc(c: Color, over: Maybe(Color) = nil) -> Color {
	if current == nil || current.space == .Linear { return c }
	o := c
	o.a = draw.alpha_like_linear(gs().space, c, c.a, over.? or_else gs().backdrop)
	return o
}

// Partial redraw of the tree: each frame, what every box draws is compared with what it drew the last frame, and only where a
// box changed, came or went is drawn again (draw.damage_auto: a box is a span keyed by its key). Custom draws are compared by
// what they draw too. On a renderer that supports it; off by default. host turns it on with Host.partial_redraw.
set_partial_redraw :: proc(s: ^State, on: bool) { s.partial_redraw = on }
partial_redraw :: proc(s: ^State) -> bool { return s.partial_redraw }

// What the last frame's partial redraw found: the parts of boxes that drew, those damaged, why a frame was whole, and the
// pixels drawn on this state's window.
damage_stats :: proc(s: ^State) -> draw.Damage_Auto_Stats { return s.damage.stats }

// Span ids of what draw_tree draws besides the boxes (box keys are hashes: these stand apart from them).
@(private = "file") SPAN_FRAME_OUTLINE :: 0x6f75_746c_696e_6531
@(private = "file") SPAN_AUTOSCROLL :: 0x6175_746f_7363_726c
@(private = "file") SPAN_INSPECTED :: 0x696e_7370_6563_7464

draw_tree :: proc(s: ^State, dc: ^draw.Context) {
	use(s)
	if s.partial_redraw {
		draw.set_partial_redraw(dc, true)
		s.partial_redraw_set = true
		draw.damage_auto(dc, &s.damage)
	} else if s.partial_redraw_set {
		draw.set_partial_redraw(dc, false)
		s.partial_redraw_set = false
		draw.damage_memory_reset(&s.damage)
	}
	bg := color_from_tags(s, 0, "background")
	s.space = draw.blend_space(dc)
	s.backdrop = {bg.r, bg.g, bg.b, 1}
	lum := clamp(LUMA_R * bg.r + LUMA_G * bg.g + LUMA_B * bg.b, 0, 1)
	s.disabled_keep = math.lerp(f32(DISABLED_KEEP_DARK), f32(DISABLED_KEEP_LIGHT), lum)
	if s.space != .Linear {
		s.disabled_keep = tuned(color_from_tags(s, 0, "text") * {1, 1, 1, 0} + {0, 0, 0, s.disabled_keep}).a
	}
	interp := draw.set_interpolation(dc, .Linear)
	if exploded_shown(s) {
		// (instead of the page: the author's view of its layers, exploded.odin)
		exploded_draw(s, dc)
		draw.set_interpolation(dc, interp)
		return
	}
	draw_box(s, dc, s.root, s.scale)
	if s.window != nil && s.root != nil && platform.needs_frame_outline(s.window) {
		// (a frame of the system's would be there: Linux with an integrated title bar)
		draw.damage_span_begin(dc, SPAN_FRAME_OUTLINE)
		draw.rect(dc, s.root.rect, color_from_tags(s, 0, "border"), 0, max(1, math.round(s.scale)))
		draw.damage_span_end(dc)
	}
	draw.damage_span_begin(dc, SPAN_AUTOSCROLL)
	autoscroll_draw(s, dc)   // the autoscroll anchor marker, over everything (autoscroll_region.odin)
	draw.damage_span_end(dc)
	if b := s.boxes[s.inspected]; s.inspected != 0 && box_current(s, b) {
		draw.damage_span_begin(dc, SPAN_INSPECTED)
		draw.rect(dc, b.rect, INSPECTED_FILL_COLOR)
		draw.rect(dc, b.rect, INSPECTED_EDGE_COLOR, 0, 1)
		draw.damage_span_end(dc)
	}
	if s.wireframe {
		// (over everything, as the inspected box: what the author looks at, never the program's)
		draw.damage_span_begin(dc, SPAN_INSPECTED)
		wireframe_draw(s, dc)
		draw.damage_span_end(dc)
	}
	draw.set_interpolation(dc, interp)
}

// Below these a state value or an alpha draws nothing.
@(private = "file") DRAW_INVISIBLE_EPS :: 0.001
@(private = "file") DISABLED_FADE_EPS :: 0.005
@(private = "file") FOCUS_T_EPS :: 0.01
@(private = "file") BORDER_ALPHA_EPS :: 0.002
@(private = "file") DROP_SHADOW_SPREAD_PX :: 8
@(private = "file") DROP_SHADOW_OFFSET_PX :: 4
@(private = "file") DROP_SHADOW_SOFT_PX :: 8
@(private = "file") FOCUS_GLOW_PX :: 5
@(private = "file") FOCUS_GLOW_ALPHA :: 0.55
@(private = "file") FOCUS_RING_PX :: 1.5

// The radius a box's corners are drawn with: its own times the state's rounding (set_rounding; none in the edged
// finish), square under ROUND_LEAST_PX, unless it is part of its shape (Fixed_Radius). What a box's custom draw rounds takes it too: its corners then
// meet the box's own and its parents'.
box_drawn_radius :: proc(s: ^State, b: ^Box) -> f32 {
	if .Fixed_Radius in b.flags { return b.radius }
	return radius_drawn(s, b.radius)
}

// A corner's radius as drawn: times the state's rounding (none in the edged finish), square under ROUND_LEAST_PX (a
// corner rounded at a pixel or two rounds nothing that shows: its antialiasing is a blob outside a 1 px edge's corner).
// What a widget's custom draw rounds a corner with goes through it (`rad`), its box's own included (box_drawn_radius).
radius_drawn :: proc(s: ^State, radius: f32) -> f32 {
	r := radius * rounding(s)
	return r < ROUND_LEAST_PX * max(1, scale()) ? 0 : r
}

// The radii a box is drawn with: its own, and at a corner where it fills the corner of a box around it that is rounded
// (a title bar's background in a dialog's corner, a header at the top of a card, a menu's search field), that box's:
// a box's square corner, or its own rounding, showed a second corner inside the one it fills. A box laid against its
// parent's border (inside it by the border's width) fills that corner too, and takes the radius less that inset, so
// that the two curves are concentric. The boxes around it are looked through while their corner is that one.
box_drawn_radii :: proc(s: ^State, b: ^Box) -> (radii: [4]f32) {
	radii = box_radii(box_drawn_radius(s, b), b.square_corners)
	CORNER_MEET_PX :: 0.5
	r := b.rect
	for c in Corner {
		left, top := c == .Top_Left || c == .Bottom_Left, c == .Top_Left || c == .Top_Right
		filled := false
		for a := b.parent; a != nil; a = a.parent {
			q := a.rect
			x := left ? abs(r.min.x - q.min.x) : abs(r.max.x - q.max.x)
			y := top ? abs(r.min.y - q.min.y) : abs(r.max.y - q.max.y)
			// (its border's width: what is laid inside a bordered box starts there)
			edge: f32 = .Draw_Border in a.flags ? max(1, math.round(s.scale)) : 0
			if x > edge + CORNER_MEET_PX || y > edge + CORNER_MEET_PX { break }
			// (a row's corner is not drawn: its face is inset in it, a cell at its corner stays square)
			if c in a.square_corners || .Row in a.flags { continue }
			ar := concentric_radius(box_drawn_radius(s, a), max(x, y))
			if ar <= 0 { continue }
			// (the corner it fills decides it: its own rounding there drew a second corner)
			if !filled || ar > radii[int(c)] { radii[int(c)] = ar }
			filled = true
		}
	}
	return
}

// The radius of a corner inset by `inset` from both edges of a corner of radius `outer`: the two curves are then concentric,
// and the gap between them is `inset` all along. Past the outer radius, the inner corner is square.
concentric_radius :: proc(outer, inset: f32) -> f32 { return max(outer - inset, 0) }

// A control of `size` in corner `c` of `outer` (drawn with corners of `outer_radius`), `inset` from both edges that meet
// there: the same margin from the side and from the top or bottom. `radius`: its corner there, concentric with `outer`'s.
corner_place :: proc(outer: Rect, outer_radius: f32, c: Corner, size: Vec2, inset: f32) -> (r: Rect, radius: f32) {
	left, top := c == .Top_Left || c == .Bottom_Left, c == .Top_Left || c == .Top_Right
	at := Vec2{left ? outer.min.x + inset : outer.max.x - inset - size.x, top ? outer.min.y + inset : outer.max.y - inset - size.y}
	return {at, at + size}, concentric_radius(outer_radius, inset)
}

// The least radius a box's corners are rounded with (logical pixels): under it, they are square.
ROUND_LEAST_PX :: 3

// `children` false: the box's own face alone, its subtree skipped (the exploded view draws each depth on its own plane).
@(private)
draw_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, scale: f32, children := true) {
	// (wholly transparent, it and what is in it show nothing: not drawn, it has no part for the partial redraw. Drawn at
	// alpha 0, a dialog's scrim still unseen was a part the size of the window, and redrew all of it: views.md 3.4)
	if b.transparency >= 1 { return }
	// (a swap draws its faces crossing, then itself through here again: swap.odin)
	if b.swap != nil && !b.swap.drawing && children { swap_draw(s, dc, b, scale); return }
	// what the box draws, its children apart, is compared with its last frame's (set_partial_redraw)
	draw.damage_span_begin(dc, u64(b.key))
	defer draw.damage_span_end(dc)
	r := b.rect
	radii := box_drawn_radii(s, b)
	flags := b.flags
	if b.transparency != 0 { draw.push_alpha(dc, 1 - b.transparency) }
	// disabled: the outermost disabled box fades itself and its subtree (nested disabled boxes do not compound)
	fade := b.disabled_t > DISABLED_FADE_EPS && (b.parent == nil || b.parent.disabled_t <= DISABLED_FADE_EPS)
	if fade { draw.push_alpha(dc, math.lerp(f32(1), s.disabled_keep, b.disabled_t)) }
	squished := b.squish > DRAW_INVISIBLE_EPS
	if squished { draw.push_scale(dc, draw.rect_center(r), 1 - b.squish) }
	// (a swap's face drawn as content only: its shape is the swap's morph, swap.odin)
	bare := box_bare(b)
	if bare { flags -= {.Draw_Shadow, .Draw_Focus_Ring, .Draw_Border, .Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right, .Row} }
	// (its ground is its custom draw's: the background is read as its face, never painted here)
	ground := !bare && .Custom_Ground not_in flags

	if .Draw_Shadow in flags {
		sc := tuned(color_from_tags(s, b.tags_key, "drop_shadow"))
		draw.rect_corners(dc, draw.rect_shift(draw.rect_pad(r, DROP_SHADOW_SPREAD_PX * scale), {DROP_SHADOW_OFFSET_PX * scale, DROP_SHADOW_OFFSET_PX * scale}), colors4(sc), radii, 0, DROP_SHADOW_SOFT_PX * scale)
	}
	keyboard_focus := !bare && s.focus_visible && b.key == s.focus_key
	focus_ring := (.Draw_Focus_Ring in flags && b.focus_t > FOCUS_T_EPS) || keyboard_focus
	// the machined finish draws its reliefs itself (machined.odin): the face, and for a well or a bevel its edge and focus
	machined_face, machined_whole: bool
	if ground { machined_face, machined_whole = machined_box(s, dc, b, r, radii, keyboard_focus) }
	if machined_whole { focus_ring = false }
	// (a row's ring goes round its face, what the user sees of it, not round its box)
	ring, ring_radii := r, radii
	if focus_ring && .Row in flags { ring, ring_radii, _, _, _ = row_face_of(s, b) }
	focus_look := s.theme != nil ? s.theme.look.focus : Theme_Focus{}
	if focus_ring && s.theme != nil && s.theme.relief.sheen && focus_look.style == .Ring_Glow {
		// glow around the focused widget, under its background
		c := color_from_tags(s, b.tags_key, "focus border")
		c.a *= (keyboard_focus ? 1 : b.focus_t) * FOCUS_GLOW_ALPHA
		glow := FOCUS_GLOW_PX * scale
		draw.rect_corners(dc, draw.rect_pad(ring, glow), colors4(tuned(c)), radii_grown(ring_radii, glow), 0, glow)
	}
	// the face in its state: lifted, sunk or appeared, on the box's own rect and radii (face.odin); a row's inset and
	// rounded inside it, over its square ground (row_face.odin)
	if .Row in flags {
		row_draw(s, dc, b)
	} else if !machined_face && ground {
		draw_face(s, dc, r, radii, box_face(s, b))
	}
	// (a rich paragraph paints both itself, between its runs' backgrounds and its text)
	if b.custom != rich_draw {
		if .Selectable in flags { draw_selection(s, dc, b) }
		if s.find.needle != "" { find_draw(s, dc, b) }
	}
	if .Draw_Text in flags && b.text != "" {
		paint := .Text_Wrap in flags ? draw_wrapped_text : draw_box_text
		if s.find.needle != "" { find_paint_text(s, dc, b, paint) } else { paint(s, dc, b) }
		if .Selectable in flags && b.custom != rich_draw { paint_selected(s, dc, b, paint) }
	}

	if .Clip in flags { draw.push_clip(dc, r) }
	faded := .Clip in flags && (b.edge_fade != {} || b.edge_hold != {})
	if faded { draw.push_mask(dc, r) }   // (no cache_id: it always asks for the content)
	if b.custom != nil { b.custom(b, b.custom_user, dc) }
	if children { for c := b.first; c != nil; c = c.next { draw_box(s, dc, c, scale) } }
	if faded {
		draw.mask_edge_fade(dc, r, b.edge_fade, b.edge_hold)
		draw.pop_mask(dc)
	}
	if .Clip in flags { draw.pop_clip(dc) }
	if .View_Scroll_Y in flags { draw_scrollbar(s, dc, b) }
	if .View_Scroll_X in flags { draw_scrollbar(s, dc, b, .X) }
	if !bare { machined_plate_over(s, dc, b, r, radii) }

	// (a row's border would frame its box, not its inset face: a row has none)
	if .Draw_Border in flags && b.border.a > BORDER_ALPHA_EPS && !machined_whole && .Row not_in flags {
		border := b.border
		// (a box that reacts: a target, or a frame that holds one, .Draw_Hot_Effects with .Hot_Within: input_frame)
		if hot := box_hot(b); hot > DRAW_INVISIBLE_EPS && b.focus_t < 0.5 && (.Clickable in flags || .Draw_Hot_Effects in flags) {
			if k := color_from_tags(s, b.tags_key, "hover_border"); k.a > DRAW_INVISIBLE_EPS { border = srgb_step(border, k, k.a * hot) }
		}
		draw.rect_corners(dc, r, colors4(border), radii, max(1, math.round(scale)), backdrop = box_under(b))
	}
	if flags & {.Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right} != {} {
		t := max(1, math.round(scale))
		if .Draw_Side_Top in flags    { draw.rect(dc, {r.min, {r.max.x, r.min.y + t}}, b.border) }
		if .Draw_Side_Bottom in flags { draw.rect(dc, {{r.min.x, r.max.y - t}, r.max}, b.border) }
		if .Draw_Side_Left in flags   { draw.rect(dc, {r.min, {r.min.x + t, r.max.y}}, b.border) }
		if .Draw_Side_Right in flags  { draw.rect(dc, {{r.max.x - t, r.min.y}, r.max}, b.border) }
	}
	if .Window_Caption in flags && s.window != nil && r.min.y <= 0 && platform.needs_top_border(s.window) {
		// Windows 10 draws no top edge over an integrated title bar
		draw.rect(dc, {{r.min.x, 0}, {r.max.x, 1}}, color_from_tags(s, b.tags_key, "border"))
	}
	if focus_ring { focus_mark(s, dc, b, ring, ring_radii, keyboard_focus, scale) }
	if !bare && s.act_light.key != 0 && s.act_light.key == b.key { act_light_draw(s, dc, b, radii) }
	if squished { draw.pop_xform(dc) }
	if fade { draw.pop_alpha(dc) }
	if b.transparency != 0 { draw.pop_alpha(dc) }
}

// The theme's focus of box `b` on `ring` (its rect, a row's face): a ring, or dots (Theme_Focus). `keyboard_focus`
// false: its focus fading (focus_t). Draw_box draws it over the box; a relief of rings over a key's rings (machined_box).
@(private)
focus_mark :: proc(s: ^State, dc: ^draw.Context, b: ^Box, ring: Rect, ring_radii: [4]f32, keyboard_focus: bool, scale: f32) {
	focus_look := s.theme != nil ? s.theme.look.focus : Theme_Focus{}
	c := focus_look.color != 0 ? draw.hex(focus_look.color) : color_from_tags(s, b.tags_key, "focus border")
	if !keyboard_focus { c.a *= b.focus_t }
	if focus_look.style == .Dotted {
		// (inside a box; a row's on its face, which is what the user sees of it. On a selected row the dots take its
		// ink: what reads on the selection, as Windows' dots in XOR did)
		if b.ink.a > 0 { c = Color{b.ink.r, b.ink.g, b.ink.b, c.a} }
		p := max(1, math.round((focus_look.width > 0 ? focus_look.width : 1) * scale))
		inset: f32 = .Row in b.flags ? 0 : math.round(focus_look.inset * scale)
		focus_dots(dc, draw.rect_pad(ring, -inset), p, c)
	} else {
		draw.rect_corners(dc, ring, colors4(c), ring_radii, (focus_look.width > 0 ? focus_look.width : FOCUS_RING_PX) * scale)
	}
}

// How much a box is drawn as under the pointer: all of it while .Lit (its menu is open).
box_hot :: proc(b: ^Box) -> f32 { return .Lit in b.flags ? 1 : b.hot_t }

// How much a box is drawn pressed in: all of it while .Held (toggled), else while the button is held on it and the
// pointer is still there (face_state).
box_held :: proc(b: ^Box) -> f32 {
	st := face_state(b)
	return max(st.toggled, st.pressing)
}

// The radii of a box's corners (draw.rect_corners' order): `radius`, or 0 for its square corners.
box_radii :: proc(radius: f32, square: Corners) -> (radii: [4]f32) {
	for c in Corner { radii[int(c)] = c in square ? 0 : radius }
	return
}

// Radii of a shape grown by `d` around it (shrunk when negative): a round corner follows, a square one stays square.
// The halo of a focused box as the theme draws it around a field (focus 0..1, `c` its "focus border" colour): a box
// drawn by a program that sits on a field's edge (a part of it of its own colour) glows as the field does. None when
// the theme's focus style has no glow (Theme_Focus).
focus_glow :: proc(dc: ^draw.Context, r: Rect, radii: [4]f32, c: Color, focus: f32) {
	s := gs()
	if s.theme == nil || focus <= DRAW_INVISIBLE_EPS || s.theme.look.focus.style != .Ring_Glow { return }
	if machined() { machined_focus_glow(dc, r, radii, c, focus); return }
	if !s.theme.relief.sheen { return }
	k := c
	k.a *= focus * FOCUS_GLOW_ALPHA
	glow := FOCUS_GLOW_PX * s.scale
	draw.rect_corners(dc, draw.rect_pad(r, glow), colors4(tuned(k)), radii_grown(radii, glow), 0, glow)
}

radii_grown :: proc(radii: [4]f32, d: f32) -> (out: [4]f32) {
	for r, i in radii { out[i] = r > 0 ? max(r + d, 0) : 0 }
	return
}

@(private)
colors4 :: proc(c: Color) -> [4]Color { return {c, c, c, c} }

// Baseline origin for a block of text of `dim` inside `r`.
text_origin :: proc(s: ^State, b: ^Box, dim: Vec2) -> Vec2 {
	m := font.metrics(s.fonts, b.font, b.font_size)
	cy := (b.rect.min.y + b.rect.max.y) * 0.5
	x: f32
	switch b.text_align {
	case .Left:   x = b.rect.min.x + b.text_pad
	case .Center: x = (b.rect.min.x + b.rect.max.x) * 0.5 - dim.x * 0.5
	case .Right:  x = b.rect.max.x - b.text_pad - dim.x
	}
	return {math.round(x), math.round(cy + (m.ascent - m.descent) * 0.5)}
}

// The colour under a box's text: its own background or the nearest opaque one of its ancestors, else the theme's.
@(private)
backdrop_under :: proc(s: ^State, b: ^Box) -> Color {
	for a := b; a != nil; a = a.parent {
		if .Draw_Background in a.flags && a.bg.a >= 0.5 { return a.bg }
	}
	return color_from_tags(s, b.tags_key, "background")
}

// The engraving of text on a raised surface: a dark shadow over light text, a light edge under dark text.
@(private = "file") ENGRAVE_SHADOW_ALPHA :: 0.35
@(private = "file") ENGRAVE_LIGHT_ALPHA :: 0.20   // (more blurred dark text on a light face)

@(private)
draw_box_text :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	text := b.text
	width := b.text_dim.x
	avail := (b.rect.max.x - b.rect.min.x) - 2 * b.text_pad
	cut := false
	if width > avail && .No_Text_Trunc not_in b.flags {
		text, width, cut = truncate(s, b, avail)
	}
	pos := text_origin(s, b, {width, b.text_dim.y})
	b.ellipsis = {}
	if cut {
		// (the ellipsis, as tall as the box and a little wider than its dots: a target the pointer can find)
		ell_w := font.text_width(s.fonts, b.font, b.font_size, TRUNC_ELLIPSIS)
		x1 := pos.x + width
		pad := math.round(b.font_size * REVEAL_PAD_EM)
		b.ellipsis = {{x1 - ell_w - pad, b.rect.min.y}, {min(x1 + pad, b.rect.max.x), b.rect.max.y}}
		if s.hot_key == reveal_key(b) {
			// (lit under the pointer: it is a target)
			kept := text[:len(text) - len(TRUNC_ELLIPSIS)]
			draw.text(dc, b.font, b.font_size, pos, b.text_color, kept)
			draw.text(dc, b.font, b.font_size, {pos.x + width - ell_w, pos.y}, color_from_tags(s, b.tags_key, "accent"), TRUNC_ELLIPSIS)
			return
		}
	}
	// (engraved: the machined finish's alone; on a shaded face the text reads as on the plain colour)
	if s.theme != nil && s.theme.relief.engrave {
		if k := box_sheen(s, b); k > DRAW_INVISIBLE_EPS {
			// text lighter than what is under it sits in a groove (a dark shadow above); darker text is lit from below. (By
			// the contrast, not the text alone: grey text on a dark panel took a light edge under it, a pixel low to the eye.)
			tc := b.text_color
			lum :: proc(c: Color) -> f32 { return LUMA_R * c.r + LUMA_G * c.g + LUMA_B * c.b }
			light := lum(tc) > lum(backdrop_under(s, b))
			sc := tuned(light ? Color{0, 0, 0, ENGRAVE_SHADOW_ALPHA * k * tc.a} : Color{1, 1, 1, ENGRAVE_LIGHT_ALPHA * k * tc.a}, Color{b.bg.r, b.bg.g, b.bg.b, 1})
			draw.text(dc, b.font, b.font_size, pos + {0, light ? -1 : 1}, sc, text)
		}
	}
	draw.text(dc, b.font, b.font_size, pos, b.text_color, text)
}

// `b.text` cut at its end so that it and TRUNC_ELLIPSIS fit in `avail` pixels (elide.odin's cutter and its cache), and
// its width; whole when it fits after all (the box's measure and the shaped one can differ by a fraction of a pixel).
@(private)
truncate :: proc(s: ^State, b: ^Box, avail: f32) -> (text: string, width: f32, cut: bool) {
	e := elide_cut(s, b.font, b.font_size, b.text, avail, .End, TRUNC_ELLIPSIS)
	if e.head < 0 { return "", 0, false }
	return elide_text(b.text, e, TRUNC_ELLIPSIS, frame_allocator()), e.width, e.head < len(b.text)
}

////////////////////////////////
// Finishes

// A lit face (.Gradient, and .Machined's surfaces painted here): how far its top goes toward white and its bottom toward
// black, in sRGB steps (srgb_step), and the alpha of the lit line along its top. Small: a shade, not a gloss; the text
// on it reads as on the plain colour.
@(private = "file") GRADIENT_TOP_WHITE :: 0.07
@(private = "file") GRADIENT_BOTTOM_BLACK :: 0.08
@(private = "file") GRADIENT_RIM_ALPHA :: 0.10
@(private = "file") MACHINED_TOP_WHITE :: 0.10
@(private = "file") MACHINED_BOTTOM_BLACK :: 0.14
@(private = "file") MACHINED_RIM_ALPHA :: 0.16
// .Glass: the gloss of a saturated (not bright) fill; the four stops of the two halves, top to bottom; the inner rim's alpha.
@(private = "file") GLASS_BRIGHT_LUM :: 0.6
@(private = "file") GLASS_SATURATED_GLOSS :: 0.6
@(private = "file") GLASS_TOP_WHITE :: 0.75
@(private = "file") GLASS_MID_WHITE :: 0.35
@(private = "file") GLASS_LOWER_BLACK :: 0.06
@(private = "file") GLASS_BOTTOM_WHITE :: 0.22
@(private = "file") GLASS_RIM_ALPHA :: 0.55
// A face pressed in (sunk): glass keeps this little of its gloss; a lit face's top is shaded by this share of its
// bottom's darkening, its bottom lit by this share of its top's lightening.
@(private = "file") GLASS_SUNK_GLOSS_LOSS :: 0.7
@(private = "file") SUNK_TOP_SHADE :: 1.2
@(private = "file") SUNK_BOTTOM_LIGHT :: 0.4

// Fills a raised surface with the theme's relief (its Face_Paint, relief.odin). `k` (0..1) is how strongly: 0 is a plain fill.
// Custom draw procs use it for their accent fills so they match the buttons.
paint_rect :: proc(dc: ^draw.Context, r: Rect, c: Color, radius: f32, k: f32 = 1) {
	paint_rect_corners(dc, r, c, {radius, radius, radius, radius}, k)
}

// paint_rect with a radius per corner (draw.rect_corners' order). `rim` false: the face alone, no lit line round it
// (a box that declares its sides, a bar: box_rimmed). `sunk` (0..1): pressed in: a lit face inverts (its top shaded, its
// bottom lit, no rim), glass loses most of its gloss.
paint_rect_corners :: proc(dc: ^draw.Context, r: Rect, c: Color, radii: [4]f32, k: f32 = 1, rim := true, sunk: f32 = 0) {
	s := gs()
	paint := s.theme != nil ? s.theme.relief.face : .Plain
	if paint == .Plain || k <= DRAW_INVISIBLE_EPS || c.a <= DRAW_INVISIBLE_EPS || r.max.y - r.min.y < 2 {
		draw.rect_corners(dc, r, colors4(c), radii)
		return
	}
	white := Color{1, 1, 1, c.a}
	black := Color{0, 0, 0, c.a}
	px := max(1, math.round(s.scale))
	rk: f32 = rim ? k : 0
	switch paint {
	case .Plain:
	case .Strong:   // (the machined and edged reliefs are machined_box's; a surface painted here, an accent fill, is a lit face)
		lit_face(dc, r, c, radii, MACHINED_TOP_WHITE * k, MACHINED_BOTTOM_BLACK * k, MACHINED_RIM_ALPHA * rk, sunk)
	case .Lit:
		lit_face(dc, r, c, radii, GRADIENT_TOP_WHITE * k, GRADIENT_BOTTOM_BLACK * k, GRADIENT_RIM_ALPHA * rk, sunk)
	case .Gloss:
		mid := math.round((r.min.y + r.max.y) * 0.5)
		// saturated fills keep more of their colour so white text stays readable on them
		lum := LUMA_R * c.r + LUMA_G * c.g + LUMA_B * c.b
		gloss := k * (lum > GLASS_BRIGHT_LUM ? 1 : GLASS_SATURATED_GLOSS) * (1 - GLASS_SUNK_GLOSS_LOSS * sunk)
		t0 := draw.mix(c, white, GLASS_TOP_WHITE * gloss)
		t1 := draw.mix(c, white, GLASS_MID_WHITE * gloss)
		b0 := draw.mix(c, black, GLASS_LOWER_BLACK * gloss)
		b1 := draw.mix(c, white, GLASS_BOTTOM_WHITE * gloss)
		lim := min((r.max.y - r.min.y) * 0.5, (r.max.x - r.min.x) * 0.5)
		rr := [4]f32{min(radii[0], lim), min(radii[1], lim), min(radii[2], lim), min(radii[3], lim)}
		draw.rect_corners(dc, {r.min, {r.max.x, mid}}, {t0, t1, t0, t1}, {rr[0], 0, rr[2], 0})
		draw.rect_corners(dc, {{r.min.x, mid}, r.max}, {b0, b1, b0, b1}, {0, rr[1], 0, rr[3]})
		if rim && sunk < 1 { draw.rect_corners(dc, draw.rect_pad(r, -px), colors4(tuned({1, 1, 1, GLASS_RIM_ALPHA * k * c.a * (1 - sunk)}, Color{c.r, c.g, c.b, 1})), radii_grown(rr, -px), px) }
	}
}

// A face of colour `c` lit from above: its top `up` toward white, its bottom `down` toward black (sRGB steps), a lit line
// of alpha `rim` along its top edge that fades down its sides. `sunk` (0..1): pressed in, the light turns over: its top
// shaded, its bottom lit a little, the rim gone (a face lit from above that goes in shades its own top).
lit_face :: proc(dc: ^draw.Context, r: Rect, c: Color, radii: [4]f32, up, down, rim: f32, sunk: f32 = 0) {
	top := srgb_step(c, {1, 1, 1, 1}, up)
	bot := srgb_step(c, {0, 0, 0, 1}, down)
	if sunk > DRAW_INVISIBLE_EPS {
		top = draw.mix(top, srgb_step(c, {0, 0, 0, 1}, down * SUNK_TOP_SHADE), sunk)
		bot = draw.mix(bot, srgb_step(c, {1, 1, 1, 1}, up * SUNK_BOTTOM_LIGHT), sunk)
	}
	draw.rect_corners(dc, r, {top, bot, top, bot}, radii)
	shine := rim * (1 - sunk)
	if shine <= DRAW_INVISIBLE_EPS || r.max.y - r.min.y < 4 { return }
	p := max(1, math.round(gs().scale))
	lit := tuned({1, 1, 1, shine * c.a}, top)
	draw.rect_corners(dc, draw.rect_pad(r, -p), {lit, {1, 1, 1, 0}, lit, {1, 1, 1, 0}}, radii_grown(radii, -p), p)
}

// Whether a finish draws its rim (the lit line round a raised face, glass's white edge) on a box. The rim belongs to a
// raised face that stands on its own (a button, a card, a chip, a dialog). A box that declares its sides (.Draw_Side_*)
// has those lines alone: a rim inset by a pixel doubled them, and framed the sides it left open. A box flush with an
// edge of the window (a bar, a sidebar) has the window's edge there: a rim framed it, and drew a second line under the
// bar next to it. A box inside a face that draws (a frame, a card, a well) is part of that face where it meets its inner
// top edge or runs across its inner width (a header, a row, a stripe): the face's edge is the line there, and a rim drew
// a second one just under it (a table's header under its frame's border).
box_rimmed :: proc(s: ^State, b: ^Box) -> bool {
	if b.flags & {.Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right} != {} { return false }
	if s.root == nil { return true }
	FLUSH_PX :: 0.5
	r, w := b.rect, s.root.rect
	if abs(r.min.x - w.min.x) <= FLUSH_PX || abs(r.min.y - w.min.y) <= FLUSH_PX ||
		abs(r.max.x - w.max.x) <= FLUSH_PX || abs(r.max.y - w.max.y) <= FLUSH_PX {
		return false
	}
	// (the boxes between that draw nothing, rows and columns of the layout, are looked through: a button in a row of a
	// bar is measured against the bar)
	face := b.parent
	for face != nil && face != s.root && !box_draws_face(face) { face = face.parent }
	if face == nil || face == s.root { return true }
	q := draw.rect_pad(face.rect, -border_inset(face))
	if abs(r.min.y - q.min.y) <= FLUSH_PX { return false }
	return abs(r.min.x - q.min.x) > FLUSH_PX || abs(r.max.x - q.max.x) > FLUSH_PX
}

// Whether a box draws a face of its own: a background, a border, or a draw of its own (a program's frame, a well).
@(private = "file")
box_draws_face :: proc(b: ^Box) -> bool {
	return (.Draw_Background in b.flags && b.bg.a > DRAW_INVISIBLE_EPS) || .Draw_Border in b.flags || b.custom != nil
}

// Sheen of the box's tags (0 when the theme is flat).
@(private)
box_sheen :: proc(s: ^State, b: ^Box) -> f32 {
	if s.theme == nil || !s.theme.relief.sheen { return 0 }
	return color_from_tags(s, b.tags_key, "sheen").a
}