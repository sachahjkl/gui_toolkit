package ui

import "core:math"
import "core:strings"
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

@(private)
draw_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, scale: f32) {
	// what the box draws, its children apart, is compared with its last frame's (set_partial_redraw)
	draw.damage_span_begin(dc, u64(b.key))
	defer draw.damage_span_end(dc)
	r := b.rect
	radius := .Fixed_Radius in b.flags ? b.radius : b.radius * rounding(s)
	radii := box_radii(radius, b.square_corners)
	flags := b.flags
	if b.transparency != 0 { draw.push_alpha(dc, 1 - b.transparency) }
	// disabled: the outermost disabled box fades itself and its subtree (nested disabled boxes do not compound)
	fade := b.disabled_t > DISABLED_FADE_EPS && (b.parent == nil || b.parent.disabled_t <= DISABLED_FADE_EPS)
	if fade { draw.push_alpha(dc, math.lerp(f32(1), s.disabled_keep, b.disabled_t)) }
	squished := b.squish > DRAW_INVISIBLE_EPS
	if squished { draw.push_scale(dc, draw.rect_center(r), 1 - b.squish) }

	if .Draw_Shadow in flags {
		sc := tuned(color_from_tags(s, b.tags_key, "drop_shadow"))
		draw.rect_corners(dc, draw.rect_shift(draw.rect_pad(r, DROP_SHADOW_SPREAD_PX * scale), {DROP_SHADOW_OFFSET_PX * scale, DROP_SHADOW_OFFSET_PX * scale}), colors4(sc), radii, 0, DROP_SHADOW_SOFT_PX * scale)
	}
	keyboard_focus := s.focus_visible && b.key == s.focus_key
	focus_ring := (.Draw_Focus_Ring in flags && b.focus_t > FOCUS_T_EPS) || keyboard_focus
	// the machined finish draws its reliefs itself (machined.odin): the face, and for a well or a bevel its edge and focus
	machined_face, machined_whole := machined_box(s, dc, b, r, radii, keyboard_focus)
	if machined_whole { focus_ring = false }
	if focus_ring && s.theme != nil && s.theme.finish != .Flat {
		// glow around the focused widget, under its background
		c := color_from_tags(s, b.tags_key, "focus border")
		c.a *= (keyboard_focus ? 1 : b.focus_t) * FOCUS_GLOW_ALPHA
		glow := FOCUS_GLOW_PX * scale
		draw.rect_corners(dc, draw.rect_pad(r, glow), colors4(tuned(c)), radii_grown(radii, glow), 0, glow)
	}
	if .Draw_Background in flags && !machined_face {
		paint_rect_corners(dc, r, b.bg, radii, box_sheen(s, b))
	}
	if .Draw_Hot_Effects in flags && b.hot_t > DRAW_INVISIBLE_EPS && !machined_face {
		// the theme's step toward its tint, over what is actually under the box (theme_default.odin: state_entries)
		hover := color_from_tags(s, b.tags_key, "hover_fill")
		press := color_from_tags(s, b.tags_key, "press_fill")
		held := b.active_t * b.hot_t   // pressed, and the pointer still on it
		h := draw.mix(hover, press, held)
		h.a = math.lerp(hover.a * b.hot_t, press.a, held)
		if h.a > DRAW_INVISIBLE_EPS {
			h.a = draw.alpha_like_srgb(s.space, h, h.a, box_under(b))
			draw.rect_corners(dc, r, colors4(h), radii)
		}
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
	faded := .Clip in flags && b.edge_fade != {}
	if faded { draw.push_mask(dc, r) }   // (no cache_id: it always asks for the content)
	if b.custom != nil { b.custom(b, b.custom_user, dc) }
	for c := b.first; c != nil; c = c.next { draw_box(s, dc, c, scale) }
	if faded {
		draw.mask_edge_fade(dc, r, b.edge_fade)
		draw.pop_mask(dc)
	}
	if .Clip in flags { draw.pop_clip(dc) }
	if .View_Scroll_Y in flags { draw_scrollbar(s, dc, b) }
	if .View_Scroll_X in flags { draw_scrollbar(s, dc, b, .X) }

	if .Draw_Border in flags && b.border.a > BORDER_ALPHA_EPS && !machined_whole {
		border := b.border
		if b.hot_t > DRAW_INVISIBLE_EPS && b.focus_t < 0.5 && .Clickable in flags {
			if k := color_from_tags(s, b.tags_key, "hover_border"); k.a > DRAW_INVISIBLE_EPS { border = srgb_step(border, k, k.a * b.hot_t) }
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
	if focus_ring {
		c := color_from_tags(s, b.tags_key, "focus border")
		if !keyboard_focus { c.a *= b.focus_t }
		draw.rect_corners(dc, r, colors4(c), radii, FOCUS_RING_PX * scale)
	}
	if squished { draw.pop_xform(dc) }
	if fade { draw.pop_alpha(dc) }
	if b.transparency != 0 { draw.pop_alpha(dc) }
}

// The radii of a box's corners (draw.rect_corners' order): `radius`, or 0 for its square corners.
box_radii :: proc(radius: f32, square: Corners) -> (radii: [4]f32) {
	for c in Corner { radii[int(c)] = c in square ? 0 : radius }
	return
}

// Radii of a shape grown by `d` around it (shrunk when negative): a round corner follows, a square one stays square.
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
	if width > avail && .No_Text_Trunc not_in b.flags {
		text, width = truncate(s, b, avail)
	}
	pos := text_origin(s, b, {width, b.text_dim.y})
	// (engraved: the machined finish's alone; on a shaded face the text reads as on the plain colour)
	if s.theme != nil && s.theme.finish == .Machined {
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

// Where a text is cut for a width (`truncate`): the measure goes rune by rune, and a list of titles asks at every frame.
// Entries not used for WRAP_CACHE_KEEP builds go.
@(private)
Trunc_Key :: struct {
	text_hash: u64,
	text_len:  int,
	font:      font.Font_Id,
	size:      f32,
	avail:     f32,
}

@(private)
Trunc_Entry :: struct {
	end:        int,   // bytes kept (-1: not even the ellipsis fits)
	width:      f32,   // of what is kept and the ellipsis
	last_build: u64,
}

// Shortens `b.text` so that it plus an ellipsis fits in `avail` pixels.
@(private)
truncate :: proc(s: ^State, b: ^Box, avail: f32) -> (string, f32) {
	ell :: "..."
	k := Trunc_Key{text_hash = hash_bytes(transmute([]u8)b.text), text_len = len(b.text), font = b.font, size = b.font_size, avail = avail}
	e, known := &s.trunc_cache[k]
	if !known {
		s.trunc_cache[k] = truncate_measure(s, b, avail, ell)
		e = &s.trunc_cache[k]
	}
	e.last_build = s.build_index
	if e.end < 0 { return "", 0 }
	return strings.concatenate({b.text[:e.end], ell}, frame_allocator()), e.width
}

@(private = "file")
truncate_measure :: proc(s: ^State, b: ^Box, avail: f32, ell: string) -> Trunc_Entry {
	ell_w := font.text_width(s.fonts, b.font, b.font_size, ell)
	if avail <= ell_w { return {end = -1} }
	x: f32
	end := 0
	for r, i in b.text {
		w := font.glyph(s.fonts, b.font, b.font_size, r).advance
		if x + w + ell_w > avail { break }
		x += w
		end = i + len_utf8(r)
	}
	return {end = end, width = x + ell_w}
}

@(private)
trunc_cache_trim :: proc(s: ^State) {
	if s.build_index % CACHE_TRIM_INTERVAL_BUILDS != 0 { return }
	dead := make([dynamic]Trunc_Key, context.temp_allocator)
	for k, e in s.trunc_cache { if e.last_build + WRAP_CACHE_KEEP < s.build_index { append(&dead, k) } }
	for k in dead { delete_key(&s.trunc_cache, k) }
}

@(private)
len_utf8 :: proc(r: rune) -> int {
	switch {
	case r < 0x80:    return 1
	case r < 0x800:   return 2
	case r < 0x10000: return 3
	}
	return 4
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

// Fills a raised surface with the theme's finish (see `Finish`). `k` (0..1) is how strongly: 0 is a plain fill.
// Custom draw procs use it for their accent fills so they match the buttons.
paint_rect :: proc(dc: ^draw.Context, r: Rect, c: Color, radius: f32, k: f32 = 1) {
	paint_rect_corners(dc, r, c, {radius, radius, radius, radius}, k)
}

// paint_rect with a radius per corner (draw.rect_corners' order).
paint_rect_corners :: proc(dc: ^draw.Context, r: Rect, c: Color, radii: [4]f32, k: f32 = 1) {
	s := gs()
	finish := s.theme != nil ? s.theme.finish : .Flat
	if finish == .Flat || k <= DRAW_INVISIBLE_EPS || c.a <= DRAW_INVISIBLE_EPS || r.max.y - r.min.y < 2 {
		draw.rect_corners(dc, r, colors4(c), radii)
		return
	}
	white := Color{1, 1, 1, c.a}
	black := Color{0, 0, 0, c.a}
	px := max(1, math.round(s.scale))
	switch finish {
	case .Flat:
	case .Machined, .Edged:   // (the reliefs are machined_box's; a surface painted here, an accent fill, is a lit face)
		lit_face(dc, r, c, radii, MACHINED_TOP_WHITE * k, MACHINED_BOTTOM_BLACK * k, MACHINED_RIM_ALPHA * k)
	case .Gradient:
		lit_face(dc, r, c, radii, GRADIENT_TOP_WHITE * k, GRADIENT_BOTTOM_BLACK * k, GRADIENT_RIM_ALPHA * k)
	case .Glass:
		mid := math.round((r.min.y + r.max.y) * 0.5)
		// saturated fills keep more of their colour so white text stays readable on them
		lum := LUMA_R * c.r + LUMA_G * c.g + LUMA_B * c.b
		gloss := k * (lum > GLASS_BRIGHT_LUM ? 1 : GLASS_SATURATED_GLOSS)
		t0 := draw.mix(c, white, GLASS_TOP_WHITE * gloss)
		t1 := draw.mix(c, white, GLASS_MID_WHITE * gloss)
		b0 := draw.mix(c, black, GLASS_LOWER_BLACK * gloss)
		b1 := draw.mix(c, white, GLASS_BOTTOM_WHITE * gloss)
		lim := min((r.max.y - r.min.y) * 0.5, (r.max.x - r.min.x) * 0.5)
		rr := [4]f32{min(radii[0], lim), min(radii[1], lim), min(radii[2], lim), min(radii[3], lim)}
		draw.rect_corners(dc, {r.min, {r.max.x, mid}}, {t0, t1, t0, t1}, {rr[0], 0, rr[2], 0})
		draw.rect_corners(dc, {{r.min.x, mid}, r.max}, {b0, b1, b0, b1}, {0, rr[1], 0, rr[3]})
		draw.rect_corners(dc, draw.rect_pad(r, -px), colors4(tuned({1, 1, 1, GLASS_RIM_ALPHA * k * c.a}, Color{c.r, c.g, c.b, 1})), radii_grown(rr, -px), px)
	}
}

// A face of colour `c` lit from above: its top `up` toward white, its bottom `down` toward black (sRGB steps), a lit line
// of alpha `rim` along its top edge that fades down its sides.
lit_face :: proc(dc: ^draw.Context, r: Rect, c: Color, radii: [4]f32, up, down, rim: f32) {
	top := srgb_step(c, {1, 1, 1, 1}, up)
	bot := srgb_step(c, {0, 0, 0, 1}, down)
	draw.rect_corners(dc, r, {top, bot, top, bot}, radii)
	if rim <= DRAW_INVISIBLE_EPS || r.max.y - r.min.y < 4 { return }
	p := max(1, math.round(gs().scale))
	lit := tuned({1, 1, 1, rim * c.a}, top)
	draw.rect_corners(dc, draw.rect_pad(r, -p), {lit, {1, 1, 1, 0}, lit, {1, 1, 1, 0}}, radii_grown(radii, -p), p)
}

// Sheen of the box's tags (0 when the theme is flat).
@(private)
box_sheen :: proc(s: ^State, b: ^Box) -> f32 {
	if s.theme == nil || s.theme.finish == .Flat { return 0 }
	return color_from_tags(s, b.tags_key, "sheen").a
}