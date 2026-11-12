package ui

import "core:fmt"
import "core:math"
import "../draw"
import "../platform"

// Color pickers: a saturation/value square, a hue bar and an alpha bar. They edit values owned by the caller (hue, sat, val,
// alpha all in 0..1) and return true when the user changed something. Each is a Tab stop: the arrows move it by a hundredth
// (Shift: a tenth; the hue by a degree, Shift: ten), Home / End go to the ends of a bar; screen readers see sliders.

Picker_Draw :: struct { hue, sat, val, alpha: f32, horizontal: bool }

@(private = "file") PICKER_MARKER_EM :: 0.55
// Every marker: a dark ring with a white one over it.
@(private = "file") PICKER_SHADOW_STROKE_PX :: 3
@(private = "file") PICKER_RING_STROKE_PX :: 2
@(private = "file") HUE_BANDS :: 6                  // the hue circle's six sides, each a gradient
@(private = "file") HUE_MARKER_HALF_HEIGHT_PX :: 3
@(private = "file") HUE_MAX :: 0.9999               // hue 1 is hue 0: the bar's end stays the bar's end
@(private = "file") HUE_DEGREES :: 360
// The keyboard's steps: a hundredth of the way, a tenth with Shift; the hue by a degree, ten with Shift.
@(private = "file") PICKER_KEY_STEP :: 0.01
@(private = "file") PICKER_KEY_STEP_LARGE :: 0.1
@(private = "file") HUE_KEY_DEGREES :: 1
@(private = "file") HUE_KEY_DEGREES_LARGE :: 10
@(private = "file") PERCENT :: 100
// The squares of the checkerboard under a colour that is not opaque, and their two greys (sRGB).
CHECKER_EM :: 0.4
@(private = "file") CHECKER_LIGHT :: 1.0
@(private = "file") CHECKER_DARK :: 0.8

@(private)
sat_val_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	rad := box_drawn_radius(gs(), b)
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

// A bar's marker at `t` (0..1) along it.
@(private = "file")
bar_marker :: proc(dc: ^draw.Context, r: Rect, t: f32, horizontal: bool) {
	sc := scale()
	half := HUE_MARKER_HALF_HEIGHT_PX * sc
	m: Rect
	if horizontal {
		x := r.min.x + t * (r.max.x - r.min.x)
		m = {{x - half, r.min.y - 2 * sc}, {x + half, r.max.y + 2 * sc}}
	} else {
		y := r.min.y + t * (r.max.y - r.min.y)
		m = {{r.min.x - 2 * sc, y - half}, {r.max.x + 2 * sc, y + half}}
	}
	draw.rect(dc, m, {0, 0, 0, 0.5}, half, PICKER_SHADOW_STROKE_PX * sc)
	draw.rect(dc, m, {1, 1, 1, 1}, half, PICKER_RING_STROKE_PX * sc)
}

@(private)
hue_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	long := d.horizontal ? r.max.x - r.min.x : r.max.y - r.min.y
	rr := box_drawn_radius(gs(), b)
	for i in 0 ..< HUE_BANDS {
		a := long * f32(i) / HUE_BANDS
		z := long * f32(i + 1) / HUE_BANDS + 0.5
		c0, c1 := draw.hsv(f32(i) / HUE_BANDS, 1, 1), draw.hsv(f32(i + 1) / HUE_BANDS, 1, 1)
		first, last := i == 0 ? rr : 0, i == HUE_BANDS - 1 ? rr : 0
		// corner order: top-left, bottom-left, top-right, bottom-right
		if d.horizontal {
			draw.rect_corners(dc, {{r.min.x + a, r.min.y}, {r.min.x + min(z, long), r.max.y}}, {c0, c0, c1, c1}, {first, first, last, last})
		} else {
			draw.rect_corners(dc, {{r.min.x, r.min.y + a}, {r.max.x, r.min.y + min(z, long)}}, {c0, c1, c0, c1}, {first, last, first, last})
		}
	}
	bar_marker(dc, r, d.hue, d.horizontal)
}

