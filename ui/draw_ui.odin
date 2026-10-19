package ui

import "core:math"
import "core:strings"
import "../draw"
import "../font"

// Paints the box tree built by the last build. Parents first, then children (later siblings on top);
// borders, focus rings and the disabled overlay are drawn after the children so they land above them.
// Opacity kept by disabled widgets. Tuned for blending in linear light, where the same alpha looks far more opaque over
// a dark background than over a light one, so it depends on the theme (and is adapted by `tuned` in an sRGB frame).
// Disabled boxes also switch to neutral colours (see build_box), so this only has to dim them a little.
DISABLED_KEEP_DARK :: 0.4
DISABLED_KEEP_LIGHT :: 0.65

// The UI's translucent colors (hover tints, glows, sheens, scrollbars, theme entries with an alpha) are tuned for
// blending in linear light. Drawn into an sRGB target (render.Blend_Space.Srgb, a web browser's choice), `tuned`
// changes their alpha so they look the same over the theme's background (or `over`); corner gradients of the UI are
// interpolated in linear light in both spaces. The tree therefore looks the same in both spaces, except for
// antialiased edges and text, which follow the space.
tuned :: proc(c: Color, over: Maybe(Color) = nil) -> Color {
	if g == nil || g.space == .Linear { return c }
	o := c
	o.a = draw.alpha_like_linear(g.space, c, c.a, over.? or_else g.backdrop)
	return o
}

draw_tree :: proc(s: ^State, dc: ^draw.Context) {
	g = s
	bg := color_from_tags(s, 0, "background")
	s.space = draw.blend_space(dc)
	s.backdrop = {bg.r, bg.g, bg.b, 1}
	lum := clamp(0.2126 * bg.r + 0.7152 * bg.g + 0.0722 * bg.b, 0, 1)
	s.disabled_keep = math.lerp(f32(DISABLED_KEEP_DARK), f32(DISABLED_KEEP_LIGHT), lum)
	if s.space != .Linear {
		s.disabled_keep = tuned(color_from_tags(s, 0, "text") * {1, 1, 1, 0} + {0, 0, 0, s.disabled_keep}).a
	}
	interp := draw.set_interpolation(dc, .Linear)
	draw_box(s, dc, s.root, s.scale)
	draw.set_interpolation(dc, interp)
}

@(private)
draw_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, scale: f32) {
	r := b.rect
	radius := .Fixed_Radius in b.flags ? b.radius : b.radius * s.rounding
	flags := b.flags
	if b.transparency != 0 { draw.push_alpha(dc, 1 - b.transparency) }
	// disabled: the outermost disabled box fades itself and its subtree (nested disabled boxes do not compound)
	fade := b.disabled_t > 0.005 && (b.parent == nil || b.parent.disabled_t <= 0.005)
	if fade { draw.push_alpha(dc, math.lerp(f32(1), s.disabled_keep, b.disabled_t)) }
	squished := b.squish > 0.001
	if squished { draw.push_scale(dc, draw.rect_center(r), 1 - b.squish) }

	if .Draw_Shadow in flags {
		sc := tuned(color_from_tags(s, b.tags_key, "drop_shadow"))
		draw.rect(dc, draw.rect_shift(draw.rect_pad(r, 8 * scale), {4 * scale, 4 * scale}), sc, radius, 0, 8 * scale)
	}
	keyboard_focus := s.focus_visible && b.key == s.focus_key
	focus_ring := (.Draw_Focus_Ring in flags && b.focus_t > 0.01) || keyboard_focus
	if focus_ring && s.theme != nil && s.theme.finish != .Flat {
		// glow around the focused widget, under its background
		c := color_from_tags(s, b.tags_key, "focus border")
		c.a *= (keyboard_focus ? 1 : b.focus_t) * 0.55
		glow := 5 * scale
		draw.rect(dc, draw.rect_pad(r, glow), tuned(c), radius + glow, 0, glow)
	}
	if .Draw_Background in flags {
		paint_rect(dc, r, b.bg, radius, box_sheen(s, b))
	}
	if .Draw_Hot_Effects in flags {
		h := color_from_tags(s, b.tags_key, "hover")
		h.a *= 0.014 * b.hot_t * (1 - b.active_t) + 0.02 * b.active_t   // tuned for linear blending: tiny alphas
		draw.rect(dc, r, tuned(h, b.bg.a > 0.5 ? Color{b.bg.r, b.bg.g, b.bg.b, 1} : g.backdrop), radius)
	}
	if .Draw_Text in flags && b.text != "" {
		if .Text_Wrap in flags { draw_wrapped_text(s, dc, b) } else { draw_box_text(s, dc, b) }
	}

	if .Clip in flags { draw.push_clip(dc, r) }
	if b.custom != nil { b.custom(b, b.custom_user, dc) }
	for c := b.first; c != nil; c = c.next { draw_box(s, dc, c, scale) }
	if .Clip in flags { draw.pop_clip(dc) }
	if .View_Scroll_Y in flags { draw_scrollbar(s, dc, b) }

	if .Draw_Border in flags && b.border.a > 0.002 { draw.rect(dc, r, b.border, radius, max(1, math.round(scale))) }
	if flags & {.Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right} != {} {
		t := max(1, math.round(scale))
		if .Draw_Side_Top in flags    { draw.rect(dc, {r.min, {r.max.x, r.min.y + t}}, b.border) }
		if .Draw_Side_Bottom in flags { draw.rect(dc, {{r.min.x, r.max.y - t}, r.max}, b.border) }
		if .Draw_Side_Left in flags   { draw.rect(dc, {r.min, {r.min.x + t, r.max.y}}, b.border) }
		if .Draw_Side_Right in flags  { draw.rect(dc, {{r.max.x - t, r.min.y}, r.max}, b.border) }
	}
	if focus_ring {
		c := color_from_tags(s, b.tags_key, "focus border")
		if !keyboard_focus { c.a *= b.focus_t }
		draw.rect(dc, r, c, radius, 1.5 * scale)
	}
	if squished { draw.pop_xform(dc) }
	if fade { draw.pop_alpha(dc) }
	if b.transparency != 0 { draw.pop_alpha(dc) }
}

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

