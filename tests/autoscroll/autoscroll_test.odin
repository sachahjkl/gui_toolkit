// Middle-click autoscroll, the pure parts (no window): the acceleration curve (dead zone, monotone, capped, symmetric),
// the engage/latch/end state machine (hold and toggle modes), the direction cursor, and that integrating the velocity
// against dt gives the same travel at 60 Hz and at 180 Hz (frame-rate independence).
//   odin test tests/autoscroll -vet
package autoscroll_test

import "core:math"
import "core:testing"
import "../../ui"

CFG :: ui.DEFAULT_AUTOSCROLL

////////////////////////////////
// The curve

@(test)
dead_zone :: proc(t: ^testing.T) {
	// no speed within the dead zone, on either side
	for off in ([]f32{0, 3, -6, 11.9, -11.9}) {
		testing.expectf(t, ui.autoscroll_axis_speed(off, CFG) == 0, "dead zone at %v moved", off)
	}
	// just past it, a small but non-zero speed
	testing.expect(t, ui.autoscroll_axis_speed(CFG.dead_zone + 1, CFG) > 0)
}

@(test)
monotone_and_capped :: proc(t: ^testing.T) {
	prev: f32 = -1
	for i in 0 ..= 100 {
		off := f32(i) * 8
		v := ui.autoscroll_axis_speed(off, CFG)
		testing.expectf(t, v >= prev - 1e-3, "not monotone at %v: %v after %v", off, v, prev)
		testing.expectf(t, v <= CFG.max_speed + 1e-3, "over the cap at %v: %v", off, v)
		prev = v
	}
	// far out it is pinned at the cap
	testing.expect(t, abs(ui.autoscroll_axis_speed(10000, CFG) - CFG.max_speed) < 1e-3)
}

@(test)
symmetric :: proc(t: ^testing.T) {
	for off in ([]f32{15, 40, 120, 500}) {
		a := ui.autoscroll_axis_speed(off, CFG)
		b := ui.autoscroll_axis_speed(-off, CFG)
		testing.expectf(t, abs(a + b) < 1e-3, "not symmetric at %v: %v vs %v", off, a, b)
		testing.expect(t, a > 0 && b < 0)
	}
}

@(test)
exponent_shapes :: proc(t: ^testing.T) {
	// at the midpoint of the ramp, exponent 2 is below linear (eases in), a low exponent is above it
	mid := CFG.dead_zone + CFG.full_dist * 0.5
	lin := CFG;   lin.exponent = 1
	soft := CFG;  soft.exponent = 2
	hard := CFG;  hard.exponent = 0.5
	vl := ui.autoscroll_axis_speed(mid, lin)
	vs := ui.autoscroll_axis_speed(mid, soft)
	vh := ui.autoscroll_axis_speed(mid, hard)
	testing.expect(t, vs < vl)
	testing.expect(t, vh > vl)
}

////////////////////////////////
// Velocity vector and axes

@(test)
axes_restrict :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	ui.autoscroll_point(&a, {400, 400})   // moved right and down
	v := ui.autoscroll_velocity(&a, CFG)
	testing.expect(t, v.x == 0 && v.y > 0)

	a = {}
	ui.autoscroll_begin(&a, {100, 100}, .X, held = true, now_ms = 0)
	ui.autoscroll_point(&a, {400, 400})
	v = ui.autoscroll_velocity(&a, CFG)
	testing.expect(t, v.y == 0 && v.x > 0)

	a = {}
	ui.autoscroll_begin(&a, {100, 100}, .Both, held = true, now_ms = 0)
	ui.autoscroll_point(&a, {400, 400})
	v = ui.autoscroll_velocity(&a, CFG)
	testing.expect(t, v.x > 0 && v.y > 0)
}

////////////////////////////////
// State machine

@(test)
hold_mode_ends_on_release :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	// move far enough to count as a drag, then release after a while: hold mode, ends on release
	ui.autoscroll_point(&a, {100, 300})
	still := ui.autoscroll_release(&a, CFG, now_ms = 500)
	testing.expect(t, !still)
	testing.expect(t, !ui.autoscroll_active(&a))
}