// A checkerboard in `r` (under a colour that may be transparent).
checker_draw :: proc(dc: ^draw.Context, r: Rect, em: f32) {
	draw.rect(dc, r, draw.srgb(CHECKER_LIGHT, CHECKER_LIGHT, CHECKER_LIGHT))
	k := max(math.round(em * CHECKER_EM), 1)
	dark := draw.srgb(CHECKER_DARK, CHECKER_DARK, CHECKER_DARK)
	draw.push_clip(dc, r)
	defer draw.pop_clip(dc)
	for y, j := r.min.y, 0; y < r.max.y; y, j = y + k, j + 1 {
		for x, i := r.min.x, 0; x < r.max.x; x, i = x + k, i + 1 {
			if (i + j) % 2 == 1 { draw.rect(dc, {{x, y}, {x + k, y + k}}, dark) }
		}
	}
}

@(private)
alpha_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Picker_Draw)(user)
	r := b.rect
	checker_draw(dc, r, b.font_size)
	c := draw.hsv(d.hue, d.sat, d.val)
	clear_c := c
	clear_c.a = 0
	br := box_drawn_radius(gs(), b)
	if d.horizontal {
		draw.rect_corners(dc, r, {clear_c, clear_c, c, c}, {br, br, br, br})
	} else {
		draw.rect_corners(dc, r, {clear_c, c, clear_c, c}, {br, br, br, br})
	}
	bar_marker(dc, r, d.alpha, d.horizontal)
}

// The keyboard's move of a bar or of one axis of the square: `-1` / `+1` keys, a small or a large step.
@(private = "file")
picker_step :: proc(less, more: [2]bool, small, large: f32) -> f32 {
	v: f32
	if less[0] { v -= small }
	if more[0] { v += small }
	if less[1] { v -= large }
	if more[1] { v += large }
	return v
}

@(private = "file")
Key_Name :: enum u8 { Left, Right, Up, Down }

@(private = "file")
key_press_name :: proc(k: Key_Name, mods: platform.Modifiers) -> bool {
	switch k {
	case .Left:  return key_press(.Left, mods)
	case .Right: return key_press(.Right, mods)
	case .Up:    return key_press(.Up, mods)
	case .Down:  return key_press(.Down, mods)
	}
	return false
}

sat_val_picker :: proc(id: string, hue: f32, sat, val: ^f32) -> (changed: bool) {
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	sig := signal(b)
	if sig.pointer_pressed || sig.dragging {
		w, h := b.rect.max.x - b.rect.min.x, b.rect.max.y - b.rect.min.y
		if w > 1 && h > 1 {
			sat^ = clamp((gs().mouse.x - b.rect.min.x) / w, 0, 1)
			val^ = 1 - clamp((gs().mouse.y - b.rect.min.y) / h, 0, 1)
			changed = true
		}
	}
	if sig.focused {
		ds := picker_step(arrows(.Left), arrows(.Right), PICKER_KEY_STEP, PICKER_KEY_STEP_LARGE)
		dv := picker_step(arrows(.Down), arrows(.Up), PICKER_KEY_STEP, PICKER_KEY_STEP_LARGE)
		if ds != 0 || dv != 0 {
			sat^, val^ = clamp(sat^ + ds, 0, 1), clamp(val^ + dv, 0, 1)
			changed = true
		}
	}
	d := frame_new(Picker_Draw)
	d.hue, d.sat, d.val = hue, sat^, val^
	b.custom, b.custom_user = sat_val_draw, d
	a11y_default(b, {role = .Slider, name = "Saturation and value", orientation = .X,
		value = fmt.aprintf("saturation %.0f%%, value %.0f%%", sat^ * PERCENT, val^ * PERCENT, allocator = frame_allocator())})
	return
}

