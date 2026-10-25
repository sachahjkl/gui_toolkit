package render

import "core:testing"
import "core:time"

// The latency probe's arithmetic (latency.odin). No clocks: instants are made up, nothing here asserts on a duration of the machine.

@(private = "file")
at :: proc(ms: f64) -> time.Tick { return time.Tick{_nsec = i64(ms * 1e6) + 1} }

@(test)
latency_sample_splits_a_frame_into_its_stages :: proc(t: ^testing.T) {
	d := Displayed_Frame{input = at(100), read = at(101), drawn = at(101.5), call = at(102), presented = at(103), shown = at(120)}
	s, ok := latency_sample_of(d)
	testing.expect(t, ok)
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-3 }
	testing.expect(t, near(s.wait, 1) && near(s.work, 1) && near(s.present, 1) && near(s.scan, 17) && near(s.total, 20), "stages")
	testing.expect(t, near(s.wait + s.work + s.present + s.scan, s.total), "the stages add up to the total")
}

@(test)
latency_sample_ignores_frames_without_input :: proc(t: ^testing.T) {
	d := Displayed_Frame{read = at(1), call = at(2), presented = at(3), shown = at(10)}
	_, ok := latency_sample_of(d)
	testing.expect(t, !ok, "no input: not a sample")
	d.input = at(0.5)
	d.read = {}
	_, ok = latency_sample_of(d)
	testing.expect(t, !ok, "an instant missing: not a sample")
	d.read = at(1)
	d.shown = at(0.2)
	_, ok = latency_sample_of(d)
	testing.expect(t, !ok, "shown before the input: not a sample")
}

@(test)
latency_summary_percentiles :: proc(t: ^testing.T) {
	samples := make([]Latency_Sample, 100, context.temp_allocator)
	for &s, i in samples { s = Latency_Sample{total = f32(i + 1), wait = 1} }   // 1 .. 100
	sum := latency_summarize(samples)
	testing.expect_value(t, sum.samples, 100)
	testing.expect_value(t, sum.total.p50, 50)
	testing.expect_value(t, sum.total.p95, 95)
	testing.expect_value(t, sum.total.max, 100)
	testing.expect(t, abs(sum.total.mean - 50.5) < 1e-3)
	testing.expect_value(t, sum.wait.p50, 1)
	testing.expect_value(t, latency_summarize(nil).samples, 0)
}

// Nothing is recorded unless the probe is on; the ring keeps the latest samples; a reset empties it.
@(test)
latency_probe_records_only_when_on :: proc(t: ^testing.T) {
	p: Latency_Probe
	defer delete(p.samples)
	d := Displayed_Frame{input = at(0.5), read = at(1), call = at(2), presented = at(3), shown = at(10)}
	latency_probe_add(&p, d)
	testing.expect_value(t, len(p.samples), 0)
	p.on = true
	for _ in 0 ..< LATENCY_RING + 10 { latency_probe_add(&p, d) }
	testing.expect_value(t, len(p.samples), LATENCY_RING)
	testing.expect_value(t, p.frames, u64(LATENCY_RING + 10))
	d.input = {}
	latency_probe_add(&p, d)
	testing.expect_value(t, p.with_input, u64(LATENCY_RING + 10))
}
