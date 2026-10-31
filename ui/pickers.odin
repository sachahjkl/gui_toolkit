package ui

import "../draw"

// Color pickers: a saturation/value square and a hue bar. They edit HSV values owned by the caller
// (hue, sat, val all in 0..1) and return true when the user changed something.

Picker_Draw :: struct { hue, sat, val: f32 }

@(private = "file") PICKER_MARKER_EM :: 0.55
// Every marker: a dark ring with a white one over it.
@(private = "file") PICKER_SHADOW_STROKE_PX :: 3
@(private = "file") PICKER_RING_STROKE_PX :: 2
@(private = "file") HUE_BANDS :: 6                  // the hue circle's six sides, each a gradient
@(private = "file") HUE_MARKER_HALF_HEIGHT_PX :: 3
@(private = "file") HUE_MAX :: 0.9999               // hue 1 is hue 0: the bar's end stays the bar's end

@(private)
sat_val_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	rad := b.radius
	hue_c := draw.hsv(d.hue, 1, 1)
	white, clear_c, black := Color{1, 1, 1, 1}, Color{0, 0, 0, 0}, Color{0, 0, 0, 1}
	// corner order: top-left, bottom-left, top-right, bottom-right
	draw.rect_corners(dc, r, {white, white, hue_c, hue_c}, {rad, rad, rad, rad})
	draw.rect_corners(dc, r, {clear_c, black, clear_c, black}, {rad, rad, rad, rad})
	x := r.min.x + d.sat * (r.max.x - r.min.x)
	y := r.min.y + (1 - d.val) * (r.max.y - r.min.y)
	k := b.font_size * PICKER_MARKER_EM
	sc := scale()
	draw.rect(dc, {{x - k, y - k}, {x + k, y + k}}, {0, 0, 0, 0.5}, k, PICKER_SHADOW_STROKE_PX * sc)
	draw.rect(dc, {{x - k, y - k}, {x + k, y + k}}, {1, 1, 1, 1}, k, PICKER_RING_STROKE_PX * sc)
}

@(private)
hue_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	h := r.max.y - r.min.y
	for i in 0 ..< HUE_BANDS {
		y0 := r.min.y + h * f32(i) / HUE_BANDS
		y1 := r.min.y + h * f32(i + 1) / HUE_BANDS
		c0, c1 := draw.hsv(f32(i) / HUE_BANDS, 1, 1), draw.hsv(f32(i + 1) / HUE_BANDS, 1, 1)
		rr := b.radius
		radii := [4]f32{i == 0 ? rr : 0, i == HUE_BANDS - 1 ? rr : 0, i == 0 ? rr : 0, i == HUE_BANDS - 1 ? rr : 0}
		draw.rect_corners(dc, {{r.min.x, y0}, {r.max.x, y1 + 0.5}}, {c0, c1, c0, c1}, radii)
	}
	y := r.min.y + d.hue * h
	sc := scale()
	half := HUE_MARKER_HALF_HEIGHT_PX * sc
	draw.rect(dc, {{r.min.x - 2 * sc, y - half}, {r.max.x + 2 * sc, y + half}}, {0, 0, 0, 0.5}, half, PICKER_SHADOW_STROKE_PX * sc)
	draw.rect(dc, {{r.min.x - 2 * sc, y - half}, {r.max.x + 2 * sc, y + half}}, {1, 1, 1, 1}, half, PICKER_RING_STROKE_PX * sc)
}

sat_val_picker :: proc(id: string, hue: f32, sat, val: ^f32) -> (changed: bool) {
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	sig := signal(b)
	if sig.pressed || sig.dragging {
		w, h := b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y
		if w > 1 && h > 1 {
			sat^ = clamp((g.mouse.x - b.rect.min.x) / w, 0, 1)
			val^ = 1 - clamp((g.mouse.y - b.rect.min.y) / h, 0, 1)
			changed = true
		}
	}
	d := frame_new(Picker_Draw)
	d.hue, d.sat, d.val = hue, sat^, val^
	b.custom, b.custom_user = sat_val_draw, d
	return
}

hue_picker :: proc(id: string, hue: ^f32) -> (changed: bool) {
	b := build_box({.Clickable}, id)
	b.cursor = .Hand
	sig := signal(b)
	if sig.pressed || sig.dragging {
		h := b.rect.max.y - b.rect.min.y
		if h > 1 {
			hue^ = clamp((g.mouse.y - b.rect.min.y) / h, 0, HUE_MAX)
			changed = true
		}
	}
	d := frame_new(Picker_Draw)
	d.hue = hue^
	b.custom, b.custom_user = hue_draw, d
	return
}
