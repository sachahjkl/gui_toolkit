package ui

// Pieces of a dense dashboard (a console's look; they serve every theme):
//
//   section_header("###mem", "Memory", "what the boot program left", "462 MiB", hue(.Cyan))
//                                  a stripe of the hue, its title in capitals in the hue, a note, a value at its right
//   tile("###t3", "rect.wgsl", hue(.Green))      a tile of colour with its words: in a flow, a wall of them
//   stacked_bar("###time", parts)                 a bar cut in parts of their colours, each part's words in it
//   if title_strip("###win", "Boot") { ... }      a dialog's title on a strip of the accent fading to the bar; true: closed
//
// In the edged and machined finishes a tile, a part and a strip are lit along their top and shaded along their bottom.

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import "../font"

// The hues of the theme shown (its palette's), for what a program colours by meaning.
Hue :: enum u8 { Accent, Blue, Purple, Green, Yellow, Red, Cyan, Rose }

// The colour of a hue of the theme shown.
hue :: proc(h: Hue) -> Color {
	NAMES :: [Hue]string{.Accent = "hue_accent", .Blue = "hue_blue", .Purple = "hue_purple", .Green = "hue_green", .Yellow = "hue_yellow", .Red = "hue_red", .Cyan = "hue_cyan", .Rose = "hue_rose"}
	names := NAMES
	return color_from_tags(gs(), 0, names[h])
}

// A section's stripe (logical pixels at 100 %), the gap after it, the title's size (of the font's), the value's.
@(private = "file") SECTION_STRIPE_PX :: 3
@(private = "file") SECTION_TITLE_SCALE :: 0.85
@(private = "file") SECTION_VALUE_SCALE :: 1.5

// A section's header: a stripe of `c`, `title` in capitals and bold in `c`, `note` weak after it, `value` large at its right
// ("" : none). As tall as its words; full width, or as wide as its words when `inline` (in a row with other things).
section_header :: proc(id, title: string, note := "", value := "", c: Color, inline := false) {
	s := gs()
	em := font_size()
	st := top_style()
	bold := styled_face(st.font, true, false)
	next({width = inline ? children_sum() : fill(), height = children_sum()})
	set_next_axis(.X, .Center)
	row_box := build_box({}, id)
	a11y_default(row_box, {role = .Heading, name = title})
	push_parent(row_box)
	defer pop_parent()
	next({width = px(math.max(1, math.round(SECTION_STRIPE_PX * s.scale))), height = px(math.round(em * 1.1)), bg = c})
	build_box({.Draw_Background}, "###stripe")
	spacer(px(em * 0.55))
	small := math.round(em * SECTION_TITLE_SCALE)   // (the title and its note: one size, one line)
	next({width = text_size(), height = text_size(), text_pad = 0, font = bold, font_size = small, fg = c})
	build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###title", strings.to_upper(title, context.temp_allocator)))
	if note != "" {
		spacer(px(em * 0.7))
		push_tags("weak")
		next({width = inline ? text_size() : fill(), height = text_size(), text_pad = 0, font_size = small})
		build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###note", note))
		pop_tags()
	} else if !inline {
		spacer(fill())
	}
	if value != "" {
		spacer(px(em * 0.7))
		next({width = text_size(), height = text_size(), text_pad = 0, font = mono_font(), font_size = math.round(em * SECTION_VALUE_SCALE), fg = color("text")})
		build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###value", value))
	}
}

// How much of a tile's hue is over what is under it; its text toward white.
@(private = "file") TILE_TINT :: 0.55
@(private = "file") TILE_TEXT :: 0.85

@(private)
Tile_Draw :: struct { face: Color }

@(private)
tile_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tile_Draw)(user)
	face := draw.mix(d.face, Color{1, 1, 1, 1}, 0.06 * b.hot_t)
	relief_face(dc, b.rect, face, b.radius)
	draw_box_text(gs(), dc, b)   // (over its face: a box's own text is drawn before its custom drawing)
}

// A raised face of colour `c` in the finish shown: in the edged and machined ones a lit line along its top, a darker one
// along its bottom, a dark hairline around; else a plain face. For a program's own tiles and parts.
relief_face :: proc(dc: ^draw.Context, r: Rect, c: Color, radius: f32) {
	draw.rect(dc, r, c, radius)
	if !machined() || r.max.y - r.min.y < 4 { return }
	p := px1()
	inset := max(p, radius * 0.6)
	draw.rect(dc, {{r.min.x + inset, r.min.y}, {r.max.x - inset, r.min.y + p}}, {1, 1, 1, 0.22})
	draw.rect(dc, {{r.min.x + inset, r.max.y - 2 * p}, {r.max.x - inset, r.max.y}}, {0, 0, 0, 0.25})
	draw.rect(dc, r, {0, 0, 0, 0.55}, radius, p)
}

