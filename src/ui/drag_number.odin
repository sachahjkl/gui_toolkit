package ui

// A number dragged inside its field, as an instrument sets it (debug-panel.md, "Dense widgets"): the value in the
// mono face at the field's right; a horizontal drag changes it, Shift slower, Ctrl faster; the wheel over it steps it,
// even in a view that scrolls; Up / Down step it from the keyboard (num_step_delta: Shift ten, Ctrl a hundred, Alt a
// tenth); a double click, Ctrl+click or Enter types it, Enter or the keyboard going elsewhere applies what is typed,
// Escape gives the value back. With both bounds, the field fills from the left as a slider's track. A vector is N of
// them on one row (drag_vector), each marked by its axis's colour.
//
//   ui.drag_number("###speed", &app.speed, lo = 0, hi = 10)
//   ui.drag_vector("###position", &app.position, step = 0.01)

import "base:intrinsics"
import "core:fmt"
import "core:math"
import "../draw"
import "../font"
import i18n "../i18n"

// How a dragged number moves, beside its bounds and its step.
Drag_Options :: struct {
	// What one logical pixel of drag adds. 0: the step; with both bounds and no step, the range over DRAG_RANGE_PX;
	// else DRAG_FLOAT_SPEED (a float) or DRAG_INT_SPEED (an integer).
	speed:    f64,
	steppers: bool,    // − and + at the field's ends, held they repeat
	disabled: bool,
	mark:     Color,   // a thin bar at the field's left edge (a vector's axis); zero: none
}

// A pixel of drag with no step: a bounded range crosses in this many pixels; a float moves by this much, an integer by
// this much (ten pixels a unit).
DRAG_RANGE_PX :: 300
DRAG_FLOAT_SPEED :: 0.01
DRAG_INT_SPEED :: 0.1
// The drag's speed with Shift and with Ctrl.
DRAG_SLOW :: 0.1
DRAG_FAST :: 10
// The digits after the point of a float with no step.
DRAG_DECIMALS :: 3

// A number dragged in its field; T: int, f32 or f64. lo, hi: its bounds (nil: none on that side); every way it moves
// clamps it to them and rounds it to step (0: an integer's 1, a float as it comes). One step of the keys and the wheel
// is step (0: 1; a float's a hundredth of its bounded range, else DRAG_FLOAT_SPEED). Its size: next (by default fill
// by a row's height: dense_row_height in a dense scope). True when the value changed this frame.
drag_number :: proc{drag_number_int, drag_number_f32, drag_number_f64}

drag_number_int :: proc(id: string, value: ^int, lo: Maybe(int) = nil, hi: Maybe(int) = nil, step := 0, o := Drag_Options{}) -> (changed: bool) {
	return drag_of(id, value, lo, hi, step, o)
}
drag_number_f32 :: proc(id: string, value: ^f32, lo: Maybe(f32) = nil, hi: Maybe(f32) = nil, step: f32 = 0, o := Drag_Options{}) -> (changed: bool) {
	return drag_of(id, value, lo, hi, step, o)
}
drag_number_f64 :: proc(id: string, value: ^f64, lo: Maybe(f64) = nil, hi: Maybe(f64) = nil, step: f64 = 0, o := Drag_Options{}) -> (changed: bool) {
	return drag_of(id, value, lo, hi, step, o)
}

// N dragged numbers on one row (N from 1 to 4), equal widths, each marked by its axis's colour: x red, y green, z
// blue, w none. The bounds and the step are each component's. True when one changed this frame.
drag_vector :: proc(id: string, v: ^[$N]$T, lo: Maybe(T) = nil, hi: Maybe(T) = nil, step: T = 0, o := Drag_Options{}) -> (changed: bool) where N >= 1 && N <= 4 && (intrinsics.type_is_float(T) || intrinsics.type_is_integer(T)) {
	s := gs()
	drag_size_default(s)
	AXES :: [4]Hue{.Red, .Green, .Blue, .Accent}
	axes := AXES
	if row(.Center, {}, id) {
		for i in 0 ..< N {
			if i > 0 { spacer(px(dense_gap())) }
			next({width = fill(), height = pct(1)})
			oo := o
			if i < 3 { oo.mark = hue(axes[i]) }
			if drag_of(fmt.tprintf("###%d", i), &v[i], lo, hi, step, oo) { changed = true }
		}
	}
	return
}

