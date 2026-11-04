package ui

import "core:hash"
import "core:math"
import "core:slice"
import "../draw"

// The colour picker: a saturation / value square, a hue bar and an opacity bar beside the colour it was opened with and the
// new one (a click on the old one takes it back), a switch of the text's format (hex, rgb, hsl, oklch) and the colour as text.
// Every part is a Tab stop: the square and the bars move by the arrows (sat_val_picker, hue_picker, alpha_picker), the
// switch is a radio group, the text is a field whose colour applies as it is typed. The caller owns the state:
//
//   cp: ui.Color_Pick
//   ui.color_pick_set(&cp, rgba, style)            // where it starts, and the "old" colour
//   if ui.color_picker("###pick", &cp) { write(ui.color_pick_text(&cp)) }   // every change (color_picker_width() wide)
//   ui.color_pick_destroy(&cp)
//
// No eyedropper: the platform layer reads no pixel of the screen.

Color_Pick :: struct {
	hue, sat, val, alpha: f32,   // the colour in the picker's coordinates (sRGB HSV: a grey keeps its hue)
	style:  Color_Style,         // how the text writes it
	old:    Srgba,               // the colour it was opened with
	field:  Text_Field,
	typed:  bool,                // the last change came from the field: its text is the colour as the user wrote it
	shown:  u64,                 // what the field's text was made from (the text it would write), to make it again on a change
}

@(private = "file") COLOR_PICKER_EM :: 17          // its width (four format names side by side)
@(private = "file") SQUARE_SHARE :: 0.62           // the square's height, of the width
@(private = "file") BAR_EM :: 0.9                  // the bars' height
@(private = "file") SWATCH_EM :: 2.3               // the old and new colours, each a square this large
@(private = "file") GAP_EM :: 0.5
@(private = "file") ROW_EM :: 1.9                  // the format switch and the field
@(private = "file") SWATCH_RADIUS_EM :: 0.25

color_picker_width :: proc() -> f32 { return math.round(font_size() * COLOR_PICKER_EM) }

color_pick_destroy :: proc(cp: ^Color_Pick) { field_destroy(&cp.field) }

// Starts the picker on `c` written in `style` (its old colour too).
color_pick_set :: proc(cp: ^Color_Pick, c: Srgba, style: Color_Style) {
	cp.hue, cp.sat, cp.val = srgb_to_hsv(c.rgb)
	cp.alpha, cp.style, cp.old, cp.typed, cp.shown = c.a, style, c, false, 0
}

color_pick_rgba :: proc(cp: ^Color_Pick) -> Srgba {
	rgb := hsv_to_srgb(cp.hue, cp.sat, cp.val)
	return {rgb[0], rgb[1], rgb[2], cp.alpha}
}

// The colour as text: as typed when it was typed, else written in the picker's style (temporary allocator).
color_pick_text :: proc(cp: ^Color_Pick) -> string {
	if cp.typed { return field_string(&cp.field) }
	return color_text(color_pick_rgba(cp), cp.style)
}

@(private = "file")
color_pick_from :: proc(cp: ^Color_Pick, c: Srgba) {
	h, s, v := srgb_to_hsv(c.rgb)
	if s > 0 && v > 0 { cp.hue = h }   // (a grey or black keeps the hue it had)
	if v > 0 { cp.sat = s }
	cp.val, cp.alpha = v, c.a
}

@(private = "file")
Swatch_Draw :: struct { c: Srgba }

@(private = "file")
swatch_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Swatch_Draw)(user)
	draw.push_clip(dc, b.rect)
	defer draw.pop_clip(dc)
	checker_draw(dc, b.rect, b.font_size)
	draw.rect(dc, b.rect, draw.srgb(d.c.r, d.c.g, d.c.b, d.c.a), b.radius)
}

color_picker :: proc(id: string, cp: ^Color_Pick) -> (changed: bool) {
	em := font_size()
	w := color_picker_width()
	gap := math.round(em * GAP_EM)
	next({width = px(w), height = children_sum(), axis = .Y})
	root := build_box({}, id)
	a11y_default(root, {role = .Group, name = "Colour picker"})
	push_parent(root)
	defer pop_parent()

	next({width = px(w), height = px(math.round(w * SQUARE_SHARE)), radius = em * SWATCH_RADIUS_EM})
	if sat_val_picker("###square", cp.hue, &cp.sat, &cp.val) { changed = true; cp.typed = false }
	spacer(px(gap))
	next({width = px(w), height = children_sum(), axis = .X, cross = .Center})
	if row(.Center) {
		sw := math.round(em * SWATCH_EM)
		// the old colour (a click takes it back) and the new one
		for k in 0 ..< 2 {
			next({width = px(sw), height = px(sw), radius = em * SWATCH_RADIUS_EM})
			b := build_box(k == 0 ? {.Clickable, .Focusable, .Draw_Border} : {.Draw_Border}, k == 0 ? "###old" : "###new")
			d := frame_new(Swatch_Draw)
			d.c = k == 0 ? cp.old : color_pick_rgba(cp)
			b.custom, b.custom_user = swatch_draw, d
			if k == 0 {
				b.cursor = .Hand
				if signal(b).clicked { color_pick_from(cp, cp.old); changed = true; cp.typed = false }
				a11y_default(b, {role = .Button, name = "Take back the colour it had"})
			} else {
				a11y_default(b, {role = .Image, name = "New colour"})
			}
		}
		spacer(px(gap))
		next({width = fill(), height = children_sum(), axis = .Y})
		if column() {
			next({width = pct(1), height = px(math.round(em * BAR_EM)), radius = em * BAR_EM * 0.5})
			if hue_picker("###hue", &cp.hue, horizontal = true) { changed = true; cp.typed = false }
			spacer(px(gap))
			next({width = pct(1), height = px(math.round(em * BAR_EM)), radius = em * BAR_EM * 0.5})
			if alpha_picker("###alpha", cp.hue, cp.sat, cp.val, &cp.alpha) { changed = true; cp.typed = false }
		}
	}
	spacer(px(gap))
	format := int(cp.style.format)
	next({width = px(w), height = px(math.round(em * ROW_EM))})
	if segmented("###format", slice.enumerated_array(&COLOR_FORMAT_NAMES), &format) {
		cp.style = {Color_Format(format), cp.style.legacy && Color_Format(format) != .Hex}
		cp.typed = false
		changed = true
	}
	spacer(px(gap))
	// the text: made again when the colour or the format changed elsewhere (not while it is being typed in)
	key := key_from_string(root.key, "###text")
	want := color_text(color_pick_rgba(cp), cp.style)
	h := hash.fnv64a(transmute([]u8)want)
	if focus_key() != key && !cp.typed && h != cp.shown { field_set(&cp.field, want); cp.shown = h }
	next({width = px(w), height = px(math.round(em * ROW_EM)), font = mono_font(), radius = em * SWATCH_RADIUS_EM})
	res := line_edit("###text", &cp.field)
	a11y_default(res.box, {role = .Text_Input, name = "Colour"})
	if res.changed {
		if c, style, ok := color_parse(field_string(&cp.field)); ok {
			color_pick_from(cp, c)
			cp.style, cp.typed, changed = style, true, true
			cp.shown = hash.fnv64a(transmute([]u8)color_text(color_pick_rgba(cp), cp.style))
		}
	}
	if !res.focused && cp.typed && focus_key() != key { cp.typed = false }   // (left: written as the picker writes it)
	return
}
