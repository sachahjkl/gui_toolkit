// The cadence model (platform/pacing.odin): its states and transitions, and simulated runs of frames on screens that pace the
// application (fixed refresh), that do not (variable refresh, tearing), under input at 1 kHz, a resize, a panel dragged and
// a program that resizes the window from outside (AltSnap). The clock is a number and the screen a function: nothing here
// measures a duration of the machine.
//   odin test tests/pacing -collection:gt=src -vet
package pacing_test

import "core:testing"
import "core:time"
import "gt:platform"

MS :: 1_000_000

////////////////////////////////
// States and transitions

@(private = "file")
presented_cadence :: proc(hz: f64 = 180, strict := true) -> platform.Cadence {
	c: platform.Cadence
	c.slots = {period_ns = i64(1e9 / hz), strict = strict}
	return c
}

// A rate asked above the screen's: made, on its slots, without waiting for the screen. Below it, and with none asked, nothing changes.
@(test)
a_target_above_the_screen_is_made :: proc(t: ^testing.T) {
	p := platform.cadence_plan({hz = 60, max_hz = 60}, {target_hz = 120})
	testing.expect(t, p.above && p.hz == 120 && p.slots.strict, "120 on a 60 Hz screen")
	testing.expect(t, !platform.cadence_plan({hz = 60, max_hz = 60}, {}).above, "the screen's rate")
	testing.expect(t, !platform.cadence_plan({hz = 60, max_hz = 60}, {target_hz = 30}).above, "below it")
	testing.expect(t, !platform.cadence_plan({hz = 60, max_hz = 60}, {target_hz = 60.2}).above, "a rounding of it")
	testing.expect(t, !platform.cadence_plan({hz = 60.001, max_hz = 180}, {}).above, "a variable screen left alone")
	c: platform.Cadence
	platform.cadence_adopt(&c, p)
	now := i64(10_000) * MS
	frames := 0
	for now < (10_000 + 1000) * MS {   // a second of frames that take 1 ms, input always there
		d := platform.frame_decision(&c, {now_ns = now, presented = true})
		testing.expect(t, !d.wait_swap_chain && d.present_at_once && d.latency == 2, "it does not wait for the screen")
		testing.expect(t, platform.cadence_at_once(&c), "a frame of the interface alone too")
		now += d.wait_ns + MS
		platform.cadence_presented(&c, now)
		frames += 1
	}
	testing.expectf(t, frames >= 118 && frames <= 122, "120 frames in a second: %d", frames)
}

// Uncapped: whatever the state, no wait and shown at once, and the choice survives a new plan.
@(test)
uncapped_lifts_every_wait :: proc(t: ^testing.T) {
	now := i64(10_000) * MS
	c := presented_cadence()
	c.uncapped = true
	platform.cadence_presented(&c, now)
	for i in 0 ..< 10 {
		d := platform.frame_decision(&c, {now_ns = now, presented = true, dragging = i % 2 == 0})
		testing.expect(t, d.wait_ns == 0 && d.wait_until_ns == now && !d.wait_swap_chain && d.present_at_once && d.latency == 2, "no wait, shown at once")
		testing.expect(t, platform.cadence_at_once(&c), "a frame of the interface alone too")
		now += MS / 10   // (ten frames in a millisecond: nothing holds them)
	}
	platform.cadence_adopt(&c, platform.Cadence_Plan{slots = {period_ns = 16 * MS}})
	testing.expect(t, c.uncapped, "a new screen keeps the choice")
	c.uncapped = false
	d := platform.frame_decision(&c, {now_ns = now, presented = true})
	testing.expect(t, !d.present_at_once && d.wait_swap_chain, "capped again")
}

