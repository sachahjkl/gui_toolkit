package render

import "core:slice"
import "core:time"

// Input -> screen latency, stage by stage (off by default: set_latency_probe; nothing is recorded otherwise).
//
// Each frame built from input that reached the screen is one sample, split at the instants the chain gives us:
//
//   input   the window procedure received the event (Event.stamp)
//   read    the frame had read it and began to build (set_frame_read)        wait    = read - input
//   drawn   frame_end was called: built, drawn, submitted to the GPU         work    = call - read
//   call    Present was called
//   presented  Present returned                                              present = presented - call
//   shown   the refresh that put it on the screen (swap chain statistics)    scan    = shown - presented
//
// total = shown - input. An event that waits in the system's queue while the thread is busy is stamped when the thread
// takes it, so `wait` does not include that time: with a thread that blocks in Present, the real latency is longer.

Latency_Sample :: struct { wait, work, present, scan, total: f32 }   // ms

Latency_Probe :: struct {
	on:      bool,
	samples: [dynamic]Latency_Sample,   // the last LATENCY_RING, oldest dropped
	count:   u64,                       // samples since the last reset
	frames, with_input: u64,            // frames seen on screen / of them, built from input (what share of the frames is sampled)
	presents: u64,                      // presents seen by the swap chain's statistics
	depth_sum, depth_max: u64,          // frames presented and not yet on screen, at each present (queue_depth)
}

@(private) LATENCY_RING :: 4096

Latency_Stat :: struct { p50, p95, max, mean: f32 }

Latency_Summary :: struct {
	samples:   int,
	frames, with_input: int,  // frames seen on screen, and of them built from input
	queue_mean: f32,          // frames presented and not on screen yet, at a present: how deep the swap chain's queue is (d3d11)
	queue_max:  int,
	wait, work, present, scan, total: Latency_Stat,
	period_ms: f32,         // the monitor's refresh period (0: unknown)
	refreshes: Latency_Stat, // total, in refreshes of the monitor (all zero without a period)
}

// Starts or stops the recording (stopping keeps what was recorded).
set_latency_probe :: proc(r: ^Renderer, on: bool) { r.present.probe.on = on }
latency_probe_on :: proc(r: ^Renderer) -> bool { return r.present.probe.on }

// Forgets what was recorded.
latency_reset :: proc(r: ^Renderer) {
	clear(&r.present.probe.samples)
	p := &r.present.probe
	p.count, p.frames, p.with_input, p.presents, p.depth_sum, p.depth_max = 0, 0, 0, 0, 0, 0
}

// At each present: how many earlier frames the screen had not taken yet (the swap chain's queue, 0 = none waiting).
@(private)
latency_probe_depth :: proc(p: ^Latency_Probe, depth: u64) {
	p.presents += 1
	p.depth_sum += depth
	p.depth_max = max(p.depth_max, depth)
}

// The summary of the recorded samples (p50 / p95 / max / mean of each stage).
latency_summary :: proc(r: ^Renderer) -> Latency_Summary {
	s := latency_summarize(r.present.probe.samples[:])
	pr := &r.present.probe
	s.frames, s.with_input = int(pr.frames), int(pr.with_input)
	if pr.presents > 0 { s.queue_mean = f32(f64(pr.depth_sum) / f64(pr.presents)) }
	s.queue_max = int(pr.depth_max)
	if r.present.period_ns > 0 {
		s.period_ms = f32(r.present.period_ns / 1e6)
		t := s.total
		s.refreshes = {t.p50 / s.period_ms, t.p95 / s.period_ms, t.max / s.period_ms, t.mean / s.period_ms}
	}
	return s
}

// Pure: the statistics of `samples`.
latency_summarize :: proc(samples: []Latency_Sample) -> (s: Latency_Summary) {
	s.samples = len(samples)
	if len(samples) == 0 { return }
	vals := make([]f32, len(samples), context.temp_allocator)
	stat :: proc(vals: []f32, samples: []Latency_Sample, pick: proc(Latency_Sample) -> f32) -> Latency_Stat {
		sum: f64
		for x, i in samples { vals[i] = pick(x); sum += f64(vals[i]) }
		slice.sort(vals)
		n := len(vals)
		return {vals[max((n * 50 + 99) / 100 - 1, 0)], vals[max((n * 95 + 99) / 100 - 1, 0)], vals[n - 1], f32(sum / f64(n))}
	}
	s.wait    = stat(vals, samples, proc(x: Latency_Sample) -> f32 { return x.wait })
	s.work    = stat(vals, samples, proc(x: Latency_Sample) -> f32 { return x.work })
	s.present = stat(vals, samples, proc(x: Latency_Sample) -> f32 { return x.present })
	s.scan    = stat(vals, samples, proc(x: Latency_Sample) -> f32 { return x.scan })
	s.total   = stat(vals, samples, proc(x: Latency_Sample) -> f32 { return x.total })
	return
}

// One frame that reached the screen. Ignored without the probe, and for a frame built from no input (or one whose
// stages are not all known: a frame_end called without set_frame_read).
@(private)
latency_probe_add :: proc(p: ^Latency_Probe, d: Displayed_Frame) {
	if !p.on { return }
	p.frames += 1
	if d.input._nsec != 0 { p.with_input += 1 }
	if sample, ok := latency_sample_of(d); ok {
		if len(p.samples) >= LATENCY_RING { ordered_remove(&p.samples, 0) }
		append(&p.samples, sample)
		p.count += 1
	}
}

// The stages of a displayed frame (ok false: built from no input, or an instant is missing).
latency_sample_of :: proc(d: Displayed_Frame) -> (s: Latency_Sample, ok: bool) {
	if d.input._nsec == 0 || d.read._nsec == 0 || d.call._nsec == 0 || d.shown._nsec <= d.input._nsec { return }
	ms :: proc(a, b: time.Tick) -> f32 { return max(f32(time.tick_diff(a, b)) / 1e6, 0) }   // negative: 0 (instants of different clocks, a shown estimated early)
	return Latency_Sample{
		wait = ms(d.input, d.read), work = ms(d.read, d.call), present = ms(d.call, d.presented),
		scan = ms(d.presented, d.shown), total = ms(d.input, d.shown),
	}, true
}
