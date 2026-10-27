// The cadence model (platform/pacing.odin): its states and transitions, and simulated runs of frames on screens that pace the
// application (fixed refresh), that do not (variable refresh, tearing), under input at 1 kHz, a resize, a panel dragged and
// a program that resizes the window from outside (AltSnap). The clock is a number and the screen a function: nothing here
// measures a duration of the machine.
//   odin test tests/pacing -vet
package pacing_test

import "core:testing"
import "../../platform"

MS :: 1_000_000

////////////////////////////////
// States and transitions

@(private = "file")
presented_cadence :: proc(hz: f64 = 180, strict := true) -> platform.Cadence {
	c: platform.Cadence
	c.slots = {period_ns = i64(1e9 / hz), strict = strict}
	return c
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
		testing.expect(t, platform.cadence_inner_frame(&c, false, true), "a frame of the chrome inside it: at once too")
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
	testing.expect(t, !platform.cadence_inner_frame(&c, false, true), "nothing new: paced")
	testing.expect(t, platform.cadence_inner_frame(&c, true, true), "a new size: at once")
	testing.expect_value(t, c.state, platform.Cadence_State.Resize_Step)
	testing.expect(t, !platform.cadence_inner_frame(&c, false, true), "the next inner frame is no step")
	testing.expect_value(t, c.state, platform.Cadence_State.Continuous)
	c.state, c.input_answer = .Resize_Step, true
	testing.expect(t, platform.cadence_inner_frame(&c, false, true), "a step that answered input stays an answer")
	c.state, c.input_answer = .Continuous, false
	testing.expect(t, !platform.cadence_inner_frame(&c, true, false), "never before the first present")
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