@(test)
each_state_and_what_it_decides :: proc(t: ^testing.T) {
	now := i64(10_000) * MS
	// a click after a rest: answered at once
	{
		c := presented_cadence()
		c.present_ns = now - 100 * MS
		d := platform.frame_decision(&c, {now_ns = now, idled = true, input = true, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Input_Answer)
		testing.expect(t, d.present_at_once && d.latency == 2 && d.wait_ns == 0 && !d.wait_swap_chain, "at once, two queued, no wait")
	}
	// a timer's frame after a rest: a new run, waits for the swap chain
	{
		c := presented_cadence()
		d := platform.frame_decision(&c, {now_ns = now, idled = true, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Rest)
		testing.expect(t, !d.present_at_once && d.latency == 1 && d.wait_ns == 0 && d.wait_swap_chain, "paced, starts its run now")
	}
	// the frames that follow: one per slot
	{
		c := presented_cadence()
		platform.frame_decision(&c, {now_ns = now, idled = true, presented = true})
		platform.cadence_presented(&c, now + 1 * MS)
		d := platform.frame_decision(&c, {now_ns = now + 2 * MS, input = true, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Continuous)
		testing.expect(t, d.wait_ns > 3 * MS && d.wait_until_ns == now + d.wait_ns + 2 * MS && d.wait_swap_chain && !d.present_at_once, "waits for its slot and the screen")
		d = platform.frame_decision(&c, {now_ns = now + 8 * MS, input = true, presented = true, dragging = true, slot_held = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Drag)
		testing.expect(t, !d.present_at_once && !d.wait_swap_chain && d.latency == 1, "a drag is paced; a slot already held is not waited for again")
	}
	// a drag on a variable refresh screen: paced by its slot, then shown at once (the screen follows the frames)
	{
		c := presented_cadence()
		c.variable = true
		platform.frame_decision(&c, {now_ns = now, idled = true, presented = true})
		platform.cadence_presented(&c, now + 1 * MS)
		d := platform.frame_decision(&c, {now_ns = now + 2 * MS, input = true, presented = true, dragging = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Drag)
		testing.expect(t, d.present_at_once && d.latency == 2 && d.wait_ns > 3 * MS && d.wait_swap_chain, "its slot and the screen, then shown at once")
		testing.expect(t, platform.cadence_at_once(&c), "the frame's own")
		testing.expect(t, platform.cadence_inner_frame(&c, false, true, 0), "a frame of the chrome inside it: at once too")
		// the same screen, nothing dragged: as before, the refresh
		d = platform.frame_decision(&c, {now_ns = now + 8 * MS, input = true, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Continuous)
		testing.expect(t, !d.present_at_once && d.latency == 1, "an animation or the wheel: at the refresh")
		// and at rest: nothing changes
		d = platform.frame_decision(&c, {now_ns = now + 900 * MS, idled = true, presented = true, dragging = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Rest)
		testing.expect(t, !d.present_at_once && d.latency == 1, "a frame after a rest: at the refresh")
	}
	// a new size: the step, then its burst, then the run goes on
	{
		c := presented_cadence()
		platform.frame_decision(&c, {now_ns = now, idled = true, presented = true})
		d := platform.frame_decision(&c, {now_ns = now + 1 * MS, input = true, presented = true, resized = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Resize_Step)
		testing.expect(t, d.present_at_once && d.wait_ns == 0 && !d.wait_swap_chain && d.latency == 2, "a step: at once, no wait at all")
		platform.cadence_presented(&c, now + 2 * MS)
		d = platform.frame_decision(&c, {now_ns = now + 3 * MS, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Resize_Burst)
		testing.expect(t, d.present_at_once && d.latency == 2 && d.wait_swap_chain && d.wait_ns > 0, "the burst: its slot and the screen, then shown at once")
		d = platform.frame_decision(&c, {now_ns = now + 1 * MS + platform.CADENCE_RESIZE_HOLD_NS, presented = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Continuous)
	}
	// before the first present: nothing at once, nothing waited for
	{
		c := presented_cadence()
		d := platform.frame_decision(&c, {now_ns = now, idled = true, input = true, resized = true})
		testing.expect_value(t, d.state, platform.Cadence_State.Rest)
		testing.expect(t, !d.present_at_once && !d.wait_swap_chain && d.latency == 1, "a swap chain never shown releases nothing")
		testing.expect_value(t, c.resize_ns, now)   // (the size is remembered all the same)
	}
}

@(test)
the_first_state_that_applies_wins :: proc(t: ^testing.T) {
	now := i64(10_000) * MS
	Case :: struct { idled, input, resized, dragging, burst: bool, want: platform.Cadence_State }
	cases := [?]Case{
		{true, true, true, true, true, .Resize_Step},
		{false, true, true, false, false, .Resize_Step},
		{true, true, false, true, true, .Input_Answer},
		{false, false, false, true, true, .Resize_Burst},
		{true, false, false, true, false, .Rest},
		{false, false, false, true, false, .Drag},
		{false, true, false, false, false, .Continuous},   // input a frame after a present: a run goes on
		{false, false, false, false, false, .Continuous},
	}
	for k in cases {
		c := presented_cadence()
		c.present_ns = now - 1 * MS
		if k.burst { c.resize_ns = now - 10 * MS }
		d := platform.frame_decision(&c, {now_ns = now, idled = k.idled, input = k.input, resized = k.resized, dragging = k.dragging, presented = true})
		testing.expectf(t, d.state == k.want, "%v: %v", k, d.state)
		testing.expect_value(t, c.state, k.want)
		testing.expect_value(t, c.counts[k.want], 1)
	}
}

@(test)
input_after_a_pause_of_the_hand_starts_an_answer :: proc(t: ^testing.T) {
	period := i64(5_555_555)
	testing.expect(t, platform.cadence_input_starts_answer(true, 1 * MS, period), "the loop idled")
	testing.expect(t, platform.cadence_input_starts_answer(false, 20 * MS, period), "3.6 periods without a present")
	testing.expect(t, !platform.cadence_input_starts_answer(false, 1 * MS, period), "a frame a millisecond ago")
	testing.expect(t, !platform.cadence_input_starts_answer(false, 8 * MS, period), "1.4 periods: still one run")
}

@(test)
an_inner_frame_changes_state_only_with_a_new_size :: proc(t: ^testing.T) {
	c := presented_cadence()
	c.state = .Continuous
	testing.expect(t, !platform.cadence_inner_frame(&c, false, true, 0), "nothing new: paced")
	testing.expect(t, platform.cadence_inner_frame(&c, true, true, 0), "a new size: at once")
	testing.expect_value(t, c.state, platform.Cadence_State.Resize_Step)
	testing.expect(t, !platform.cadence_inner_frame(&c, false, true, 0), "the next inner frame is no step")
	testing.expect_value(t, c.state, platform.Cadence_State.Continuous)
	c.state, c.input_answer = .Resize_Step, true
	testing.expect(t, platform.cadence_inner_frame(&c, false, true, 0), "a step that answered input stays an answer")
	c.state, c.input_answer = .Continuous, false
	testing.expect(t, !platform.cadence_inner_frame(&c, true, false, 0), "never before the first present")
}

// A resize made of inner frames (a loop of the system) has its burst like any other.
@(test)
a_size_step_of_an_inner_frame_starts_a_burst :: proc(t: ^testing.T) {
	c := presented_cadence()
	now: i64 = 1_000_000_000
	platform.cadence_inner_frame(&c, true, true, now)
	d := platform.frame_decision(&c, {now_ns = now + 1_000_000, presented = true})
	testing.expect_value(t, d.state, platform.Cadence_State.Resize_Burst)
}

@(test)
an_echo_of_a_resize_step_is_not_made :: proc(t: ^testing.T) {
	c := presented_cadence()
	c.state = .Resize_Burst
	testing.expect(t, platform.cadence_echo(&c, false, 0, 0, false), "after a step, nothing new: skipped")
	testing.expect(t, !platform.cadence_echo(&c, true, 0, 0, false), "a step is made")
	testing.expect(t, !platform.cadence_echo(&c, false, 1, 0, false), "input came")
	testing.expect(t, !platform.cadence_echo(&c, false, 0, 2, false), "a task ran")
	testing.expect(t, !platform.cadence_echo(&c, false, 0, 0, true), "something wants a frame")
	c.state = .Resize_Step
	testing.expect(t, platform.cadence_echo(&c, false, 0, 0, false), "a frame after the step, at the step's size")
	c.state = .Continuous
	testing.expect(t, !platform.cadence_echo(&c, false, 0, 0, false), "outside a resize: frames as asked")
}

////////////////////////////////
// The plan

@(test)
the_plan_of_a_screen :: proc(t: ^testing.T) {
	// Windows 11's dynamic refresh rate: rests at 60, reports 60, shows up to 180
	p := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	testing.expect(t, p.variable && p.timed && p.interval == 1 && p.slots.strict)
	testing.expect_value(t, p.hz, 180)
	testing.expect_value(t, p.slots.period_ns, i64(5_555_555))
	c: platform.Cadence
	platform.cadence_adopt(&c, p)
	testing.expect(t, c.variable && c.slots == p.slots, "the cadence takes the plan's clock and screen")
	p = platform.cadence_plan({hz = 60.001, max_hz = 180}, {variable = .Off})
	testing.expect(t, !p.variable && !p.timed && p.hz == 60.001)
	platform.cadence_adopt(&c, p)
	testing.expect(t, !c.variable, "and again when the plan changes")
	p = platform.cadence_plan({hz = 60.001, max_hz = 180}, {target_hz = 120})
	testing.expect_value(t, p.hz, 120)
	p = platform.cadence_plan({hz = 60.001, max_hz = 180}, {max_hz = 100})
	testing.expect(t, p.hz == 100 && p.timed)
	p = platform.cadence_plan({hz = 179.98, max_hz = 180}, {})
	testing.expect(t, !p.variable && !p.timed && !p.slots.strict, "a screen at its top rate paces the frames: the cap is a net")
	p = platform.cadence_plan({hz = 179.98, max_hz = 179.98}, {variable = .On})
	testing.expect(t, p.variable && p.timed)
	p = platform.cadence_plan({hz = 180, max_hz = 180}, {tearing = true})
	testing.expect(t, p.timed && p.slots.strict, "tearing: the application times every frame")
	testing.expect_value(t, platform.cadence_target_rate(0, 0, 0), 60)
	testing.expect_value(t, platform.cadence_target_rate(240, 0, 0, 180), 240)
	Case :: struct { display, hz: f64, tearing: bool, interval: int, timed: bool }
	for c in ([?]Case{{180, 180, false, 1, false}, {180, 90, false, 2, false}, {180, 60, false, 3, false}, {180, 45, false, 4, false}, {180, 144, false, 1, true}, {180, 240, false, 1, false}, {59.94, 60, false, 1, false}, {180, 180, true, 1, true}}) {
		i, timed := platform.cadence_sync(c.display, c.hz, c.tearing)
		testing.expectf(t, i == c.interval && timed == c.timed, "%v Hz on %v Hz: %d %v", c.hz, c.display, i, timed)
	}
}

@(test)
the_frame_clock_advances_by_whole_periods :: proc(t: ^testing.T) {
	for hz in ([?]f64{60, 120, 144, 180, 240}) {
		period := 1000 / hz
		last := 1234.5
		clk: platform.Frame_Clock
		seed: u32 = 7
		for frame in 0 ..< 300 {
			seed = seed * 1664525 + 1013904223
			jitter := 0.05 + 0.85 * f64(seed >> 8) / f64(1 << 24)
			vblank := last + f64(frame + 10) * period
			prev := clk.frame_ms
			platform.frame_clock_advance(&clk, vblank + jitter * period, period, last, period, 0, false)
			testing.expectf(t, abs(clk.frame_ms - vblank) < 1e-6, "%v Hz frame %d", hz, frame)
			if frame > 0 { testing.expectf(t, abs(clk.frame_ms - prev - period) < 1e-6 && abs(f64(clk.dt) - period / 1000) < 1e-6, "%v Hz: step", hz) }
		}
	}
	// a timed cadence: the slot; never backwards
	clk := platform.Frame_Clock{prev_ms = 100, frame_ms = 100}
	platform.frame_clock_advance(&clk, 107, 5, 0, 0, 105.5, true)
	testing.expect_value(t, clk.frame_ms, 105.5)
	platform.frame_clock_advance(&clk, 105, 5, 0, 0, 104, true)
	testing.expect_value(t, clk.frame_ms, 105.5)
	testing.expect_value(t, clk.dt, f32(0.005))   // (no time passed: a period)
	testing.expect_value(t, platform.vblank_at_or_before(42, 0, 0), 42)
}

// The compositor's answers (Wayland's wp_presentation) as Vblank_Timing: the period it gives, else the one its refresh
// counter measures; a rest is no sample; shown and discarded pictures counted apart.
@(test)
the_vblank_timing_follows_the_compositors_answers :: proc(t: ^testing.T) {
	// a period given: taken as it is
	v: platform.Vblank_Timing
	platform.vblank_presented(&v, 1000 * MS, 10, 6_944_444)
	testing.expect_value(t, v.period_ns, 6_944_444)
	testing.expect_value(t, v.last_ns, 1000 * MS)
	testing.expect_value(t, v.msc, 10)
	// none given (a variable refresh): measured from the counter, a picture every other refresh at 60 Hz
	w: platform.Vblank_Timing
	at: i64 = 5000 * MS
	for i in 0 ..< 20 {
		platform.vblank_presented(&w, at, u64(100 + 2 * i), 0)
		at += 2 * 16_666_667
	}
	testing.expectf(t, abs(w.period_ns - 16_666_667) < 1000, "measured %.0f ns", w.period_ns)
	testing.expect_value(t, w.shown, 20)
	// a rest of a minute: the counter's jump measures nothing
	before := w.period_ns
	platform.vblank_presented(&w, at + 60_000 * MS, w.msc + 3600, 0)
	testing.expect_value(t, w.period_ns, before)
	// a counter that goes back (another output): no sample either
	platform.vblank_presented(&w, w.last_ns + 16 * MS, 5, 0)
	testing.expect_value(t, w.period_ns, before)
	// a picture never shown: its own count, not a shown one
	platform.vblank_discarded(&w)
	testing.expect_value(t, w.discarded, 1)
	testing.expect_value(t, w.shown, 22)
	// neither period nor counter (sway's headless output): the gaps are whole refreshes of a 144 Hz screen, one or two,
	// counted against the mode's 60 Hz first: it settles on 144 Hz, and a rest's gap measures nothing
	n: platform.Vblank_Timing
	p :: 6_944_444
	at = 9000 * MS
	for i in 0 ..< 200 {
		platform.vblank_presented(&n, at, 0, 0, hint_ns = p)
		at += i % 3 == 0 ? 2 * p : p
	}
	testing.expectf(t, abs(n.period_ns - p) < 2000, "measured with no counter %.0f ns", n.period_ns)
	settled := n.period_ns
	platform.vblank_presented(&n, at + 5000 * MS, 0, 0, hint_ns = p)
	testing.expect_value(t, n.period_ns, settled)
}

////////////////////////////////
// The start just in time

@(private = "file") P60 :: 16_666_667

// The lead (how long before a vblank a present must be made to be shown at it) is learned from the pictures: one shown a
// refresh late raises it past the bound it proves, one shown early lowers it to what it took, two refreshes late is no
// sample. A compositor that composes at the vblank before (sway: a deadline a period ahead) is learned in a few frames,
// then missed only once in a long while (the lead probes later).
@(test)
the_lead_is_learned_from_the_pictures :: proc(t: ^testing.T) {
	lead: f64
	// on time: nothing to raise (and nothing under 0)
	platform.vblank_lead_learn(&lead, 1000 * MS, 1002 * MS, P60)
	testing.expect_value(t, lead, 0)
	// a refresh late: the deadline was before the present, the lead jumps past it
	platform.vblank_lead_learn(&lead, 1000 * MS, 1000 * MS + 2 * MS + P60, P60)
	testing.expectf(t, abs(lead - 2_500_000) < 1, "past the bound, plus half a millisecond: %.0f", lead)
	// earlier than predicted: the deadline was later, the lead drops to what the picture took
	lead = 10 * MS
	platform.vblank_lead_learn(&lead, 1000 * MS, 1003 * MS, P60)
	testing.expect_value(t, lead, 3 * MS)
	// two refreshes late: a hiccup, no sample
	platform.vblank_lead_learn(&lead, 1000 * MS, 1000 * MS + 3 * MS + 2 * P60, P60)
	testing.expect_value(t, lead, 3 * MS)

	// a compositor whose deadline is a period before the vblank, frames presented a millisecond before the deadline the
	// lead predicts
	TRUE_LEAD :: P60
	lead = 0
	vblank := i64(5000) * MS
	misses_late := 0
	for i in 0 ..< 300 {
		target := vblank + P60
		present := target - i64(lead) - MS
		shown := present <= target - TRUE_LEAD ? target : target + P60
		if shown != target && i >= 200 { misses_late += 1 }
		platform.vblank_lead_learn(&lead, present, shown, P60)
		vblank = shown
	}
	testing.expectf(t, lead >= TRUE_LEAD - 1.5 * MS && lead <= TRUE_LEAD + MS, "learned %.2f ms for a deadline %.2f ms ahead", lead / 1e6, f64(TRUE_LEAD) / 1e6)
	testing.expectf(t, misses_late <= 1, "%d pictures late in the last 100", misses_late)
}

// The cost of a frame is a high percentile of the recent ones, not their mean; nothing before enough frames.
@(test)
the_cost_of_a_frame_is_a_high_percentile :: proc(t: ^testing.T) {
	c: platform.Frame_Cost
	for _ in 0 ..< platform.FRAME_COST_MIN - 1 { platform.frame_cost_add(&c, 2 * MS) }
	testing.expect_value(t, platform.frame_cost_estimate(&c), 0)
	c = {}
	for i in 1 ..= 32 { platform.frame_cost_add(&c, i64(i) * MS) }
	testing.expect_value(t, platform.frame_cost_estimate(&c), 29 * MS)   // (the mean would be 16.5 ms)
	// the ring keeps the last 32: a run of light frames after heavy ones
	for _ in 0 ..< 32 { platform.frame_cost_add(&c, 3 * MS) }
	testing.expect_value(t, platform.frame_cost_estimate(&c), 3 * MS)
}

// A 60 Hz cadence whose frames cost 2 ms, eight of them measured.
@(private = "file")
measured_cadence :: proc() -> platform.Cadence {
	c: platform.Cadence
	platform.cadence_adopt(&c, platform.cadence_plan({hz = 60, max_hz = 60}, {}))
	for _ in 0 ..< platform.FRAME_COST_MIN { platform.frame_cost_add(&c.cost, 2 * MS) }
	return c
}

// A frame of a run starts at the deadline of the refresh after the previous picture's, minus its cost and the margin; a
// frame later than that goes at once; the first frame after a rest and a frame with no timing are not delayed.
@(test)
a_frame_starts_just_in_time :: proc(t: ^testing.T) {
	v0 := i64(10_000) * MS                 // the vblank the previous picture reaches
	grid := v0 - 3 * P60                   // the last vblank the server said (three refreshes before)
	lead := f64(1 * MS)
	prev := v0 - 5 * MS                    // the previous present, before v0's deadline
	start := v0 + P60 - 1 * MS - 2 * MS - platform.JIT_MARGIN_NS
	testing.expect_value(t, platform.jit_start(prev, grid, P60, lead, 2 * MS), start)

	// decided just after the previous present (as on Windows, before the vblank that shows it): it waits for its start
	c := measured_cadence()
	c.present_ns = prev
	d := platform.frame_decision(&c, {now_ns = prev + MS / 2, presented = true, vblank_ns = grid, period_ns = P60, lead_ns = lead})
	testing.expect_value(t, d.state, platform.Cadence_State.Continuous)
	testing.expect(t, d.just_in_time, "timed just in time")
	testing.expect_value(t, d.wait_until_ns, start)
	testing.expect_value(t, d.wait_ns, start - (prev + MS / 2))

	// later than its start: at once, never held to the next deadline
	c = measured_cadence()
	c.present_ns = prev
	d = platform.frame_decision(&c, {now_ns = start + MS, presented = true, vblank_ns = grid, period_ns = P60, lead_ns = lead})
	testing.expect(t, !d.just_in_time, "late: not timed")
	testing.expect_value(t, d.wait_ns, 0)

	// the first frame after a rest: at once
	c = measured_cadence()
	c.present_ns = prev
	d = platform.frame_decision(&c, {now_ns = prev + MS / 2, idled = true, presented = true, vblank_ns = grid, period_ns = P60, lead_ns = lead})
	testing.expect_value(t, d.state, platform.Cadence_State.Rest)
	testing.expect(t, !d.just_in_time && d.wait_ns == 0, "a rest's first frame goes at once")

	// no timing, or no cost measured yet: the slot alone
	c = measured_cadence()
	c.present_ns = prev
	d = platform.frame_decision(&c, {now_ns = prev + MS / 2, presented = true})
	testing.expect(t, !d.just_in_time && d.wait_ns == 0, "no vblanks known")
	c = {}
	platform.cadence_adopt(&c, platform.cadence_plan({hz = 60, max_hz = 60}, {}))
	c.present_ns = prev
	d = platform.frame_decision(&c, {now_ns = prev + MS / 2, presented = true, vblank_ns = grid, period_ns = P60, lead_ns = lead})
	testing.expect(t, !d.just_in_time, "no cost measured")

	// a screen that does not pace the frames (variable refresh): its slots, no start just in time
	c = measured_cadence()
	platform.cadence_adopt(&c, platform.cadence_plan({hz = 60, max_hz = 144}, {}))
	c.present_ns = prev
	d = platform.frame_decision(&c, {now_ns = prev + MS / 2, presented = true, vblank_ns = grid, period_ns = P60, lead_ns = lead})
	testing.expect(t, !d.just_in_time, "variable refresh")
}

// A run of frames on a 60 Hz screen whose compositor keeps a 3 ms deadline: after the frames that measure the cost, each
// starts at its refresh's deadline minus its cost and the margin, is presented before that deadline, and one picture
// reaches each refresh. The cost is learned through cadence_started and cadence_presented.
@(test)
a_run_reads_its_input_just_in_time :: proc(t: ^testing.T) {
	LEAD :: 3 * MS
	COST :: 2 * MS
	c: platform.Cadence
	platform.cadence_adopt(&c, platform.cadence_plan({hz = 60, max_hz = 60}, {}))
	vblank := i64(20_000) * MS   // the last vblank a picture reached
	now := vblank + 1 * MS
	shown_prev: i64
	timed := 0
	for i in 0 ..< 40 {
		d := platform.frame_decision(&c, {now_ns = now, idled = i == 0, presented = i > 0, vblank_ns = vblank, period_ns = P60, lead_ns = LEAD})
		now += d.wait_ns
		platform.cadence_started(&c, now)
		if d.just_in_time {
			timed += 1
			// the refresh after the previous picture's, its deadline, the frame's cost and the margin before it
			testing.expectf(t, now == shown_prev + P60 - LEAD - COST - platform.JIT_MARGIN_NS, "frame %d starts at %d, its refresh at %d", i, now, shown_prev + P60)
		}
		now += COST
		platform.cadence_presented(&c, now)
		// the screen: the first vblank whose deadline the present made
		shown := vblank
		for shown - LEAD < now { shown += P60 }
		if d.just_in_time { testing.expectf(t, shown == shown_prev + P60, "frame %d: one picture a refresh", i) }
		shown_prev, vblank = shown, shown
		// (the program asks the next frame at once: an animation)
		now += 100_000
	}
	testing.expectf(t, timed >= 40 - 1 - platform.FRAME_COST_MIN, "frames timed just in time: %d", timed)
}

////////////////////////////////
// Simulated runs

// A screen: `refresh_ns` 0 releases the swap chain's slot at once (variable refresh, tearing, a compositor that takes every
// frame); otherwise at the vblank after the last present. `rest_ns`: a variable refresh screen under a dynamic refresh rate
// at rest (the rate the system reports, 60 Hz): a frame that waits for a refresh is shown at the next vblank of that grid,
// and the swap chain's slot comes back then; a frame shown at once is on screen when it is presented (the screen follows
// it, up to its top rate). Input every `input_ns` while `input` says so; the window's size changes at the times `resized`
// says; each frame costs `cost_ns`.
@(private = "file")
Sim :: struct {
	refresh_ns: i64,
	rest_ns:    i64,
	input_ns:   i64,
	cost_ns:    i64,
	input:      proc(now: i64) -> bool,
	resized:    proc(now, last: i64) -> bool,
	dragging:   bool,
	echoes:     bool,   // frames with nothing new are skipped in a burst (cadence_echo)
}

@(private = "file")
Run :: struct {
	frames, at_once, waits, skipped: int,
	shortest_ns: i64,
	longest_shown_ns: i64,   // the longest time between two frames reaching the screen (after the first two)
	counts:      [platform.Cadence_State]int,
}

@(private = "file")
simulate :: proc(plan: platform.Cadence_Plan, s: Sim, span_ms: int) -> (r: Run) {
	c: platform.Cadence
	platform.cadence_adopt(&c, plan)
	start := i64(5_000) * MS
	now := start
	end := now + i64(span_ms) * MS
	last_frame, last_present, last_size, last_shown := i64(0), i64(0), start, i64(0)
	presented, slot_held := false, false
	r.shortest_ns = max(i64)
	for now < end {
		idled := last_frame == 0 || now - last_frame > 50 * MS
		input := s.input(now)
		resized := s.resized(now, last_size)
		if resized { last_size = now }
		d := platform.frame_decision(&c, {now_ns = now, idled = idled, input = input, presented = presented, resized = resized, dragging = s.dragging, slot_held = slot_held})
		now += d.wait_ns
		if d.wait_ns > 0 { r.waits += 1 }
		if d.wait_swap_chain && s.refresh_ns > 0 {
			// the latency object: released at the vblank after the last present
			vb := (last_present / s.refresh_ns + 1) * s.refresh_ns
			if vb > now { now = vb }
		}
		// (one frame queued: its slot comes back when the frame waiting for a refresh before it is shown)
		if d.wait_swap_chain && s.rest_ns > 0 && d.latency == 1 && last_shown > now { now = last_shown }
		slot_held = d.wait_swap_chain
		if s.echoes && platform.cadence_echo(&c, resized, input ? 1 : 0, 0, false) {
			r.skipped += 1
		} else {
			if r.frames >= 2 { r.shortest_ns = min(r.shortest_ns, now - last_frame) }
			r.frames += 1
			if d.present_at_once { r.at_once += 1 }
			last_frame = now
			now += s.cost_ns
			last_present = now
			shown := now
			if s.rest_ns > 0 && !d.present_at_once { shown = (now / s.rest_ns + 1) * s.rest_ns }
			if r.frames > 2 { r.longest_shown_ns = max(r.longest_shown_ns, shown - last_shown) }
			last_shown = shown
			platform.cadence_presented(&c, now)
			presented, slot_held = true, false
		}
		// the next wake: the next input (or the next frame asked for: a continuous run asks for the next one at once)
		now = (now / s.input_ns + 1) * s.input_ns
	}
	r.counts = c.counts
	return
}

@(private = "file") always :: proc(now: i64) -> bool { return true }
@(private = "file") never_resized :: proc(now, last: i64) -> bool { return false }
@(private = "file") resized_every_ms :: proc(now, last: i64) -> bool { return now - last >= 1 * MS }
// AltSnap: a step every 6 ms (500 steps in 3 s); the loop also wakes in between for the program's messages
@(private = "file") resized_every_6ms :: proc(now, last: i64) -> bool { return now - last >= 6 * MS }
@(private = "file") no_input :: proc(now: i64) -> bool { return false }

@(test)
a_fixed_refresh_screen_paces_the_frames :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 60, max_hz = 60}, {})
	r := simulate(plan, {refresh_ns = 16_666_667, input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames >= 58 && r.frames <= 61, "a pointer at 1 kHz on a 60 Hz screen: one frame per refresh (%d)", r.frames)
	testing.expectf(t, r.at_once <= 1, "only the first answer is shown at once (%d)", r.at_once)
	testing.expect(t, !plan.slots.strict, "the screen paces: the cap is a net")
}

@(test)
a_variable_refresh_screen_is_paced_by_the_slots :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames >= 170 && r.frames <= 181, "180 Hz under a 1 kHz mouse (%d)", r.frames)
	testing.expectf(t, r.shortest_ns >= 5_500_000, "no two frames closer than a period (%v)", r.shortest_ns)
	testing.expect(t, r.counts[.Continuous] >= 169)
	// a frame that costs more than a period is not made up for
	r = simulate(plan, {input_ns = 1 * MS, cost_ns = 7 * MS, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames >= 100 && r.frames <= 181, "frames of 7 ms (%d)", r.frames)
}

@(test)
tearing_is_paced_by_the_slots :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 180, max_hz = 180}, {tearing = true})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames >= 170 && r.frames <= 181, "%d frames", r.frames)
}

@(test)
a_screen_that_paces_nothing_tightens_a_loose_cap :: proc(t: ^testing.T) {
	// variable_refresh = off on a screen that varies: the system says 60, the swap chain does not pace the app
	plan := platform.cadence_plan({hz = 60, max_hz = 180}, {variable = .Off})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames <= 67, "%d frames at 60 Hz", r.frames)
	plan.slots.period_ns = 0   // no cap: a frame per move (what a loop with input did)
	r = simulate(plan, {input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, r.frames > 400, "%d frames without a cap", r.frames)
}

@(test)
a_panel_dragged_at_1_khz_makes_one_frame_per_slot :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 500_000, input = always, resized = never_resized, dragging = true}, 100)
	testing.expectf(t, r.frames >= 17 && r.frames <= 19, "100 ms at 180 Hz: 18 frames, not 100 (%d)", r.frames)
	testing.expectf(t, r.counts[.Drag] >= 16 && r.shortest_ns >= 5_500_000, "paced as a drag, one per slot (%d, %v ns)", r.counts[.Drag], r.shortest_ns)
}