// A tile of colour `c` with `text` on it, as wide as its words (in a `flow`: a wall of tiles). `clickable`: it answers the
// pointer. Its face is `c` over what is under it; its text light.
tile :: proc(id, text: string, c: Color, clickable := false) -> Signal {
	em := font_size()
	next({width = text_size(em * 0.45), height = px(dense(em * 1.6)), text_align = .Center, font = mono_font(), radius = rad(em * 0.15), fg = draw.mix(c, Color{1, 1, 1, 1}, TILE_TEXT)})
	flags: Box_Flags = {.No_Text_Trunc}
	if clickable { flags += {.Clickable} }
	b := build_box(flags, fmt.tprintf("%s###%s", text, id))
	d := frame_new(Tile_Draw)
	d.face = srgb_mix(box_under(b.parent != nil ? b.parent : b), c, TILE_TINT)
	d.face.a = 1
	b.custom, b.custom_user = tile_draw, d
	if clickable { a11y_default(b, {role = .Button, name = text}) }
	return signal(b)
}

// A part of a stacked bar: its share (any unit: the parts are their shares of the sum), its colour, its words ("": none;
// shown when they fit).
Bar_Part :: struct {
	value: f32,
	color: Color,
	label: string,
}

@(private)
Stacked_Draw :: struct { parts: []Bar_Part, total: f32, well: Color }

@(private)
stacked_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	s := gs()
	d := (^Stacked_Draw)(user)
	r := b.rect
	if machined() { machined_well(dc, r, 0, d.well) } else { draw.rect(dc, r, d.well) }
	if d.total <= 0 { return }
	w := r.max.x - r.min.x
	x := r.min.x
	sz := b.font_size
	for part, i in d.parts {
		x1 := i == len(d.parts) - 1 ? r.min.x + w * min(1, part.value / d.total + (x - r.min.x) / w) : math.round(x + w * part.value / d.total)
		pr := Rect{{x, r.min.y}, {x1, r.max.y}}
		x = x1
		if pr.max.x - pr.min.x < 1 { continue }
		relief_face(dc, pr, part.color, 0)
		if part.label == "" { continue }
		tw := font.text_width(s.fonts, b.font, sz, part.label)
		if tw + sz > pr.max.x - pr.min.x { continue }
		m := font.metrics(s.fonts, b.font, sz)   // (a baseline: as text_origin centres a line)
		lum := 0.2126 * part.color.r + 0.7152 * part.color.g + 0.0722 * part.color.b
		ink := lum > 0.25 ? Color{0.02, 0.03, 0.05, 1} : Color{1, 1, 1, 1}   // (linear light: a mid colour reads dark text)
		pos := Vec2{math.round((pr.min.x + pr.max.x - tw) * 0.5), math.round((pr.min.y + pr.max.y + m.ascent - m.descent) * 0.5)}
		draw.text(dc, b.font, sz, pos, ink, part.label)
	}
}

// A bar cut in `parts` of their colours, in order, each as long as its share; the words of each in it when they fit. Size
// from `next` (full width, two lines high by default).
stacked_bar :: proc(id: string, parts: []Bar_Part) {
	em := font_size()
	s := gs()
	if s.next_mod.width == nil { s.next_mod.width = fill() }
	if s.next_mod.height == nil { s.next_mod.height = px(dense(em * 1.9)) }
	s.has_next = true
	if s.next_mod.font == nil { s.next_mod.font = styled_face(mono_font(), true, false) }   // (bold: words on colour)
	b := build_box({}, id)
	d := frame_new(Stacked_Draw)
	d.parts = make([]Bar_Part, len(parts), frame_allocator())
	copy(d.parts, parts)
	for p in parts { d.total += max(0, p.value) }
	d.well = color_from_tags(s, b.tags_key, "well")
	b.custom, b.custom_user = stacked_draw, d
	said := strings.builder_make(frame_allocator())
	for p, i in parts { fmt.sbprintf(&said, "%s%s", i > 0 ? ", " : "", p.label) }
	a11y_default(b, {role = .Image, name = strings.to_string(said)})
}

// A caption's fade in the edged finish: the accent at its left reaches the bar's colour at this fraction of its width, at
// most this far (logical pixels: a wide window's title bar is blue at its start, not along its whole length).
@(private = "file") CAPTION_FADE_END :: 0.9
@(private = "file") CAPTION_FADE_MAX_PX :: 720
// How far the words on an edged caption go toward white: they stand on the accent.
@(private = "file") CAPTION_INK_WHITE :: 0.8