// The hue bar, from top to bottom (`horizontal`: from left to right).
hue_picker :: proc(id: string, hue: ^f32, horizontal := false) -> (changed: bool) {
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	sig := signal(b)
	if t, ok := bar_input(b, sig, horizontal); ok {
		hue^ = clamp(t, 0, HUE_MAX)
		changed = true
	}
	if sig.focused {
		dh := picker_step(arrows(horizontal ? .Left : .Up), arrows(horizontal ? .Right : .Down), f32(HUE_KEY_DEGREES) / HUE_DEGREES, f32(HUE_KEY_DEGREES_LARGE) / HUE_DEGREES)
		if key_press(.Home) { hue^, changed = 0, true }
		if key_press(.End) { hue^, changed = HUE_MAX, true }
		if dh != 0 { hue^, changed = clamp(hue^ + dh, 0, HUE_MAX), true }
	}
	if v, ok := a11y_numeric_request(b.key, hue^ * HUE_DEGREES, HUE_KEY_DEGREES); ok { hue^, changed = clamp(v / HUE_DEGREES, 0, HUE_MAX), true }
	d := frame_new(Picker_Draw)
	d.hue, d.horizontal = hue^, horizontal
	b.custom, b.custom_user = hue_draw, d
	a11y_default(b, {role = .Slider, name = "Hue", numeric = f64(math.round(hue^ * HUE_DEGREES)), min = 0, max = HUE_DEGREES, step = HUE_KEY_DEGREES, orientation = horizontal ? .X : .Y})
	return
}

// The alpha bar of the colour (hue, sat, val): from transparent to opaque, over a checkerboard, left to right (or top to bottom).
alpha_picker :: proc(id: string, hue, sat, val: f32, alpha: ^f32, horizontal := true) -> (changed: bool) {
	b := build_box({.Clickable, .Focusable}, id)
	b.cursor = .Hand
	sig := signal(b)
	if t, ok := bar_input(b, sig, horizontal); ok {
		alpha^ = clamp(t, 0, 1)
		changed = true
	}
	if sig.focused {
		da := picker_step(arrows(horizontal ? .Left : .Up), arrows(horizontal ? .Right : .Down), PICKER_KEY_STEP, PICKER_KEY_STEP_LARGE)
		if key_press(.Home) { alpha^, changed = 0, true }
		if key_press(.End) { alpha^, changed = 1, true }
		if da != 0 { alpha^, changed = clamp(alpha^ + da, 0, 1), true }
	}
	if v, ok := a11y_numeric_request(b.key, alpha^ * PERCENT, PICKER_KEY_STEP * PERCENT); ok { alpha^, changed = clamp(v / PERCENT, 0, 1), true }
	d := frame_new(Picker_Draw)
	d.hue, d.sat, d.val, d.alpha, d.horizontal = hue, sat, val, alpha^, horizontal
	b.custom, b.custom_user = alpha_draw, d
	a11y_default(b, {role = .Slider, name = "Opacity", numeric = f64(math.round(alpha^ * PERCENT)), min = 0, max = PERCENT, step = PICKER_KEY_STEP * PERCENT, orientation = horizontal ? .X : .Y})
	return
}

// Where a press or a drag puts a bar's marker (0..1 along it).
@(private = "file")
bar_input :: proc(b: ^Box, sig: Signal, horizontal: bool) -> (t: f32, ok: bool) {
	if !sig.pointer_pressed && !sig.dragging { return }
	r := b.rect
	long := horizontal ? r.max.x - r.min.x : r.max.y - r.min.y
	if long <= 1 { return }
	at := horizontal ? gs().mouse.x - r.min.x : gs().mouse.y - r.min.y
	return clamp(at / long, 0, 1), true
}

// The presses of this build of an arrow, without and with Shift.
@(private = "file")
arrows :: proc(k: Key_Name) -> [2]bool { return {key_press_name(k, {}), key_press_name(k, {.Shift})} }