// The splitter between the page and a panel docked beside it, dragged by a 1 kHz mouse on a 180 Hz G-Sync screen that
// Windows' dynamic refresh rate reports at 60 Hz at rest: every frame reaches the screen a period of the top rate after the one
// before, as the window's own edge does when it is dragged. (A frame that waited for a refresh waited for the 60 Hz the
// system reports: 16.7 ms between two pictures.)
@(test)
a_splitter_dragged_on_a_variable_screen_is_shown_at_its_top_rate :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	rest := i64(16_666_667)
	r := simulate(plan, {rest_ns = rest, input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized, dragging = true}, 1000)
	testing.expectf(t, r.frames >= 170 && r.frames <= 181, "a second of dragging: 180 frames (%d)", r.frames)
	testing.expectf(t, r.longest_shown_ns <= plan.slots.period_ns, "no two pictures further apart than a period of 180 Hz (%v ns)", r.longest_shown_ns)
	testing.expectf(t, r.shortest_ns >= 5_500_000, "nor closer: one frame per slot, not per move (%v ns)", r.shortest_ns)
	testing.expectf(t, r.at_once >= r.frames - 1 && r.counts[.Drag] >= r.frames - 2, "shown at once (%d of %d), as drags (%d)", r.at_once, r.frames, r.counts[.Drag])
	// the window's own edge on the same screen, for comparison: its steps are shown at once as well
	w := simulate(plan, {rest_ns = rest, input_ns = 1 * MS, cost_ns = 500_000, input = always, resized = resized_every_ms}, 200)
	testing.expect_value(t, w.at_once, w.frames - 1)
	// what the frames of anything else that moves do there (an animation, the wheel): at the refresh, as before
	a := simulate(plan, {rest_ns = rest, input_ns = 1 * MS, cost_ns = 1_300_000, input = always, resized = never_resized}, 1000)
	testing.expectf(t, a.at_once <= 1 && a.counts[.Continuous] >= a.frames - 2, "a run that is no drag is not shown at once (%d)", a.at_once)
}

