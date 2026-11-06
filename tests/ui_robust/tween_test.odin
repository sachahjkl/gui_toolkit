package ui_robust_test

// ui.tween: a set time, gentle at both ends, the first step not the largest, and no frames asked for once it is there.

import "core:testing"
import "../../ui"

@(private = "file") TWEEN_MS :: 200
@(private = "file") TWEEN_DT :: 0.02
@(private = "file") TWEEN_FRAMES :: 10   // TWEEN_MS of TWEEN_DT

@(private = "file")
step :: proc(f: ^Fx, target: f32, ms: f32 = TWEEN_MS, dt: f32 = TWEEN_DT, animations := true) -> f32 {
	ui.begin_build(&f.s, {window_size = {800, 600}, dt = dt, animations = animations, dpi_scale = 1, base = ui.Style{font = f.base_font, font_size = 15}})
	v := ui.tween(ui.key_from_string(0, "###tween"), target, ms)
	ui.end_build()
	return v
}

@(test)
a_tween_is_gentle_at_both_ends_and_ends_on_time :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	testing.expect_value(t, step(&f, 0), 0)
	// the frame that starts it, however long the rest before it was, moves nothing
	testing.expect_value(t, step(&f, 1, dt = 5), 0)
	prev, first, largest: f32
	for i in 1 ..= TWEEN_FRAMES {
		v := step(&f, 1)
		d := v - prev
		testing.expectf(t, d >= 0, "it goes one way: %v after %v", v, prev)
		if i == 1 { first = d }
		largest = max(largest, d)
		prev = v
	}
	testing.expect_value(t, prev, 1)
	testing.expectf(t, first < largest / 3, "it leaves gently: %v, at its fastest %v", first, largest)
	testing.expect_value(t, step(&f, 1), 1)
	testing.expect(t, !f.s.anim_busy, "there: no more frames")
}

@(test)
a_tween_turned_back_sets_off_from_where_it_is :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	step(&f, 0)
	step(&f, 1)
	for _ in 1 ..= TWEEN_FRAMES / 2 { step(&f, 1) }
	half := step(&f, 0)
	testing.expectf(t, half > 0 && half < 1, "it stays where it was: %v", half)
	testing.expect(t, step(&f, 0) <= half, "and comes back")
}

@(test)
a_tween_without_animations_is_at_its_end :: proc(t: ^testing.T) {
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	step(&f, 0)
	testing.expect_value(t, step(&f, 1, animations = false), 1)
	testing.expect_value(t, step(&f, 0, ms = 0), 0)
}
