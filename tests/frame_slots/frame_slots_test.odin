// The cap on the cadence of frames (platform/frame_slots.odin): the logic alone, with a clock that is a number and a
// screen that is a function. Nothing here measures a duration of the machine.
//   odin test tests/frame_slots -use-separate-modules -vet
package frame_slots_test

import "core:testing"
import "../../platform"

MS :: 1_000_000

// A loop of frames woken by input every `input_ms` (a mouse at 1 kHz), on a screen whose latency object is released at
// once (a variable refresh display: nothing else paces the app). Each frame costs `cost_ns`. Returns the frames started in
// `span_ms`. `cap_on` false: the app has no cap (the loop the browser had).
simulate :: proc(s: ^platform.Frame_Slots, span_ms: int, input_ms: f64, cost_ns: i64, cap_on: bool) -> (frames: int) {
	now := i64(1_000) * MS   // (any origin but 0: 0 means "no slot yet")
	end := now + i64(span_ms) * MS
	first := true
	for now < end {
		// a frame is made as soon as there is input and the screen takes one
		wait: i64
		if cap_on { wait, _ = platform.frame_slot_wait(s, now, first, false) }
		first = false
		now += wait
		if now >= end { break }
		frames += 1
		now += cost_ns
		// the next input arrives on the thousandth of a second grid
		step := i64(input_ms * f64(MS))
		now = (now / step + 1) * step
	}
	return
}

@(test)
frames_under_input_at_1khz_stay_within_the_cadence_on_a_screen_that_paces_nothing :: proc(t: ^testing.T) {
	s := platform.Frame_Slots{period_ns = 5_555_555, strict = true}   // 180 Hz
	n := simulate(&s, 1000, 1, 1_300_000, true)
	testing.expect(t, n <= 181, "at most one frame per period (and the first)")
	testing.expect(t, n >= 170, "and not much fewer: the cap delays, it does not starve")
}

@(test)
the_same_loop_without_the_cap_makes_a_frame_per_input :: proc(t: ^testing.T) {
	// what the browser did: the harness sees it (a bound of 181 would have failed)
	s := platform.Frame_Slots{period_ns = 5_555_555, strict = true}
	n := simulate(&s, 1000, 1, 1_300_000, false)
	testing.expect(t, n > 400, "no cap: hundreds of frames a second")
}

@(test)
a_loose_grid_never_delays_a_screen_that_paces_the_app :: proc(t: ^testing.T) {
	// a 60 Hz screen: frames start one period apart (the latency object releases them at the refresh)
	s := platform.Frame_Slots{period_ns = 16_666_667}
	now := i64(5_000) * MS
	for i in 0 ..< 600 {
		wait, _ := platform.frame_slot_wait(&s, now, i == 0, false)
		testing.expect_value(t, wait, 0)
		now += 16_666_667 + i64(i % 3) * 20_000 - 20_000   // the refresh's own jitter
	}
	testing.expect(t, !s.escalated)
}

@(test)
a_loose_grid_becomes_strict_when_nothing_else_paces_the_app :: proc(t: ^testing.T) {
	s := platform.Frame_Slots{period_ns = 5_555_555}   // loose: the safety net, 0.9 of a period
	n := simulate(&s, 1000, 1, 1_300_000, true)
	testing.expect(t, s.escalated, "eight delayed frames in a row: the cap is the period")
	testing.expect(t, n <= 200, "a few frames at the loose grid, then the period")
	// a rest forgets it
	platform.frame_slot_wait(&s, 9_000 * MS, true, false)
	testing.expect(t, !s.escalated)
}

@(test)
a_frame_that_starts_an_answer_is_not_delayed_and_the_next_one_is_a_period_after :: proc(t: ^testing.T) {
	s := platform.Frame_Slots{period_ns = 5_555_555, strict = true}
	now := i64(2_000) * MS
	platform.frame_slot_wait(&s, now, true, false)   // the run's first frame
	wait, _ := platform.frame_slot_wait(&s, now + 1 * MS, false, true)   // a click, 1 ms later
	testing.expect_value(t, wait, 0)
	wait, _ = platform.frame_slot_wait(&s, now + 2 * MS, false, false)
	testing.expect(t, wait > 4 * MS && wait <= 5_555_555, "the frame after it waits for its slot")
}

@(test)
a_late_frame_is_not_made_up_for_with_a_burst :: proc(t: ^testing.T) {
	s := platform.Frame_Slots{period_ns = 5_555_555, strict = true}
	now := i64(2_000) * MS
	platform.frame_slot_wait(&s, now, true, false)
	now += 100 * MS   // a frame that took 100 ms
	wait, _ := platform.frame_slot_wait(&s, now, false, false)
	testing.expect_value(t, wait, 0)
	wait, _ = platform.frame_slot_wait(&s, now + 500_000, false, false)   // half a millisecond later
	testing.expect(t, wait > 4 * MS, "one slot after, not the ones it missed")
}

@(test)
no_period_no_cap :: proc(t: ^testing.T) {
	s: platform.Frame_Slots
	wait, _ := platform.frame_slot_wait(&s, 1_000 * MS, false, false)
	testing.expect_value(t, wait, 0)
}

@(test)
a_display_is_variable_when_its_modes_go_higher_than_its_rate :: proc(t: ^testing.T) {
	testing.expect(t, platform.refresh_is_variable(60.001, 180), "dynamic refresh rate: rests at 60, goes to 180")
	testing.expect(t, !platform.refresh_is_variable(179.98, 180), "running at its top")
	testing.expect(t, !platform.refresh_is_variable(59.94, 60), "59.94 is a 60 Hz mode")
	testing.expect(t, !platform.refresh_is_variable(0, 180), "no rate: nothing to compare")
}
