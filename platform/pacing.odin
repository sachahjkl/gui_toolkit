package platform

// The cadence model: when a frame starts, whether it waits for the screen, and how it is shown. Pure (no clock, no window,
// no swap chain): the caller gives the time and what happened, executes the decision, and tells the model when it presented.
// Frame_Slots (frame_slots.odin) is its clock; docs/pacing.md has the whole model.
//
//   plan := cadence_plan(display_info(w), {})            // once, and again when the monitor or its rate changes
//   c.slots = plan.slots
//   ...
//   d := frame_decision(&c, {now_ns = now, idled = idled, input = input_waits, presented = shown_once, resized = size != last})
//   wait d.wait_ns (taking input meanwhile); if d.wait_swap_chain, wait for the swap chain's latency object
//   set the swap chain's latency to d.latency; ... make the frame ...; Present with no wait for a refresh if d.present_at_once
//   cadence_presented(&c, now)
//
// The rate aimed for is the screen's top useful rate (a variable or dynamic refresh screen: its top mode, not the rate it
// reports at rest), under the application's own target and ceiling; slots are one period of it apart. Each frame is in one
// state, the first that applies:
//
//   Resize_Step    the window has a new size: made and shown at once (no slot, no wait for the screen), two frames may queue;
//                  the composer would otherwise stretch the last frame, drawn for the old size, over the new one
//   Input_Answer   input woke a window at rest (nothing presented for CADENCE_INPUT_REST_PERIODS periods): made and shown at
//                  once, two frames may queue (the answer to a click or a key is not a refresh late)
//   Resize_Burst   within CADENCE_RESIZE_HOLD_NS of a size change: paced by its slot, but shown at once with two frames queued
//                  (a program that resizes the window from outside, AltSnap, waits for the thread at every step: a frame
//                  asleep in Present for a refresh would stall each step)
//   Rest           the loop slept before this frame and no input woke it: a new run of slots starts with it
//   Drag           a pointer drags something inside the window (a splitter, a panel's handle, a tab): paced as Continuous, one
//                  frame per slot. Not a resize step: the window keeps its size (a step skips the slot, and a pointer at 1 kHz
//                  made a frame a millisecond)
//   Continuous     frames follow one another (an animation, the wheel, a pointer sweeping the window): one per slot, each after
//                  the screen took the previous one
//
// A frame that is neither a resize step nor an input answer waits for its slot, then for the swap chain's slot (unless it
// holds one already, or nothing was presented yet: a swap chain never shown releases nothing).

import "core:math"

CADENCE_INPUT_REST_PERIODS :: 1.5            // input after this many periods without a present starts an answer (shown at once)
CADENCE_RESIZE_HOLD_NS     :: 120_000_000    // the frames this long after a size change are part of its burst

Cadence_State :: enum u8 { Rest, Continuous, Drag, Input_Answer, Resize_Step, Resize_Burst }

// What happened since the last frame, as the caller sees it.
Cadence_Inputs :: struct {
	now_ns:    i64,    // the clock of the slots (any monotonic tick in ns, not 0)
	idled:     bool,   // the loop slept before this frame (nothing moved)
	input:     bool,   // the user's input waits (keys, pointer, buttons, touch; not other threads' wake-ups)
	presented: bool,   // the window has presented a frame (none yet: nothing is shown at once, nothing is waited for)
	resized:   bool,   // the window's size is not the one of the last frame
	dragging:  bool,   // a pointer drags something inside the window
	slot_held: bool,   // the swap chain's slot was waited for and no frame was presented since
}

// What the frame does: the caller executes it.
Frame_Decision :: struct {
	state:           Cadence_State,
	wait_ns:         i64,    // how long before the frame starts (0: now)
	wait_until_ns:   i64,    // the same, as a time on the inputs' clock
	slot_ns:         i64,    // the slot the frame was timed for (its time on a timed cadence)
	wait_swap_chain: bool,   // then wait for the swap chain to take a frame
	present_at_once: bool,   // Present without waiting for a refresh (the frame may tear on a fixed refresh screen)
	latency:         int,    // frames the swap chain may queue (1, or 2 for a frame shown at once)
}

// The model's memory of one window, from frame to frame.
Cadence :: struct {
	slots:        Frame_Slots,   // the clock: set from cadence_plan
	state:        Cadence_State, // the last frame's
	input_answer: bool,          // the last frame answered input (also when it was a resize step)
	resize_ns:    i64,           // the last size change seen (0: none)
	present_ns:   i64,           // the last present (cadence_presented)
	counts:       [Cadence_State]int,   // frames decided in each state (statistics)
}

