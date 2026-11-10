package ui

// Values over time: a ring of the last N values (Value_History), the graph of one or more of them (line_graph: each
// series an area filled from its line down, fading to the bottom, under its line; grid lines and a frame), the same
// small and bare (sparkline), and a flat bar of how full something is (meter_bar).
//
//   cpu: ui.Value_History(60)
//   ui.value_history_push(&cpu, percent)                       // once per sample
//   ui.next({width = ui.fill(), height = ui.px(em * 10)})
//   ui.line_graph("###cpu", {{ui.value_history_values(&cpu), ui.color("accent")}}, {top = 100, points = 60, grid = true})
//
// The colours: each series its own; the grid and the frame the theme's border. Nothing here asks for frames: a graph
// changes when the app pushes a value.

import "core:math"
import "../draw"

// The last N values pushed, oldest first.
Value_History :: struct($N: int) {
	values: [N]f32,
	head:   int,   // where the next value goes
	count:  int,
}

value_history_push :: proc(h: ^Value_History($N), v: f32) {
	h.values[h.head] = v
	h.head = (h.head + 1) % N
	h.count = min(h.count + 1, N)
}

// The `i`th value kept, oldest first (0 ..< count).
value_history_at :: proc(h: ^Value_History($N), i: int) -> f32 {
	return h.values[(h.head - h.count + i + N * 2) % N]
}

// The newest value, 0 when there is none.
value_history_last :: proc(h: ^Value_History($N)) -> f32 { return h.count > 0 ? value_history_at(h, h.count - 1) : 0 }

value_history_max :: proc(h: ^Value_History($N)) -> f32 {
	m: f32
	for i in 0 ..< h.count { m = max(m, value_history_at(h, i)) }
	return m
}

value_history_clear :: proc(h: ^Value_History($N)) { h.head, h.count = 0, 0 }

// The values kept, oldest first, in a copy (what a graph's series takes).
value_history_values :: proc(h: ^Value_History($N), allocator := context.temp_allocator) -> []f32 {
	out := make([]f32, h.count, allocator)
	for i in 0 ..< h.count { out[i] = value_history_at(h, i) }
	return out
}

// A round value at or above `v`: 1, 2 or 5 times a power of ten, and at least `floor` (rounded the same way). The
// top of a graph of rates (bytes per second: a floor of 1 MB/s keeps a disk at rest from filling the graph with noise).
graph_top :: proc(v: f32, floor: f32 = 0) -> f32 {
	x := max(v, floor)
	if x <= 0 { return 1 }
	p := math.pow(10, math.floor(math.log10(x)))
	for k in ([]f32{1, 2, 5}) { if x <= k * p * (1 + 1e-6) { return k * p } }
	return 10 * p
}

// One series of a graph: its values oldest first (value_history_values) and its colour.
Line_Series :: struct {
	values: []f32,
	color:  Color,
}

Line_Graph_Opts :: struct {
	top:     f32,    // the value at the top; 0: graph_top of the largest value shown, at least `floor`
	floor:   f32,    // what the top is at least when it is found (0: 1)
	points:  int,    // values across the width, the newest at the right edge (0: the longest series'): a history
	                 // not full yet starts at the right
	grid:    bool,   // grid lines and a frame
	columns: int,    // vertical spaces of the grid (0: 10)
	rows:    int,    // horizontal spaces (0: 4)
}

// The graph's opacities: of the area under its line at the line and at the bottom, of the grid against the border.
@(private = "file") LINE_GRAPH_FILL_TOP :: 0.32
@(private = "file") LINE_GRAPH_FILL_BOTTOM :: 0.06
@(private = "file") LINE_GRAPH_GRID_ALPHA :: 0.55
@(private = "file") LINE_GRAPH_COLUMNS :: 10
@(private = "file") LINE_GRAPH_ROWS :: 4
// The line's width, in logical pixels: with a grid, and in a sparkline.
@(private = "file") LINE_GRAPH_LINE_PX :: 1.5
@(private = "file") SPARKLINE_LINE_PX :: 1.2
// A graph's series at most.
@(private = "file") LINE_GRAPH_SERIES :: 8

@(private = "file")
Line_Graph_Draw :: struct {
	series: [LINE_GRAPH_SERIES]Line_Series,   // values copied to the frame's memory
	count:  int,
	opts:   Line_Graph_Opts,
	line:   Color,   // the grid's and the frame's
	scale:  f32,
}

// The top a graph of `series` with `opts` shows (what its caption says).
line_graph_top :: proc(series: []Line_Series, opts: Line_Graph_Opts) -> f32 {
	if opts.top > 0 { return opts.top }
	m: f32
	for s in series { for v in s.values { m = max(m, v) } }
	return graph_top(m, opts.floor > 0 ? opts.floor : 1)
}

