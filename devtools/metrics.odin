package devtools

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "../render"
import "../ui"

// Toolkit.metrics: what the frames cost, in numbers a script can compare. "It lags" becomes a figure, without a special
// build. The time between frames counts rests too: a program at rest draws nothing, so frameMs says how fast it was
// drawing only while it was kept busy; buildMs and layoutMs are the work whatever the pace. The latency input -> screen
// needs a build with -define:RENDER_PROBE=true (the probe writes in the present path): null otherwise.

@(private)
METRIC_RING :: 240

@(private)
Metric_Sample :: struct {
	frame, build, layout, total: f32,
	at:          f64,   // ui.now_ms, when the frame after this build began
	build_index: u64,
}

// Each frame: the last build's numbers, once.
@(private)
metrics_sample :: proc(srv: ^Server, s: ^ui.State) {
	if s.build_index == srv.sample_build { return }
	srv.sample_build = s.build_index
	now := time.tick_now()
	m := ui.build_metrics(s)
	frame := srv.sample_at != {} ? f32(time.duration_milliseconds(time.tick_diff(srv.sample_at, now))) : 0
	srv.sample_at = now
	srv.samples[srv.sampled % METRIC_RING] = {frame, f32(m.build_ms), f32(m.layout_ms), f32(m.total_ms), ui.now_ms(), s.build_index}
	srv.sampled += 1
}

@(private)
metrics_write :: proc(sb: ^strings.Builder, srv: ^Server, s: ^ui.State, r: ^render.Renderer, p: json.Object) {
	n := min(srv.sampled, METRIC_RING)
	stat :: proc(sb: ^strings.Builder, name: string, samples: []Metric_Sample, field: int) {
		v := make([]f32, len(samples), context.temp_allocator)
		for x, i in samples {
			switch field {
			case 0: v[i] = x.frame
			case 1: v[i] = x.build
			case 2: v[i] = x.layout
			case 3: v[i] = x.total
			}
		}
		slice.sort(v)
		at :: proc(v: []f32, q: f32) -> f32 { return len(v) > 0 ? v[min(int(f32(len(v)) * q), len(v) - 1)] : 0 }
		fmt.sbprintf(sb, `,"%s":{{"p50":%.2f,"p95":%.2f,"max":%.2f}}`, name, at(v, 0.5), at(v, 0.95), at(v, 1))
	}
	nodes, ax_ms := ui.a11y_cost(s)
	m := ui.build_metrics(s)
	fmt.sbprintf(sb, `{{"build":%d,"frames":%d,"boxes":%d,"lazyBuilt":%d,"animating":%v,"axNodes":%d,"axMs":%.2f`, s.build_index, n, ui.boxes_built(s), m.lazy_built, ui.needs_frame(s), nodes, ax_ms)
	stat(sb, "frameMs", srv.samples[:n], 0)
	stat(sb, "buildMs", srv.samples[:n], 1)
	stat(sb, "layoutMs", srv.samples[:n], 2)
	stat(sb, "totalMs", srv.samples[:n], 3)
	when render.RENDER_PROBE {
		if r != nil {
			if !render.latency_probe_on(r) { render.set_latency_probe(r, true) }   // (from the first asking on)
			l := render.latency_summary(r)
			fmt.sbprintf(sb, `,"latencyMs":{{"samples":%d,"p50":%.2f,"p95":%.2f,"max":%.2f}}`, l.samples, l.total.p50, l.total.p95, l.total.max)
		}
	} else {
		strings.write_string(sb, `,"latencyMs":null`)
	}
	strings.write_string(sb, "}")
	if bool_of(p["reset"]) {
		srv.sampled = 0
		srv.sample_at = {}
		when render.RENDER_PROBE { if r != nil { render.latency_reset(r) } }
	}
}

// Toolkit.frames {after?}: the frames still in the ring, one by one, after build `after`; `now` on the same clock as their
// `t` and the recorder's. A timeline pulls these while it records: the ring holds a few seconds of a busy program.
@(private)
frames_write :: proc(sb: ^strings.Builder, srv: ^Server, p: json.Object) {
	after := u64(num(p["after"]))
	fmt.sbprintf(sb, `{{"now":%.3f,"frames":[`, ui.now_ms())
	first := true
	for i in max(srv.sampled - METRIC_RING, 0) ..< srv.sampled {
		x := srv.samples[i % METRIC_RING]
		if x.build_index <= after { continue }
		if !first { strings.write_byte(sb, ',') }
		first = false
		fmt.sbprintf(sb, `{{"build":%d,"t":%.3f,"frameMs":%.3f,"buildMs":%.3f,"layoutMs":%.3f,"totalMs":%.3f}}`, x.build_index, x.at, x.frame, x.build, x.layout, x.total)
	}
	strings.write_string(sb, "]}")
}