// Whether `now_ns` is within the hold after the last size change (`last_ns`, 0: none).
cadence_resize_burst :: proc(now_ns, last_ns: i64) -> bool {
	return last_ns != 0 && now_ns - last_ns < CADENCE_RESIZE_HOLD_NS
}

// Whether input starts an answer (shown at once) rather than continues one: the loop idled before it, or nothing was
// presented for CADENCE_INPUT_REST_PERIODS periods.
cadence_input_starts_answer :: proc(idled: bool, since_present_ns, period_ns: i64) -> bool {
	return idled || f64(since_present_ns) > f64(period_ns) * CADENCE_INPUT_REST_PERIODS
}

// The decision for the frame about to start; the cadence moves to its state.
frame_decision :: proc(c: ^Cadence, in_: Cadence_Inputs) -> (d: Frame_Decision) {
	step := in_.resized && in_.presented
	burst := !step && in_.presented && cadence_resize_burst(in_.now_ns, c.resize_ns)
	if in_.resized { c.resize_ns = in_.now_ns }
	answer := in_.input && in_.presented && cadence_input_starts_answer(in_.idled, in_.now_ns - c.present_ns, c.slots.period_ns)
	switch {
	case step:      d.state = .Resize_Step
	case answer:    d.state = .Input_Answer
	case burst:     d.state = .Resize_Burst
	case in_.idled: d.state = .Rest
	case in_.dragging: d.state = .Drag
	case:           d.state = .Continuous
	}
	c.state, c.input_answer = d.state, answer
	c.counts[d.state] += 1
	d.present_at_once = step || burst || answer
	d.latency = d.present_at_once ? 2 : 1
	d.wait_ns, d.slot_ns = frame_slot_wait(&c.slots, in_.now_ns, in_.idled, step || answer)
	if step { d.wait_ns = 0 }
	d.wait_until_ns = in_.now_ns + d.wait_ns
	d.wait_swap_chain = !step && !answer && in_.presented && !in_.slot_held
	return
}

// A frame made inside another one's work or a loop of the system (a frame of the interface alone): it has no slot of its
// own; only a new size changes its state. Returns whether it is shown at once.
cadence_inner_frame :: proc(c: ^Cadence, resized, presented: bool) -> (at_once: bool) {
	switch {
	case resized && presented: c.state = .Resize_Step
	case c.state == .Resize_Step || c.state == .Resize_Burst: c.state = .Continuous
	}
	return cadence_at_once(c)
}

// Whether the last decided frame is shown at once.
cadence_at_once :: proc(c: ^Cadence) -> bool {
	return c.state == .Resize_Step || c.state == .Resize_Burst || c.input_answer
}

// Whether the last decided frame belongs to a resize (its step or its burst).
cadence_resizing :: proc(c: ^Cadence) -> bool { return c.state == .Resize_Step || c.state == .Resize_Burst }

// A frame was presented at `now_ns`.
cadence_presented :: proc(c: ^Cadence, now_ns: i64) { c.present_ns = now_ns }

// A frame of a resize's burst that would only show the step's picture again: not a step (`step`: this frame is at a size not
// drawn yet), nothing came (`events`, `tasks`), nothing waits for a frame (`wants`). The caller does not make it.
cadence_echo :: proc(c: ^Cadence, step: bool, events, tasks: int, wants: bool) -> bool {
	return cadence_resizing(c) && !step && events == 0 && tasks == 0 && !wants
}

////////////////////////////////
// The plan: the rate aimed for on a screen

// Whether a screen is taken for one that shows frames above the rate it reports.
Variable_Refresh :: enum u8 {
	Auto,   // when its modes go higher than the rate it reports (refresh_is_variable)
	On,     // a screen that reports its top rate but varies it (G-Sync without a dynamic rate)
	Off,    // the rate the system reports
}

// The application's choices: everything else follows from the screen.
Cadence_Choices :: struct {
	target_hz: f64,                // 0: the screen's (its top rate when it is variable)
	max_hz:    f64,                // ceiling (0: none)
	variable:  Variable_Refresh,
	tearing:   bool,               // frames are presented with tearing (asked for and supported)
}