// (a field with no size given: the row's width, a row's height)
@(private = "file")
drag_size_default :: proc(s: ^State) {
	if !s.has_next { s.next_mod, s.has_next = {}, true }
	if s.next_mod.width == nil { s.next_mod.width = fill() }
	if s.next_mod.height == nil { s.next_mod.height = px(dense_shown() ? dense_row_height() : control_height()) }
}

// What a drag keeps while its press lasts: the value it moves (unrounded: an integer moves by fractions of a pixel's
// worth), where the pointer was, whether it moved (a press that did not move is a click).
@(private = "file")
Drag_Press :: struct {
	taken: bool,
	moved: bool,
	v:     f64,
	x:     f32,
}

@(private = "file")
Drag_Draw :: struct {
	text:        string,
	font:        font.Font_Id,
	size:        f32,
	t:           f32,    // how far a bounded value is in its range, 0..1
	t0:          f32,    // where its bar starts: the range's start, or zero when the range holds it
	bounded:     bool,
	fill, grab, mark, ink: Color,   // grab: the line at the value's place, the accent whole
}

@(private = "file")
drag_of :: proc(id: string, value: ^$T, lo, hi: Maybe(T), step: T, o: Drag_Options) -> (changed: bool) where intrinsics.type_is_integer(T) || intrinsics.type_is_float(T) {
	s := gs()
	low, has_lo := lo.?
	high, has_hi := hi.?
	bounded := has_lo && has_hi && high > low
	k := f64(step)
	if k <= 0 {
		k = 1
		when intrinsics.type_is_float(T) { k = bounded ? (f64(high) - f64(low)) / 100 : DRAG_FLOAT_SPEED }
	}
	speed := o.speed
	if speed <= 0 {
		switch {
		case step > 0: speed = f64(step)
		case bounded:  speed = (f64(high) - f64(low)) / DRAG_RANGE_PX
		case:          speed = intrinsics.type_is_float(T) ? DRAG_FLOAT_SPEED : DRAG_INT_SPEED
		}
	}
	before := value^
	push_disabled(o.disabled)
	defer pop_disabled()
	drag_size_default(s)
	if row(.Center, {}, id) {
		em := font_size()
		fkey := key_from_string(parent_box().key, "###value")
		editing := s.drag_edit_key == fkey
		// (the keyboard went elsewhere while typing: what was typed applies)
		if editing && s.focus_key != fkey {
			drag_parse(value, line_edit_string(&s.drag_edit), lo, hi, step)
			s.drag_edit_key, editing = 0, false
		}
		side := math.round(dense_row_height())
		if o.steppers { drag_stepper(value, -1, k, lo, hi, step, side, o.disabled) }
		text := drag_text(value^, step)
		info := A11y_Info{role = .Spin_Button, numeric = f64(value^), step = k, value = text}
		if has_lo { info.min = f64(low) }
		if has_hi { info.max = f64(high) }
		if v, ok := a11y_numeric_request(fkey, f32(value^), f32(k)); ok && !o.disabled { drag_set(value, f64(v), lo, hi, step) }
		next({width = fill(), height = pct(1)})
		a11y(info)
		if editing {
			next({width = fill(), height = pct(1), font = mono_font(), text_align = .Right})
			res := line_edit("###value", &s.drag_edit, {own_menu = true})
			if s.drag_edit_new { line_edit_select_all(&s.drag_edit); s.drag_edit_new = false }
			if res.committed { drag_parse(value, line_edit_string(&s.drag_edit), lo, hi, step); s.drag_edit_key = 0 }
			if res.cancelled { s.drag_edit_key = 0 }
		} else {
			push_tags("input")
			fb := build_box({.Clickable, .Focusable, .Draw_Background, .Draw_Border, .Draw_Hot_Effects, .Draw_Focus_Ring, .Sunken, .Clip}, fmt.tprintf("%s###value", text_shown(text)))
			d := frame_new(Drag_Draw)
			d^ = {text = text, font = mono_font(), size = fb.font_size, bounded = bounded, mark = o.mark, ink = fb.target_text}
			d.grab = color("accent")
			d.fill = drag_fill(d.grab, fb.target_bg, fb.target_text)
			pop_tags()
			if bounded {
				span := f64(high) - f64(low)
				d.t = f32(clamp((f64(value^) - f64(low)) / span, 0, 1))
				// (a range across zero fills from zero: a sign reads at a glance)
				if low < 0 && high > 0 { d.t0 = f32(-f64(low) / span) }
			}
			fb.custom, fb.custom_user = drag_draw, d
			fb.cursor = .Resize_H
			sig := signal(fb)
			if p := press_data(Drag_Press, fb.key); p != nil && sig.dragging && !o.disabled {
				if !p.taken { p^ = {taken = true, v = f64(value^), x = s.mouse.x} }
				if dx := s.mouse.x - p.x; dx != 0 {
					p.x = s.mouse.x
					mul := 1.0
					if .Shift in s.mods { mul = DRAG_SLOW } else if .Ctrl in s.mods { mul = DRAG_FAST }
					p.v += f64(dx / s.scale) * speed * mul
					// (held at the bounds: a drag back from past one moves at once)
					if has_lo { p.v = max(p.v, f64(low)) }
					if has_hi { p.v = min(p.v, f64(high)) }
					drag_set(value, p.v, lo, hi, step)
					p.moved = true
				}
			}
			// (a second press after a press that dragged is a new drag, not a double click)
			typed := sig.double_clicked && s.drag_moved != fkey
			if sig.pressed { s.drag_moved = 0 }
			if p := press_data(Drag_Press, fb.key); p != nil && p.moved { s.drag_moved = fkey }
			if !o.disabled && (typed || (sig.clicked && .Ctrl in sig.mods && s.drag_moved != fkey) || (sig.focused && key_press(.Return))) {
				// (typed from the value as it shows; the box keeps its key, so the keyboard stays on it)
				s.drag_edit_key, s.drag_edit_new = fkey, true
				line_edit_set(&s.drag_edit, text)
				set_focus(fkey)
				s.anim_busy = true
			}
			if sig.focused && !o.disabled && !keys_held_by_dialog(s) {
				for e, i in s.events.list {
					if s.events.consumed[i] || e.mods - {.Ctrl, .Shift, .Alt} != {} { continue }
					delta := num_step_delta(e.key, e.mods) or_continue
					s.events.consumed[i] = true
					drag_set(value, f64(value^) + delta * k, lo, hi, step)
				}
			}
			if n := wheel_take(fb); n != 0 && !o.disabled {
				drag_set(value, f64(value^) + f64(n) * k * f64(shift_steps(s.mods)), lo, hi, step)
			}
		}
		if o.steppers { drag_stepper(value, 1, k, lo, hi, step, side, o.disabled) }
		_ = em
	}
	changed = value^ != before
	// (what it moves is drawn by the next build: a program's page built before it shows the value then)
	if changed { s.anim_busy = true }
	return
}