// A fixed refresh screen: a drag waits for the refresh (shown at once, a frame would tear and come no sooner).
@(test)
a_splitter_dragged_on_a_fixed_screen_waits_for_the_refresh :: proc(t: ^testing.T) {
	for hz in ([?]f64{60, 144, 180}) {
		plan := platform.cadence_plan({hz = hz, max_hz = hz}, {})
		refresh := i64(1e9 / hz)
		r := simulate(plan, {refresh_ns = refresh, input_ns = 1 * MS, cost_ns = 1_000_000, input = always, resized = never_resized, dragging = true}, 1000)
		testing.expectf(t, r.at_once <= 1, "%v Hz: only the press is answered at once (%d)", hz, r.at_once)
		testing.expectf(t, f64(r.frames) >= hz * 0.95 && f64(r.frames) <= hz + 1, "%v Hz: one frame per refresh (%d)", hz, r.frames)
	}
}

@(test)
a_window_resized_every_millisecond_shows_each_step_at_once :: proc(t: ^testing.T) {
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 500_000, input = always, resized = resized_every_ms}, 200)
	testing.expect(t, r.counts[.Resize_Step] >= 150, "every new size is a step")
	testing.expect_value(t, r.at_once, r.frames - 1)   // (the first frame: nothing presented yet)
	testing.expect_value(t, r.waits, 0)
}

