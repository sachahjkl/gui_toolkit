package ui

import "core:math"
import "core:strings"
import "../draw"
import "../font"

// Paints the box tree built by the last build. Parents first, then children (later siblings on top);
// borders, focus rings and the disabled overlay are drawn after the children so they land above them.
draw_tree :: proc(s: ^State, dc: ^draw.Context) {
	g = s
	draw_box(s, dc, s.root, s.scale)
}

@(private)
draw_box :: proc(s: ^State, dc: ^draw.Context, b: ^Box, scale: f32) {
	r := b.rect
	radius := b.radius
	flags := b.flags
	if b.transparency != 0 { draw.push_alpha(dc, 1 - b.transparency) }
	squished := b.squish > 0.001
	if squished { draw.push_scale(dc, draw.rect_center(r), 1 - b.squish) }

	if .Draw_Shadow in flags {
		sc := color_from_tags(s, b.tags_key, "drop_shadow")
		draw.rect(dc, draw.rect_shift(draw.rect_pad(r, 8 * scale), {4 * scale, 4 * scale}), sc, radius, 0, 8 * scale)
	}
	if .Draw_Background in flags {
		draw.rect(dc, r, b.bg, radius)
	}
	if .Draw_Hot_Effects in flags {
		h := color_from_tags(s, b.tags_key, "hover")
		h.a *= 0.014 * b.hot_t * (1 - b.active_t) + 0.02 * b.active_t   // blending is in linear space: tiny alphas
		draw.rect(dc, r, h, radius)
	}
	if .Draw_Text in flags && b.text != "" { draw_box_text(s, dc, b) }

	if .Clip in flags { draw.push_clip(dc, r) }
	if b.custom != nil { b.custom(b, b.custom_user, dc) }
	for c := b.first; c != nil; c = c.next { draw_box(s, dc, c, scale) }
	if .Clip in flags { draw.pop_clip(dc) }

	if .Draw_Border in flags { draw.rect(dc, r, b.border, radius, max(1, math.round(scale))) }
	if flags & {.Draw_Side_Top, .Draw_Side_Bottom, .Draw_Side_Left, .Draw_Side_Right} != {} {
		t := max(1, math.round(scale))
		if .Draw_Side_Top in flags    { draw.rect(dc, {r.min, {r.max.x, r.min.y + t}}, b.border) }
		if .Draw_Side_Bottom in flags { draw.rect(dc, {{r.min.x, r.max.y - t}, r.max}, b.border) }
		if .Draw_Side_Left in flags   { draw.rect(dc, {r.min, {r.min.x + t, r.max.y}}, b.border) }
		if .Draw_Side_Right in flags  { draw.rect(dc, {{r.max.x - t, r.min.y}, r.max}, b.border) }
	}
	if .Draw_Focus_Ring in flags && b.focus_t > 0.01 {
		c := color_from_tags(s, b.tags_key, "focus border")
		c.a *= b.focus_t
		draw.rect(dc, r, c, radius, 1.5 * scale)
	}
	if b.disabled_t > 0.005 {
		c := color_from_tags(s, b.tags_key, "background")
		c.a = b.disabled_t * 0.5
		draw.rect(dc, r, c, radius)
	}

	if squished { draw.pop_xform(dc) }
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
