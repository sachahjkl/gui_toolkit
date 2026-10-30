package ui

import "core:math"

// Smooth scrolling of the toolkit's scroll regions (scroll_y, list, vlist...): when a region's scroll target moves (a
// wheel notch, a key, reveal of the active row), its offset follows a curve sampled at each frame's time, as web pages
// scroll in Chromium and Edge (and in an app's document view that does the same, so both feel alike):
//   * Impulse: a strong push, then a long deceleration; Ease_Out: a cubic deceleration. Both end exactly on the target
//     with zero speed and never overshoot. Exponential: the toolkit's former easing (halves the distance every 1/60 s).
//   * A new target while moving keeps the speed it has when that is faster than the curve's own start (notches add up
//     into a glide, they do not brake it).
//   * Dragging a scroll bar's thumb moves at once. No glide when Build_Params.smooth_scroll says so (by default: when
//     animations are off).

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

Scroll_Anim :: struct {
	from, to:   f64,
	start, dur: f64,
	active:     bool,
}

// Position along the curve (0..1) at `at` (0..1), and its slope.
scroll_curve_eval :: proc(curve: Scroll_Curve, k, at: f64) -> (p, dp: f64) {
	s := clamp(at, 0, 1)
	switch curve {
	case .Impulse:
		// an exponential decay of the speed, less its value at the end, so the speed reaches 0 exactly there
		kk := max(k, 1e-2)
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
	if abs(dist) < 1e-6 || a.dur <= 0 { a.from, a.dur = to, 0; return }
	if vel * dist > 0 {
		need := abs(vel) * a.dur / abs(dist)
		_, natural := scroll_curve_eval(cfg.curve, f64(cfg.impulse), 0)
		if need > natural { a.dur = natural * abs(dist) / abs(vel) }
	}
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
		if abs(d) < 0.003 || !s.scroll_smooth || cfg.duration_ms <= 0 { b.view_off[ai] = target; return }
		b.view_off[ai] = cur + d * f32(1 - math.pow(2, -60 * f64(s.dt)))
		s.anim_busy = true
		return
	}
	now := s.frame_ms
	if abs(f64(target) - a.to) > 0.01 || (!a.active && b.view_off[ai] != target) {
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