// The bar of a bounded value's share, over the field's face: at most this much of the accent.
@(private = "file") DRAG_FILL_ALPHA :: 0.28

// The bar's colour: the accent laid on the field, faint enough that the value reads over it as over the field (WCAG AA,
// 4.5). Where the bar ends is the grab's line, in the whole accent: the bar need not be strong to be seen.
@(private = "file")
drag_fill :: proc(accent, field, ink: Color) -> Color {
	ground := field
	ground.a = 1
	a := f32(DRAG_FILL_ALPHA)
	for ; a > 0.04; a -= 0.04 {
		mix := ground + (accent - ground) * a
		mix.a = 1
		if contrast(ink, mix) >= 4.5 { break }
	}
	c := accent
	c.a *= a
	return c
}
// The axis mark's width and the grab's, logical pixels.
@(private = "file") DRAG_MARK_PX :: 2
@(private = "file") DRAG_GRAB_PX :: 2
// The share of the field's height each tick of the grab takes.
@(private = "file") DRAG_GRAB_SHARE :: 0.25

@(private = "file")
drag_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Drag_Draw)(user)
	r := b.rect
	sc := scale()
	inset := max(1, math.round(sc))
	inner := Rect{{r.min.x + inset, r.min.y + inset}, {r.max.x - inset, r.max.y - inset}}
	if d.bounded && d.t != d.t0 {
		a := math.round(math.lerp(inner.min.x, inner.max.x, min(d.t, d.t0)))
		z := math.round(math.lerp(inner.min.x, inner.max.x, max(d.t, d.t0)))
		draw.rect(dc, {{a, inner.min.y}, {z, inner.max.y}}, d.fill, rad(max(b.radius - inset, 0)))
	}
	if d.bounded {
		// (the value's place, seen at 3:1 where the faint bar is not: the theme's accent on its field. Two ticks at its
		// edges, not a line across: the digits stay whole)
		gw := max(1, math.round(DRAG_GRAB_PX * sc))
		gh := max(gw, math.round((inner.max.y - inner.min.y) * DRAG_GRAB_SHARE))
		x := clamp(math.round(math.lerp(inner.min.x, inner.max.x, d.t)) - math.round(gw * 0.5), inner.min.x, inner.max.x - gw)
		draw.rect(dc, {{x, inner.min.y}, {x + gw, inner.min.y + gh}}, d.grab)
		draw.rect(dc, {{x, inner.max.y - gh}, {x + gw, inner.max.y}}, d.grab)
	}
	if d.mark.a > 0 {
		draw.rect(dc, {inner.min, {inner.min.x + math.round(DRAG_MARK_PX * sc), inner.max.y}}, d.mark)
	}
	m := font.metrics(gs().fonts, d.font, d.size)
	w := font.text_width(gs().fonts, d.font, d.size, d.text)
	cy := (r.min.y + r.max.y) * 0.5
	x := max(r.max.x - b.text_pad - w, r.min.x + b.text_pad)
	draw.text(dc, d.font, d.size, {math.round(x), math.round(cy + (m.ascent - m.descent) * 0.5)}, d.ink, d.text)
}