// A graph in a box of the size `next` gives it.
line_graph :: proc(id: string, series: []Line_Series, opts: Line_Graph_Opts) -> ^Box {
	d := frame_new(Line_Graph_Draw)
	d.count = min(len(series), LINE_GRAPH_SERIES)
	for s, i in series[:d.count] {
		values := make([]f32, len(s.values), frame_allocator())
		copy(values, s.values)
		d.series[i] = {values, s.color}
	}
	d.opts = opts
	d.opts.top = line_graph_top(series, opts)
	if d.opts.points <= 0 { for s in series { d.opts.points = max(d.opts.points, len(s.values)) } }
	d.line = color("border")
	d.scale = scale()
	return custom(id, line_graph_draw, d)
}

// A small graph with no grid nor frame (beside a device's name in a list).
sparkline :: proc(id: string, series: []Line_Series, top: f32 = 0, points := 0, floor: f32 = 0) -> ^Box {
	return line_graph(id, series, {top = top, points = points, floor = floor})
}

@(private = "file")
line_graph_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Line_Graph_Draw)(user)
	r := b.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w <= 2 || h <= 2 { return }
	px := max(1, math.round(d.scale))
	if d.opts.grid {
		grid := d.line
		grid.a *= LINE_GRAPH_GRID_ALPHA
		cols := d.opts.columns > 0 ? d.opts.columns : LINE_GRAPH_COLUMNS
		rows := d.opts.rows > 0 ? d.opts.rows : LINE_GRAPH_ROWS
		for i in 1 ..< cols {
			x := math.round(r.min.x + w * f32(i) / f32(cols))
			draw.rect(dc, {{x, r.min.y}, {x + px, r.max.y}}, grid)
		}
		for i in 1 ..< rows {
			y := math.round(r.min.y + h * f32(i) / f32(rows))
			draw.rect(dc, {{r.min.x, y}, {r.max.x, y + px}}, grid)
		}
	}
	step := w / f32(max(d.opts.points - 1, 1))
	points := make([dynamic]Vec2, 0, d.opts.points + 2, context.temp_allocator)
	for s in d.series[:d.count] {
		n := min(len(s.values), d.opts.points)
		if n < 2 { continue }
		clear(&points)
		values := s.values[len(s.values) - n:]
		for v, i in values {
			t := clamp(v / max(d.opts.top, 1e-6), 0, 1)
			append(&points, Vec2{r.max.x - f32(n - 1 - i) * step, r.max.y - t * (h - px)})
		}
		// the area: the line, then down to the bottom; a gradient from under the line to the bottom
		line_len := len(points)
		append(&points, Vec2{points[line_len - 1].x, r.max.y}, Vec2{points[0].x, r.max.y})
		top_c, bottom_c := s.color, s.color
		top_c.a *= LINE_GRAPH_FILL_TOP
		bottom_c.a *= LINE_GRAPH_FILL_BOTTOM
		draw.push_clip_polygon(dc, points[:])
		draw.rect_corners(dc, {{points[0].x, r.min.y}, r.max}, {top_c, bottom_c, top_c, bottom_c}, {})
		draw.pop_clip(dc)
		draw.polyline(dc, points[:line_len], (d.opts.grid ? LINE_GRAPH_LINE_PX : SPARKLINE_LINE_PX) * d.scale, s.color)
	}
	if d.opts.grid { draw.rect(dc, r, d.line, border = px) }
}

////////////////////////////////
// Meter bar

@(private = "file")
Meter_Draw :: struct { used: f32, bar, track: Color }

@(private = "file")
meter_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Meter_Draw)(user)
	r := b.rect
	draw.rect(dc, r, d.track)
	draw.rect(dc, {r.min, {r.min.x + (r.max.x - r.min.x) * clamp(d.used, 0, 1), r.max.y}}, d.bar)
}

// A flat bar of how full something is (`used` 0..1): the theme's accent on its border colour; past `alert` (0..1) the
// colour of the "bad" tag. No animation: it shows the last sample. The size comes from `next`.
meter_bar :: proc(id: string, used: f32, alert: f32 = 1) -> ^Box {
	d := frame_new(Meter_Draw)
	full: Color
	if tags("bad") { full = color("text") }
	d^ = {used, used > alert ? full : color("accent"), color("border")}
	b := custom(id, meter_draw, d)
	a11y_default(b, {role = .Progress_Indicator, numeric = f64(clamp(used, 0, 1) * 100), min = 0, max = 100, read_only = true})
	return b
}