// What a screen and the choices make of the cadence.
Cadence_Plan :: struct {
	variable:  bool,          // the screen shows frames above the rate it reports: the target is its top rate
	hz:        f64,           // the rate aimed for
	period_ms: f64,           // 1000 / hz: the frame budget
	interval:  int,           // vsync refreshes per frame
	timed:     bool,          // the application times the frames itself (its slots are the clock)
	slots:     Frame_Slots,   // the cap: strict where the application paces (timed), a loose net where the screen does
}

cadence_plan :: proc(d: Display_Info, choices: Cadence_Choices) -> (p: Cadence_Plan) {
	p.variable = cadence_variable(choices.variable, d.hz, d.max_hz)
	p.hz = cadence_target_rate(d.hz, choices.target_hz, choices.max_hz, p.variable ? d.max_hz : 0)
	p.period_ms = 1000 / p.hz
	p.interval, p.timed = cadence_sync(d.hz, p.hz, choices.tearing, p.variable)
	p.slots = {period_ns = i64(p.period_ms * 1e6), strict = p.timed}
	return
}

cadence_variable :: proc(mode: Variable_Refresh, hz, max_hz: f64) -> bool {
	switch mode {
	case .On:   return hz > 0
	case .Off:  return false
	case .Auto: return refresh_is_variable(hz, max_hz)
	}
	return false
}

// The rate frames aim for: the target (0: the display's, or its top rate `top_hz` when it is variable), under the ceiling.
cadence_target_rate :: proc(display_hz, target_hz, max_hz: f64, top_hz: f64 = 0) -> f64 {
	hz := target_hz > 0 ? target_hz : (top_hz > display_hz ? top_hz : display_hz)
	if hz <= 0 { hz = 60 }
	if max_hz > 0 { hz = min(hz, max_hz) }
	return hz
}

// How a rate is reached on a display: vsync refreshes per frame, and whether the application times the frames itself. A rate
// within 1 % of display / n (n = 1..4) is every n-th refresh; any other one is timed, and so is everything with tearing and
// on a variable refresh screen. A rate above the display's cannot be shown with vsync: every refresh.
cadence_sync :: proc(display_hz, hz: f64, tearing: bool, variable := false) -> (interval: int, timed: bool) {
	if tearing || variable { return 1, true }
	if display_hz <= 0 || hz >= display_hz * 0.99 { return 1, false }
	for n in 1 ..= 4 {
		if abs(display_hz / f64(n) - hz) <= hz * 0.01 { return n, false }
	}
	return 1, true
}

////////////////////////////////
// The frame clock: the time a frame shows

// The time of the frames (animation timestamps, a CSS clock, smooth scrolling), in ms on the caller's clock.
Frame_Clock :: struct {
	frame_ms: f64,   // this frame's time
	prev_ms:  f64,   // the previous frame's (0: none)
	dt:       f32,   // seconds since the previous frame's time, for the interface's animations
}

// The vblank a frame starting at `now` belongs to: the latest one of the grid (`last` + k periods) not after `now`.
// Without a grid (period 0), `now`.
vblank_at_or_before :: proc(now, last, period: f64) -> f64 {
	if period <= 0 { return now }
	k := math.floor((now - last) / period)
	return last + k * period
}

// The frame's time: on a screen with a vblank grid (`grid_period_ms` > 0), the vblank it starts at, so that motion
// advances by whole refresh periods; on a timed cadence, the slot it was timed for (`slot_ms`, `has_slot`); else now. Never
// before the previous frame's; `dt` is clamped to 0.5 ms .. 100 ms.
frame_clock_advance :: proc(clk: ^Frame_Clock, now_ms, period_ms: f64, grid_last_ms, grid_period_ms: f64, slot_ms: f64, has_slot: bool) {
	t := now_ms
	if grid_period_ms > 0 {
		t = vblank_at_or_before(now_ms, grid_last_ms, grid_period_ms)
	} else if has_slot {
		t = min(slot_ms, now_ms)
	}
	if t <= clk.prev_ms { t = min(now_ms, clk.prev_ms + period_ms) }   // never backwards
	if t <= clk.prev_ms { t = clk.prev_ms }
	clk.dt = clk.prev_ms > 0 ? f32((t - clk.prev_ms) / 1000) : f32(period_ms / 1000)
	if clk.dt <= 0 { clk.dt = f32(period_ms / 1000) }
	clk.dt = clamp(clk.dt, 0.0005, 0.1)
	clk.prev_ms, clk.frame_ms = t, t
}