// The face of a title bar (a window's, a dialog's) in the finish shown. In the edged one: the accent fading to `top` from
// the left, a lit line along its top, a dark one along its bottom (a console's window). In the others: `top` at its top to
// `bottom` at its bottom, lit along its top in the machined finish; flat, the colour between them.
caption_face :: proc(dc: ^draw.Context, r: Rect, top, bottom: Color) {
	p := px1()
	switch {
	case !machined():   // (flat: one colour, between the two)
		draw.rect(dc, r, draw.mix(top, bottom, 0.5))
		return
	case !edged():
		draw.rect_corners(dc, r, {top, bottom, top, bottom}, {})
		draw.rect(dc, {r.min, {r.max.x, r.min.y + p}}, {1, 1, 1, 0.05})
		return
	}
	from := color_from_tags(gs(), 0, "accent")
	end := r.min.x + math.min((r.max.x - r.min.x) * CAPTION_FADE_END, CAPTION_FADE_MAX_PX * scale())
	draw.rect_corners(dc, {r.min, {end, r.max.y}}, {from, from, top, top}, {})
	draw.rect(dc, {{end, r.min.y}, r.max}, top)
	draw.rect(dc, {r.min, {r.max.x, r.min.y + p}}, {1, 1, 1, 0.28})
	draw.rect(dc, {{r.min.x, r.max.y - p}, r.max}, {0, 0, 0, 0.45})
}

// The colour words of colour `c` take on a caption_face: in the edged finish toward white (they stand on the accent), else
// `c` itself.
caption_ink :: proc(c: Color) -> Color {
	if !edged() { return c }
	return draw.mix(c, Color{1, 1, 1, c.a}, CAPTION_INK_WHITE)
}

@(private)
Strip_Draw :: struct { top: Color }

@(private)
strip_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Strip_Draw)(user)
	if edged() { caption_face(dc, b.rect, d.top, d.top); return }
	// (outside the edged finish a strip is the accent fading out all the same: it is what the strip is)
	r := b.rect
	from := color_from_tags(gs(), 0, "accent")
	end := r.min.x + (r.max.x - r.min.x) * CAPTION_FADE_END
	draw.rect_corners(dc, {r.min, {end, r.max.y}}, {from, from, d.top, d.top}, {})
	draw.rect(dc, {{end, r.min.y}, r.max}, d.top)
}

@(private)
strip_close_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	close_block(dc, b.rect, b.hot_t, b.active_t)
	// the cross: two strokes of whole pixels
	c := draw.rect_center(b.rect)
	h := math.round((b.rect.max.y - b.rect.min.y) * 0.17)
	t := max(1, math.round(gs().scale * 1.5))
	draw.line(dc, c - {h, h}, c + {h, h}, t, {1, 1, 1, 1})
	draw.line(dc, c + {-h, h}, c + {h, -h}, t, {1, 1, 1, 1})
}

// A red block that closes (title_strip's, an edged window's close button): the theme's red in relief, lighter under the
// pointer, darker held.
@(private)
close_block :: proc(dc: ^draw.Context, r: Rect, hot, held: f32) {
	red := color_from_tags(gs(), 0, "hue_red")
	face := draw.mix(red, Color{1, 1, 1, 1}, 0.12 * hot)
	if held > 0.5 { face = draw.mix(red, Color{0, 0, 0, 1}, 0.2) }
	relief_face(dc, r, face, 0)
}

// `if title_strip(id, "Boot") { open = false }`: a dialog's or a floating panel's title, white and bold on a strip of the
// accent fading to the bar's colour, a red block at its right that closes it (true when clicked). Full width, 2.2 lines.
title_strip :: proc(id, title: string, closable := true) -> (closed: bool) {
	s := gs()
	em := font_size()
	h := dense(em * 2.2)
	next({width = fill(), height = px(h)})
	set_next_axis(.X, .Center)
	b := build_box({}, id)
	d := frame_new(Strip_Draw)
	d.top = color_from_tags(s, 0, "bar background")
	b.custom, b.custom_user = strip_draw, d
	a11y_default(b, {role = .Title_Bar, name = title})
	push_parent(b)
	defer pop_parent()
	spacer(px(em * 0.8))
	next({width = fill(), height = pct(1), font = styled_face(top_style().font, true, false), fg = {1, 1, 1, 1}})
	build_box({.Draw_Text}, fmt.tprintf("%s###title", title))
	if closable {
		next({width = px(math.round(h * 1.25)), height = pct(1)})
		x := build_box({.Clickable}, "###close")
		x.custom = strip_close_draw
		a11y_default(x, {role = .Button, name = "Close"})
		closed = signal(x).clicked
	}
	return
}