@(test)
altsnap_steps_from_outside_are_shown_at_once_and_their_echoes_are_skipped :: proc(t: ^testing.T) {
	// (a 180 Hz variable refresh screen: the slots, 5.6 ms apart, are the only pacing; a wake between two steps waits for
	// its slot, then has nothing to show)
	plan := platform.cadence_plan({hz = 60.001, max_hz = 180}, {})
	r := simulate(plan, {input_ns = 1 * MS, cost_ns = 500_000, input = no_input, resized = resized_every_6ms, echoes = true}, 3000)
	testing.expectf(t, r.counts[.Resize_Step] >= 490, "500 steps in 3 s, each a frame (%d)", r.counts[.Resize_Step])
	// (all but the first two: nothing presented yet, then a frame before the first step)
	testing.expectf(t, r.at_once >= r.frames - 2, "all shown at once (%d of %d)", r.at_once, r.frames)
	testing.expectf(t, r.skipped >= 400, "the wakes between steps make no frame (%d)", r.skipped)
	testing.expectf(t, r.frames <= r.counts[.Resize_Step] + 2, "one picture per step (%d frames)", r.frames)
	// without skipping the echoes, the burst's frames are shown at once too: none waits for a refresh in Present
	r = simulate(plan, {input_ns = 1 * MS, cost_ns = 500_000, input = no_input, resized = resized_every_6ms}, 3000)
	testing.expectf(t, r.at_once >= r.frames - 2, "%d of %d", r.at_once, r.frames)
	testing.expect(t, r.counts[.Resize_Burst] >= 400)
}

