package ui

import "core:math"

// Smooth scrolling of the toolkit's scroll regions (scroll_y, list, vlist...): when a region's scroll target moves (a
// wheel notch, a key, reveal of the active row), its offset follows a curve sampled at each frame's time, as web pages
// scroll in Chromium and Edge (and in an app's document view that does the same, so both feel alike):
//   * Impulse: a strong push, then a long deceleration; Ease_Out: a cubic deceleration. Both end exactly on the target
//     with zero speed and never overshoot. Exponential: the toolkit's former easing (halves the distance every 1/60 s).
//   * A new target while moving keeps the speed it has when that is faster than the curve's own start (notches add up
//     into a glide, they do not brake it).
//   * Dragging a scroll bar's thumb moves at once. No glide when set_smooth_scroll says so (by default: when animations
//     are off).

Scroll_Curve :: enum u8 { Impulse, Ease_Out, Exponential }

// Whether scrolling glides: as the interface's animations (Follow), or always / never whatever they are. A system that
// turns animations off (Windows' "Animation effects") need not make every wheel notch a jump: an application may keep
// the glide as its own setting.
Smooth_Scroll :: enum u8 { Follow, On, Off }

Scroll_Settings :: struct {
	curve:       Scroll_Curve,
	impulse:     f32,   // Impulse: strength (higher starts faster and decelerates longer)
	duration_ms: f32,   // of one move (0: jump)
}

DEFAULT_SCROLL :: Scroll_Settings{curve = .Impulse, impulse = 5, duration_ms = 180}

set_scroll_settings :: proc(s: ^State, cfg: Scroll_Settings) { s.scroll_cfg = cfg; s.scroll_cfg_set = true }
scroll_settings :: proc(s: ^State) -> Scroll_Settings { return s.scroll_cfg_set ? s.scroll_cfg : DEFAULT_SCROLL }

// Whether scrolling glides (Follow by default: as the animations do). From the next build on.
set_smooth_scroll :: proc(s: ^State, m: Smooth_Scroll) { s.smooth_scroll = m }
smooth_scroll :: proc(s: ^State) -> Smooth_Scroll { return s.smooth_scroll }

Scroll_Anim :: struct {
	from, to:   f64,
	start, dur: f64,
	active:     bool,
}

@(private = "file") SCROLL_IMPULSE_MIN :: 1e-2   // (the curve divides by it)
// A move shorter than this is no move; a target that moved less than this keeps the animation under way.
@(private = "file") SCROLL_ARRIVED_PX :: 1e-6
@(private = "file") SCROLL_RETARGET_PX :: 0.01
// Exponential curve: the distance left halves this many times per second, and ends this close to the target.
@(private = "file") SCROLL_EXP_HALVINGS_PER_S :: 60
@(private = "file") SCROLL_EXP_SETTLED_PX :: 0.003

// Position along the curve (0..1) at `at` (0..1), and its slope.
scroll_curve_eval :: proc(curve: Scroll_Curve, k, at: f64) -> (p, dp: f64) {
	s := clamp(at, 0, 1)
	switch curve {
	case .Impulse:
		// an exponential decay of the speed, less its value at the end, so the speed reaches 0 exactly there
		kk := max(k, SCROLL_IMPULSE_MIN)
		ek := math.exp(-kk)
		den := 1 - ek * (1 + kk)
		e := math.exp(-kk * s)
		return (1 - e - kk * ek * s) / den, kk * (e - ek) / den
	case .Ease_Out:
		u := 1 - s
		return 1 - u * u * u, 3 * u * u
	case .Exponential:
	}
	return s, 1
}

// Where the animation is at `now`, its speed (px per ms), and whether it is over (then pos == to).
scroll_anim_sample :: proc(a: ^Scroll_Anim, cfg: Scroll_Settings, now: f64) -> (pos, vel: f64, done: bool) {
	if !a.active || a.dur <= 0 || now >= a.start + a.dur { return a.to, 0, true }
	t := max(now - a.start, 0) / a.dur
	p, dp := scroll_curve_eval(cfg.curve, f64(cfg.impulse), t)
	return a.from + (a.to - a.from) * p, (a.to - a.from) * dp / a.dur, false
}

// Heads for `to` from `pos`, moving at `vel` (px per ms) at `now`: a faster speed than the curve's start is kept
// (the move takes less time), never past `to`.
scroll_anim_retarget :: proc(a: ^Scroll_Anim, cfg: Scroll_Settings, pos, vel, to, now: f64) {
	a.from, a.to, a.start, a.dur, a.active = pos, to, now, f64(cfg.duration_ms), true
	dist := to - pos
	if abs(dist) < SCROLL_ARRIVED_PX || a.dur <= 0 { a.from, a.dur = to, 0; return }
	if vel * dist > 0 {
		need := abs(vel) * a.dur / abs(dist)
		_, natural := scroll_curve_eval(cfg.curve, f64(cfg.impulse), 0)
		if need > natural { a.dur = natural * abs(dist) / abs(vel) }
	}
}

// The verbs of a scroll box's view. view_off, view_target and view_anim go together: code that moves a view says which
// of these it means, and only scroll_step and these write them. Positions are in the content, 0 at its start.
// Bounds are the last layout's, so what is new this build may lie past them: the update's clamp has the last word.

// The largest scroll along an axis.
view_limit :: proc(b: ^Box, axis := Axis.Y) -> f32 {
	return max(0, b.view_bounds[int(axis)] - b.size[int(axis)])
}

