package ui

import "core:math"
import "../draw"

// Color pickers: a saturation/value square and a hue bar. They edit HSV values owned by the caller
// (hue, sat, val all in 0..1) and return true when the user changed something.

Picker_Draw :: struct { hue, sat, val: f32, ring: Color }

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
	k := b.font_size * 0.55
	draw.rect(dc, {{x - k, y - k}, {x + k, y + k}}, {0, 0, 0, 0.5}, k, 3)
	draw.rect(dc, {{x - k, y - k}, {x + k, y + k}}, {1, 1, 1, 1}, k, 2)
}

@(private)
hue_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	h := r.max.y - r.min.y
	for i in 0 ..< 6 {
		y0 := r.min.y + h * f32(i) / 6
		y1 := r.min.y + h * f32(i + 1) / 6
		c0, c1 := draw.hsv(f32(i) / 6, 1, 1), draw.hsv(f32(i + 1) / 6, 1, 1)
		rr := b.radius
		radii := [4]f32{i == 0 ? rr : 0, i == 5 ? rr : 0, i == 0 ? rr : 0, i == 5 ? rr : 0}
		draw.rect_corners(dc, {{r.min.x, y0}, {r.max.x, y1 + 0.5}}, {c0, c1, c0, c1}, radii)
	}
	y := r.min.y + d.hue * h
	draw.rect(dc, {{r.min.x - 2, y - 3}, {r.max.x + 2, y + 3}}, {0, 0, 0, 0.5}, 3, 3)
	draw.rect(dc, {{r.min.x - 2, y - 3}, {r.max.x + 2, y + 3}}, {1, 1, 1, 1}, 3, 2)
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
			hue^ = clamp((g.mouse.y - b.rect.min.y) / h, 0, 0.9999)
			changed = true
		}
	}
	d := frame_new(Picker_Draw)
	d.hue = hue^
	b.custom, b.custom_user = hue_draw, d
	return
}

_ :: math
