package ui

import "core:strings"
import "../draw"
import "../font"

Fuzzy_Range :: [2]int   // byte offsets [start, end) in the haystack

// Every space-separated part of `needle` must occur (case-insensitively) in `hay`, outside the ranges already taken by
// earlier parts. Returns the matched ranges. An empty needle matches everything with no ranges.
fuzzy_find :: proc(needle, hay: string, allocator := context.temp_allocator) -> (ranges: []Fuzzy_Range, ok: bool) {
	parts := strings.fields(needle, context.temp_allocator)
	if len(parts) == 0 { return nil, true }
	low_hay := strings.to_lower(hay, context.temp_allocator)
	out := make([dynamic]Fuzzy_Range, allocator)
	for part in parts {
		low := strings.to_lower(part, context.temp_allocator)
		pos := 0
		found := false
		for pos <= len(low_hay) - len(low) {
			i := strings.index(low_hay[pos:], low)
			if i < 0 { break }
			start := pos + i
			overlap := false
			for r in out { if start < r[1] && start + len(low) > r[0] { overlap = true; pos = r[1]; break } }
			if overlap { continue }
			append(&out, Fuzzy_Range{start, start + len(low)})
			found = true
			break
		}
		if !found { return nil, false }
	}
	return out[:], true
}

Fuzzy_Draw :: struct { ranges: []Fuzzy_Range, text: string, color: Color }

@(private)
fuzzy_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Fuzzy_Draw)(user)
	s := g
	dim := Vec2{b.text_dim.x, b.text_dim.y}
	origin := text_origin(s, b, dim)
	m := font.metrics(s.fonts, b.font, b.font_size)
	for r in d.ranges {
		x0 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[0]])
		x1 := origin.x + font.text_width(s.fonts, b.font, b.font_size, d.text[:r[1]])
		cy := (b.rect.min.y + b.rect.max.y) * 0.5
		draw.rect(dc, {{x0, cy - m.line_height * 0.5}, {x1, cy + m.line_height * 0.5}}, d.color, 2)
	}
}

// A label whose matched ranges (from `fuzzy_find`) are highlighted with the accent color.
label_fuzzy :: proc(text: string, ranges: []Fuzzy_Range) -> Signal {
	b := build_box({.Draw_Text}, text)
	if len(ranges) > 0 {
		d := frame_new(Fuzzy_Draw)
		d.ranges = make([]Fuzzy_Range, len(ranges), frame_allocator())
		copy(d.ranges, ranges)
		d.text = b.text
		d.color = color("accent")
		d.color.a *= 0.30
		d.color = tuned(d.color)
		b.custom, b.custom_user = fuzzy_draw, d
	}
	return signal(b)
}