// The edges of a box that scrolls along `axis` fade over `width` where they hide content (by the last layout's offset and
// bounds): a subtle sign that it scrolls that way, where a bar alone says little. The box must clip (.Clip): edge_fade.
scroll_fades :: proc(b: ^Box, axis: Axis, width: f32) {
	i := int(axis)
	off, limit := b.view_off[i], view_limit(b, axis)
	before := off > 0.5 ? width : 0
	after := off < limit - 0.5 ? width : 0
	b.edge_fade = axis == .X ? {before, 0, after, 0} : {0, before, 0, after}
}

// The offset closest to `offset` that shows `top` .. `bottom` in `view`; what is longer than the view keeps its top.
// `margin`: how much room is left around it when the offset has to move (what already shows stays as it is).
view_reveal_offset :: proc(offset, top, bottom, view: f32, margin: f32 = 0) -> f32 {
	o := offset
	if top < o { o = top - margin }
	if bottom > o + view { o = min(bottom + margin - view, top - margin) }
	return o
}

// Heads for `top` .. `bottom` (a glide, as the wheel's); true when the target moved. A view that shows its bar only for
// a while decides for itself whether this is a reason to: see scrollbar_reveal.
view_reveal :: proc(b: ^Box, top, bottom: f32, axis := Axis.Y, margin: f32 = 0) -> (moved: bool) {
	ai := int(axis)
	y := view_reveal_offset(b.view_target[ai], top, bottom, b.size[ai], margin)
	moved = y != b.view_target[ai]
	b.view_target[ai] = y
	return
}

// view_reveal of `b`, a box inside the scroll box `p`, as its rect stands in the last layout.
@(private)
view_reveal_box :: proc(p, b: ^Box, axis := Axis.Y, margin: f32 = 0) {
	ai := int(axis)
	top := b.rect.min[ai] - p.rect.min[ai] + p.view_off[ai]
	view_reveal(p, top, top + b.rect.max[ai] - b.rect.min[ai], axis, margin)
}

// Goes to `at` with no glide. Not clamped: content filtered anew has no bounds yet, the update clamps it.
// (Ending a glide is cutting `active`: scroll_step reads the rest of a Scroll_Anim only while it is set, and with it
// off a view that sits on its target has nothing to follow, wherever the old glide was heading.)
view_jump :: proc(b: ^Box, at: f32, axis := Axis.Y) {
	ai := int(axis)
	b.view_off[ai], b.view_target[ai] = at, at
	b.view_top_held[ai] = false
	b.view_anim[ai].active = false
}

// Heads for the content's start as such (Home): content that comes above the view on the way does not stop it short
// (view_shift). A move that stops at the start (the wheel, Page Up) is a place like any other.
view_top :: proc(b: ^Box, axis := Axis.Y) {
	b.view_target[int(axis)] = 0
	b.view_top_held[int(axis)] = true
}

// The content moved by `by` under the view: the view follows, what it showed stays on screen, and a glide under way
// goes on from where it was instead of starting over. `limit`: the largest scroll of the content as it now is, which
// view_limit does not know before the layout. The target follows too, even at the start where a move stopped (a wheel
// turned up past the top while a page is read before it: it would glide over all of that page); a view sent to the
// start as such (view_top) still ends there (the glide, shifted with the rest, turns to it at its speed).
view_shift :: proc(b: ^Box, by, limit: f32, axis := Axis.Y) {
	ai := int(axis)
	b.view_off[ai] = clamp(b.view_off[ai] + by, 0, limit)
	if b.view_target[ai] > 0 || !b.view_top_held[ai] { b.view_target[ai] = clamp(b.view_target[ai] + by, 0, limit) }
	if a := &b.view_anim[ai]; a.active { a.from += f64(by); a.to += f64(by) }
}

// One axis of a scroll box toward its (clamped) target, at the end of a build (update_animations).
@(private)
scroll_step :: proc(s: ^State, b: ^Box, ai: int) {
	cfg := scroll_settings(s)
	target := b.view_target[ai]
	a := &b.view_anim[ai]
	if !s.scroll_smooth || cfg.curve == .Exponential || cfg.duration_ms <= 0 {
		a.active = false
		cur := b.view_off[ai]
		d := target - cur
		if abs(d) < SCROLL_EXP_SETTLED_PX || !s.scroll_smooth || cfg.duration_ms <= 0 { b.view_off[ai] = target; return }
		b.view_off[ai] = cur + d * f32(1 - math.pow(2, -SCROLL_EXP_HALVINGS_PER_S * f64(s.dt)))
		s.anim_busy = true
		return
	}
	now := s.frame_ms
	if abs(f64(target) - a.to) > SCROLL_RETARGET_PX || (!a.active && b.view_off[ai] != target) {
		vel: f64
		if a.active { _, vel, _ = scroll_anim_sample(a, cfg, now) }
		scroll_anim_retarget(a, cfg, f64(b.view_off[ai]), vel, f64(target), now)
	}
	// sampled where the next frame will be: the frame being built is the one the move shows first
	pos, _, done := scroll_anim_sample(a, cfg, now + f64(s.dt) * 1000)
	if done {
		a.active = false
		b.view_off[ai] = target
	} else {
		b.view_off[ai] = f32(pos)
		s.anim_busy = true
	}
}
