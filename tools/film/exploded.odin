package film_tool

import "core:math"
import "../../examples/showcase"
import "gt:film"
import "gt:ui"

// The exploded view over five scenes. Each act: the flat page, the way out into its planes, two beats where the planes
// squeeze, the mode turns at the bottom and they burst out past their place, the way back. The camera goes round the
// centre the whole film; the last act makes a whole turn.

@(private = "file")
Act :: struct {
	scene:  showcase.Scene,
	length: f64,                   // seconds
	modes:  [3]ui.Exploded_Mode,   // at its start, then after each beat
	beats:  [2]f64,                // seconds into the act
	spin:   bool,
}

@(private = "file", rodata)
ACTS := [?]Act{
	{.Views,    7.5, {.Layers, .Depths, .Outlines}, {3.2, 4.8}, false},
	{.Palette,  6.5, {.Depths, .Outlines, .Layers}, {2.8, 4.2}, false},
	{.Graph,    6.5, {.Outlines, .Layers, .Depths}, {2.8, 4.2}, false},
	{.Values,   6.5, {.Layers, .Outlines, .Depths}, {2.8, 4.2}, false},
	{.Settings, 9.5, {.Depths, .Layers, .Outlines}, {6.2, 7.4}, true},
}

@(private = "file") EXPLODE_AT :: 0.35
@(private = "file") EXPLODE_FOR :: 1.5
@(private = "file") COLLAPSE_FOR :: 1.1
@(private = "file") SQUEEZE :: 0.2
@(private = "file") RELEASE :: 0.7

@(private = "file")
Pose :: struct {
	scene: showcase.Scene,
	t:     f64,
	mode:  ui.Exploded_Mode,
	yaw, pitch, spread, fit: f64,
}

@(private = "file")
Exploded :: struct {
	take:  ^Take,
	start: int,   // the film's frame where the acts begin
}

exploded_film :: proc(t: ^Take) {
	open_with(t, "Exploded view", "Every box of a window, in depth")
	e := Exploded{take = t, start = t.rec.frames}
	t.rec.each, t.rec.each_user = exploded_each, &e
	total: f64
	for a in ACTS { total += a.length }
	film.hold(&t.rec, total)
	t.rec.each, t.rec.each_user = nil, nil
	t.app.main.state.exploded.on = false
	t.app.main.state.exploded.t = 0
	close_with(t)
}

@(private = "file")
exploded_each :: proc(r: ^film.Recorder, user: rawptr) {
	e := (^Exploded)(user)
	app := e.take.app
	p := pose_at(f64(r.frames - e.start) / f64(r.o.fps))
	app.scene = p.scene
	v := &app.main.state.exploded
	// (exploded_step adds a frame's step after this: t is set that much short, so the frame draws the pose's)
	step := f32(1000.0 / f64(r.o.fps) / 600)
	tt := f32(p.t)
	v.on = tt > 0
	v.t = tt > 0 && tt < 1 ? max(tt - step, 0) : tt
	v.mode = p.mode
	v.yaw, v.pitch, v.spread, v.fit = f32(p.yaw), f32(p.pitch), f32(p.spread), f32(p.fit)
	app.main.state.anim_busy = true
}

// A beat's spread: the planes squeeze in, the mode turns at the bottom, they burst out past their place and settle.
@(private = "file")
beat_spread :: proc(u, at: f64) -> f64 {
	d := u - at
	if d < -SQUEEZE || d > RELEASE { return 1 }
	if d < 0 { return 1 - 0.85 * f64(film.ease_in_out(f32(1 + d / SQUEEZE))) }
	return 0.15 + 0.85 * f64(film.ease_out_back(f32(d / RELEASE), 2.2))
}

@(private = "file")
beat_kick :: proc(u, at: f64) -> f64 {
	d := u - at
	if d < 0 || d > 1.2 { return 0 }
	return math.sin(d / 1.2 * math.PI) * math.exp(-d * 2.2)
}

@(private = "file")
pose_at :: proc(T: f64) -> Pose {
	start: f64
	last := len(ACTS) - 1
	for act, i in ACTS {
		if T < start + act.length || i == last {
			u := T - start
			p := Pose{scene = act.scene}
			end := act.length - COLLAPSE_FOR - 0.15
			p.t = u < end ? clamp((u - EXPLODE_AT) / EXPLODE_FOR, 0, 1) : 1 - clamp((u - end) / COLLAPSE_FOR, 0, 1)
			p.mode = act.modes[0]
			for b, k in act.beats { if u >= b { p.mode = act.modes[k + 1] } }
			// (round the centre all along the film, leaning in and out on a slower wave)
			p.yaw = 38 * math.sin(T * 2 * math.PI / 11) - 8
			p.pitch = 24 + 9 * math.sin(T * 2 * math.PI / 6.5 + 1)
			for b in act.beats { p.yaw += 22 * beat_kick(u, b) }
			if act.spin { p.yaw += 360 * f64(film.ease_in_out(f32((u - 1.9) / 4.0))) }
			grow := f64(film.smooth(f32((u - EXPLODE_AT) / (act.length * 0.8))))
			p.spread = 34 + 46 * grow
			for b in act.beats { p.spread *= beat_spread(u, b) }
			p.fit = 0.60 + 0.12 * grow
			for b in act.beats { p.fit += 0.05 * beat_kick(u, b) }
			return p
		}
		start += act.length
	}
	return {}
}