@(test)
toggle_latches_on_tap :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	// quick release, no movement: a tap latches the mode on
	still := ui.autoscroll_release(&a, CFG, now_ms = 100)
	testing.expect(t, still)
	testing.expect(t, ui.autoscroll_active(&a))
	// it scrolls as the pointer moves with no button held
	ui.autoscroll_point(&a, {100, 300})
	testing.expect(t, ui.autoscroll_velocity(&a, CFG).y > 0)
	// the next click ends it, and is reported as consumed
	ended := ui.autoscroll_click(&a)
	testing.expect(t, ended)
	testing.expect(t, !ui.autoscroll_active(&a))
}

@(test)
slow_release_does_not_latch :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	// held past tap_ms without moving: not a tap, so hold mode ends on release
	still := ui.autoscroll_release(&a, CFG, now_ms = f64(CFG.tap_ms) + 50)
	testing.expect(t, !still)
}

@(test)
moved_press_does_not_latch :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	ui.autoscroll_point(&a, {100, 100 + CFG.tap_slop + 5})   // moved past the slop: a drag, not a tap
	still := ui.autoscroll_release(&a, CFG, now_ms = 100)
	testing.expect(t, !still)
}

@(test)
cancel_clears :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Both, held = true, now_ms = 0)
	ui.autoscroll_cancel(&a)
	testing.expect(t, !ui.autoscroll_active(&a))
	// a click on a dead session is not consumed
	testing.expect(t, !ui.autoscroll_click(&a))
}

////////////////////////////////
// Direction cursor

@(test)
direction_cursor :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Both, held = true, now_ms = 0)
	// in the dead zone: the all-directions cursor
	testing.expect(t, ui.autoscroll_cursor(&a, CFG) == .All_Scroll)
	ui.autoscroll_point(&a, {100, 400})   // straight down
	testing.expect(t, ui.autoscroll_cursor(&a, CFG) == .Resize_S)
	ui.autoscroll_point(&a, {400, 100})   // straight right
	testing.expect(t, ui.autoscroll_cursor(&a, CFG) == .Resize_E)
	ui.autoscroll_point(&a, {400, 400})   // down-right
	testing.expect(t, ui.autoscroll_cursor(&a, CFG) == .Resize_SE)

	// a Y-only area always reports a vertical cursor, even for a diagonal pointer
	b: ui.Autoscroll
	ui.autoscroll_begin(&b, {100, 100}, .Y, held = true, now_ms = 0)
	ui.autoscroll_point(&b, {400, 400})
	testing.expect(t, ui.autoscroll_cursor(&b, CFG) == .Resize_S)
}

////////////////////////////////
// Frame-rate independence

// Integrating the velocity against dt gives the same travel whatever the frame rate, because the velocity is a speed
// (units per second) that does not depend on dt. Simulate 250 ms of a steady pointer at 60 Hz and at 180 Hz.
@(test)
rate_independent :: proc(t: ^testing.T) {
	a: ui.Autoscroll
	ui.autoscroll_begin(&a, {100, 100}, .Y, held = true, now_ms = 0)
	ui.autoscroll_point(&a, {100, 350})   // a fixed offset

	travel :: proc(a: ^ui.Autoscroll, hz: f64) -> f64 {
		dt := 1.0 / hz
		total := 0.0
		elapsed := 0.0
		for elapsed < 0.25 - 1e-9 {
			v := ui.autoscroll_velocity(a, CFG)
			total += f64(v.y) * dt
			elapsed += dt
		}
		return total
	}
	at60 := travel(&a, 60)
	at180 := travel(&a, 180)
	// the same within a frame's worth of travel (the loops end on different frame boundaries)
	v := ui.autoscroll_velocity(&a, CFG)
	tol := f64(v.y) / 60
	testing.expectf(t, abs(at60 - at180) <= tol, "travel differs: 60Hz=%v 180Hz=%v tol=%v", at60, at180, tol)
	testing.expect(t, math.abs(at60) > 1)
}