@(private)
draw_box_text :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	text := b.text
	width := b.text_dim.x
	avail := (b.rect.max.x - b.rect.min.x) - 2 * b.text_pad
	if width > avail && .No_Text_Trunc not_in b.flags {
		text, width = truncate(s, b, avail)
	}
	pos := text_origin(s, b, {width, b.text_dim.y})
	if s.theme != nil && s.theme.finish != .Flat {
		if k := box_sheen(s, b); k > 0.001 {
			// light text sits in a groove (dark shadow above), dark text is lit from below
			tc := b.text_color
			light := 0.2126 * tc.r + 0.7152 * tc.g + 0.0722 * tc.b > 0.5
			sc := tuned(light ? Color{0, 0, 0, 0.35 * k * tc.a} : Color{1, 1, 1, 0.75 * k * tc.a}, Color{b.bg.r, b.bg.g, b.bg.b, 1})
			draw.text(dc, b.font, b.font_size, pos + {0, light ? -1 : 1}, sc, text)
		}
	}
	draw.text(dc, b.font, b.font_size, pos, b.text_color, text)
}

// Shortens `b.text` so that it plus an ellipsis fits in `avail` pixels.
@(private)
truncate :: proc(s: ^State, b: ^Box, avail: f32) -> (string, f32) {
	ell := "..."
	ell_w := font.text_width(s.fonts, b.font, b.font_size, ell)
	if avail <= ell_w { return "", 0 }
	x: f32
	end := 0
	for r, i in b.text {
		w := font.glyph(s.fonts, b.font, b.font_size, r).advance
		if x + w + ell_w > avail { break }
		x += w
		end = i + len_utf8(r)
	}
	out := strings.concatenate({b.text[:end], ell}, frame_allocator())
	return out, x + ell_w
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

// Fills a raised surface with the theme's finish (see `Finish`). `k` (0..1) is how strongly: 0 is a plain fill.
// Custom draw procs use it for their accent fills so they match the buttons.
paint_rect :: proc(dc: ^draw.Context, r: Rect, c: Color, radius: f32, k: f32 = 1) {
	finish := g.theme != nil ? g.theme.finish : .Flat
	if finish == .Flat || k <= 0.001 || c.a <= 0.001 || r.max.y - r.min.y < 2 {
		draw.rect(dc, r, c, radius)
		return
	}
	white := Color{1, 1, 1, c.a}
	black := Color{0, 0, 0, c.a}
	px := max(1, math.round(g.scale))
	switch finish {
	case .Flat:
	case .Gradient:
		top := draw.mix(c, white, 0.50 * k)
		bot := draw.mix(c, black, 0.14 * k)
		draw.rect_corners(dc, r, {top, bot, top, bot}, {radius, radius, radius, radius})
		inset := min(radius, (r.max.x - r.min.x) * 0.5) * 0.7
		draw.rect(dc, {{r.min.x + inset, r.min.y + px}, {r.max.x - inset, r.min.y + 2 * px}}, tuned({1, 1, 1, 0.30 * k * c.a}, top))
	case .Glass:
		mid := math.round((r.min.y + r.max.y) * 0.5)
		// saturated fills keep more of their colour so white text stays readable on them
		lum := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		gloss := k * (lum > 0.6 ? 1 : 0.6)
		t0 := draw.mix(c, white, 0.75 * gloss)
		t1 := draw.mix(c, white, 0.35 * gloss)
		b0 := draw.mix(c, black, 0.06 * gloss)
		b1 := draw.mix(c, white, 0.22 * gloss)
		rr := min(radius, (r.max.y - r.min.y) * 0.5, (r.max.x - r.min.x) * 0.5)
		draw.rect_corners(dc, {r.min, {r.max.x, mid}}, {t0, t1, t0, t1}, {rr, 0, rr, 0})
		draw.rect_corners(dc, {{r.min.x, mid}, r.max}, {b0, b1, b0, b1}, {0, rr, 0, rr})
		draw.rect(dc, draw.rect_pad(r, -px), tuned({1, 1, 1, 0.55 * k * c.a}, Color{c.r, c.g, c.b, 1}), max(0, rr - px), px)
	}
}

// Sheen of the box's tags (0 when the theme is flat).
@(private)
box_sheen :: proc(s: ^State, b: ^Box) -> f32 {
	if s.theme == nil || s.theme.finish == .Flat { return 0 }
	return color_from_tags(s, b.tags_key, "sheen").a
}