// − (dir -1) or + (dir 1): a step, Shift ten; held it repeats; disabled at its bound.
@(private = "file")
drag_stepper :: proc(value: ^$T, dir: f64, k: f64, lo, hi: Maybe(T), step: T, side: f32, disabled: bool) {
	at_end := false
	if dir < 0 { if l, ok := lo.?; ok { at_end = value^ <= l } } else { if h, ok := hi.?; ok { at_end = value^ >= h } }
	next({width = px(side), height = pct(1)})
	sig: Signal
	if tab_stops(false) { sig = button(dir < 0 ? "dec" : "inc", icon = dir < 0 ? ICON_MINUS : ICON_ADD, o = {icon_font = widget_icons(), disabled = at_end || disabled, face = .Ghost}) }
	if repeat_pressed(sig) { drag_set(value, f64(value^) + dir * k * f64(shift_steps(sig.mods)), lo, hi, step) }
}

// `v` clamped to the bounds that are given and rounded to step (0: an integer's 1, a float as it is).
@(private = "file")
drag_set :: proc(value: ^$T, v: f64, lo, hi: Maybe(T), step: T) {
	v := v
	if step > 0 { v = math.round(v / f64(step)) * f64(step) }
	when !intrinsics.type_is_float(T) { v = math.round(v) }
	if l, ok := lo.?; ok { v = max(v, f64(l)) }
	if h, ok := hi.?; ok { v = min(v, f64(h)) }
	when !intrinsics.type_is_float(T) { v = clamp(v, f64(min(T)), f64(max(T))) }
	value^ = T(v)
}

// What is typed, when it is a number in either decimal mark, as the value; else the value stays.
@(private = "file")
drag_parse :: proc(value: ^$T, text: string, lo, hi: Maybe(T), step: T) {
	if v, ok := i18n.parse_decimal(text); ok { drag_set(value, v, lo, hi, step) }
}

// The text of a dragged number: an integer's digits; a float's with as many after the language's decimal mark as its
// step has (no step: DRAG_DECIMALS), so the digits of a column stay in their places.
drag_text :: proc(v: $T, step: T) -> string {
	when intrinsics.type_is_float(T) {
		decimals := DRAG_DECIMALS
		if step > 0 {
			decimals = 0
			x := f64(step)
			for decimals < 6 && abs(x - math.round(x)) > 1e-6 * max(1, abs(x)) {
				x *= 10
				decimals += 1
			}
		}
		return i18n.decimal(f64(v), decimals)
	} else {
		return fmt.tprintf("%d", v)
	}
}