////////////////////////////////
// input_pending: the user's input is seen without being taken

@(test)
input_pending_sees_input_and_keeps_it :: proc(t: ^testing.T) {
	w := platform.open_window_offscreen("pending", {200, 100})
	if !testing.expect(t, w != nil) { return }
	defer platform.destroy_window(w)
	testing.expect(t, !platform.input_pending(w), "nothing yet")
	_ = platform.poll_events(w, false)
	platform.inject_event(w, {kind = .Activate})
	testing.expect(t, !platform.input_pending(w), "a window event is not the user's input")
	platform.inject_event(w, {kind = .Mouse_Move, pos = {10, 20}})
	testing.expect(t, platform.input_pending(w), "the pointer moved")
	evs := platform.poll_events(w, false)
	testing.expect_value(t, len(evs), 2)   // both handed out again, nothing lost
	if len(evs) == 2 {
		testing.expect_value(t, evs[0].kind, platform.Event_Kind.Activate)
		testing.expect_value(t, evs[1].kind, platform.Event_Kind.Mouse_Move)
	}
	testing.expect(t, !platform.input_pending(w), "taken")
}

// Kept is not read: a wait does not sleep over it. And inside the window's own poll nothing is read, nor kept twice.
@(test)
input_pending_keeps_what_a_wait_must_see :: proc(t: ^testing.T) {
	WAIT_THAT_ENDS_A_FAILING_RUN_MS :: 2000
	w := platform.open_window_offscreen("pending wait", {200, 100})
	if !testing.expect(t, w != nil) { return }
	defer platform.destroy_window(w)
	platform.inject_event(w, {kind = .Mouse_Move, pos = {10, 20}})
	testing.expect(t, platform.input_pending(w))
	start := time.tick_now()
	platform.wait_event(w, WAIT_THAT_ENDS_A_FAILING_RUN_MS)
	testing.expect(t, time.duration_milliseconds(time.tick_since(start)) < WAIT_THAT_ENDS_A_FAILING_RUN_MS / 2, "the wait ends at once")
	testing.expect_value(t, len(platform.poll_events(w, false)), 1)
	w.in_poll = true   // (as inside a frame callback)
	testing.expect(t, !platform.input_pending(w))
	w.in_poll = false
	testing.expect_value(t, len(platform.poll_events(w, false)), 0)
}
