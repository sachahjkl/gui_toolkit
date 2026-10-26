package ui

// Status bars and quick performance views: a bar along the bottom of a window with compact items, a history of
// per-frame samples (several stacked series: the phases of a frame), a graph of that history with a budget line and
// the sample under the pointer, key / value rows for detail panels, and a popover anchored to a widget.
//
//   if ui.status_bar("###status") {
//       if ui.status_fill("###left") { ui.status_item("Ready###state") }
//       res := ui.frame_graph("###graph", &history, {colors = colors[:], budget = 16.7})
//       if res.hovered >= 0 { ... ui.history_at(&history, res.hovered) ... }
//   }
//
// Nothing here asks for frames: a graph changes when the app pushes a sample, which it does when it draws a frame.

import "core:fmt"
import "core:math"
import "core:slice"
import "../draw"

////////////////////////////////
// Sample history

// Series a sample can stack (the phases of a frame, for instance).
HISTORY_SERIES :: 8

History_Sample :: struct {
	v:    [HISTORY_SERIES]f32,   // one value per series (milliseconds for frame phases); the bar is their sum
	t_ms: f64,                   // when it was taken (any monotonic clock, in ms): rates are counted on it
	tag:  u64,                   // the app's own (a frame number, to complete a sample later: GPU times arrive late)
}

// A ring of the most recent samples. Index 0 is the oldest kept, `history_len - 1` the newest.
Frame_History :: struct {
	buf:    []History_Sample,
	head:   int,   // where the next sample goes
	count:  int,
	series: int,   // series in use (<= HISTORY_SERIES)
}

history_init :: proc(h: ^Frame_History, capacity: int, series: int, allocator := context.allocator) {
	h.buf = make([]History_Sample, max(capacity, 1), allocator)
	h.head, h.count = 0, 0
	h.series = clamp(series, 1, HISTORY_SERIES)
}

history_destroy :: proc(h: ^Frame_History, allocator := context.allocator) {
	delete(h.buf, allocator)
	h^ = {}
}

history_capacity :: proc(h: ^Frame_History) -> int { return len(h.buf) }
history_len :: proc(h: ^Frame_History) -> int { return h.count }
history_clear :: proc(h: ^Frame_History) { h.head, h.count = 0, 0 }

// Changes the capacity, keeping the newest samples that fit.
history_resize :: proc(h: ^Frame_History, capacity: int, allocator := context.allocator) {
	n := max(capacity, 1)
	if n == len(h.buf) { return }
	nb := make([]History_Sample, n, allocator)
	keep := min(h.count, n)
	for i in 0 ..< keep { nb[i] = history_at(h, h.count - keep + i)^ }
	delete(h.buf, allocator)
	h.buf = nb
	h.count = keep
	h.head = keep % n
}

// Adds a sample (the oldest goes when the ring is full) and returns it, to be filled in.
history_push :: proc(h: ^Frame_History, t_ms: f64, tag: u64 = 0) -> ^History_Sample {
	if len(h.buf) == 0 { return nil }
	s := &h.buf[h.head]
	s^ = {t_ms = t_ms, tag = tag}
	h.head = (h.head + 1) % len(h.buf)
	h.count = min(h.count + 1, len(h.buf))
	return s
}

// Sample `i` (0 = oldest kept); nil outside the history.
history_at :: proc(h: ^Frame_History, i: int) -> ^History_Sample {
	if i < 0 || i >= h.count { return nil }
	return &h.buf[(h.head - h.count + i + len(h.buf)) % len(h.buf)]
}

history_last :: proc(h: ^Frame_History) -> ^History_Sample { return history_at(h, h.count - 1) }

// The most recent sample with this tag, looking back at most `within` samples (nil: none).
history_find_tag :: proc(h: ^Frame_History, tag: u64, within := 16) -> ^History_Sample {
	for k in 0 ..< min(within, h.count) {
		s := history_at(h, h.count - 1 - k)
		if s.tag == tag { return s }
	}
	return nil
}

sample_total :: proc(s: ^History_Sample, series: int) -> f32 {
	t: f32
	for i in 0 ..< clamp(series, 0, HISTORY_SERIES) { t += s.v[i] }
	return t
}

// Aggregates of a history, over its samples taken at or after `since_ms` (0: all of them).
History_Stats :: struct {
	n:              int,
	mean, min, max: f32,                  // of the totals
	p50, p95, p99:  f32,
	over:           int,                  // totals above `budget`
	series_mean:    [HISTORY_SERIES]f32,
	series_max:     [HISTORY_SERIES]f32,
	span_ms:        f64,                  // newest t_ms - oldest t_ms of the samples counted
}

history_stats :: proc(h: ^Frame_History, since_ms: f64 = 0, budget: f32 = 0) -> (st: History_Stats) {
	totals := make([dynamic]f32, 0, h.count, context.temp_allocator)
	first, last: f64
	for i in 0 ..< h.count {
		s := history_at(h, i)
		if s.t_ms < since_ms { continue }
		if st.n == 0 { first = s.t_ms }
		last = s.t_ms
		t := sample_total(s, h.series)
		append(&totals, t)
		st.n += 1
		st.mean += t
		if budget > 0 && t > budget { st.over += 1 }
		for k in 0 ..< h.series {
			st.series_mean[k] += s.v[k]
			st.series_max[k] = max(st.series_max[k], s.v[k])
		}
	}
	if st.n == 0 { return }
	st.span_ms = last - first
	st.mean /= f32(st.n)
	for k in 0 ..< h.series { st.series_mean[k] /= f32(st.n) }
	slice.sort(totals[:])
	st.min, st.max = totals[0], totals[st.n - 1]
	pick :: proc(v: []f32, q: f32) -> f32 { return v[clamp(int(math.ceil(q * f32(len(v)))) - 1, 0, len(v) - 1)] }
	st.p50, st.p95, st.p99 = pick(totals[:], 0.5), pick(totals[:], 0.95), pick(totals[:], 0.99)
	return
}

// Samples per second over the `window_ms` before `now_ms` (frames per second for a history of frames).
history_rate :: proc(h: ^Frame_History, now_ms: f64, window_ms: f64 = 1000) -> f32 {
	if window_ms <= 0 { return 0 }
	n := 0
	for i := h.count - 1; i >= 0; i -= 1 {
		if history_at(h, i).t_ms < now_ms - window_ms { break }
		n += 1
	}
	return f32(f64(n) * 1000 / window_ms)
}

////////////////////////////////
// Frame graph

// What `frame_graph` draws. Lengths are logical pixels (scaled like every other size), values in the samples' unit.
Frame_Graph_Opts :: struct {
	colors:    []Color,   // per series, bottom first (missing: the theme's accent)
	series:    int,       // series stacked (0: the history's); more than the history's draws values it does not count
	                      // (a GPU time over the CPU phases a history's statistics are about)
	bars:      int,       // bars shown (0: the history's capacity); the newest is at the right edge
	budget:    f32,       // a dashed line at this value (0: none): the frame period, 1000 / refresh rate (5.56 ms at 180 Hz)
	scale:     f32,       // the graph's top is at least this value (0: the budget, else the tallest bar)
	max_scale: f32,       // and at most this one: taller bars are cut and get a cap mark (0: no limit)
	warn, bad: f32,       // totals (of the history's series) above these get a cap mark in the theme's warn / bad colour
	                      // (0: none)
	highlight: Maybe(int),   // history index drawn highlighted, e.g. the sample a detail panel shows
}

Frame_Graph_Result :: struct {
	using sig: Signal,
	hovered:   int,       // history index of the bar under the pointer (-1: none)
}

@(private)
Graph_Draw :: struct {
	h:        Frame_History,   // a view: the samples are drawn this frame, after the build
	opts:     Frame_Graph_Opts,
	colors:   [HISTORY_SERIES]Color,
	track, budget_c, warn_c, bad_c, hover_c: Color,
	hovered:  int,
	scale:    f32,
}

// Layout of the bars of a graph box: how many slots, how wide, and the history index in slot 0.
@(private)
graph_slots :: proc(h: ^Frame_History, opts: Frame_Graph_Opts, width: f32) -> (slots: int, w: f32, first: int) {
	slots = opts.bars > 0 ? opts.bars : max(history_capacity(h), 1)
	w = width / f32(slots)
	first = history_len(h) - slots   // may be negative: the left slots are empty until the history fills
	return
}

// Height the graph's top stands for: at least `scale` (else the budget), enough for most bars shown (90 % of them
// with some room); a rare spike far above them is cut and marked rather than flattening every other bar. At most
// `max_scale`.
graph_scale :: proc(h: ^Frame_History, opts: Frame_Graph_Opts) -> f32 {
	top := opts.scale > 0 ? opts.scale : opts.budget
	n := opts.bars > 0 ? min(opts.bars, h.count) : h.count
	series := opts.series > 0 ? opts.series : h.series
	if n > 0 {
		totals := make([]f32, n, context.temp_allocator)
		for k in 0 ..< n { totals[k] = sample_total(history_at(h, h.count - n + k), series) }
		slice.sort(totals)
		tallest := totals[n - 1]
		most := totals[clamp(int(math.ceil(0.9 * f32(n))) - 1, 0, n - 1)] * 1.25
		top = max(top, tallest <= most * 1.5 ? tallest * 1.08 : most)
	}
	if opts.max_scale > 0 { top = min(top, opts.max_scale) }
	return top > 0 ? top : 1
}

// A bar graph of `h`: one stacked bar per sample, newest at the right; the size comes from the style (`next`).
// Clickable: the result says which sample is under the pointer, and whether the graph was clicked.
frame_graph :: proc(id: string, h: ^Frame_History, opts: Frame_Graph_Opts) -> (res: Frame_Graph_Result) {
	b := build_box({.Clickable, .Draw_Hot_Effects}, id)
	b.cursor = .Hand
	res.sig = signal(b)
	res.hovered = -1
	if res.hovering {
		slots, w, first := graph_slots(h, opts, b.rect.max.x - b.rect.min.x)
		if w > 0 {
			k := int(res.mouse.x / w)
			if k >= 0 && k < slots && first + k >= 0 && first + k < h.count { res.hovered = first + k }
		}
	}
	d := frame_new(Graph_Draw)
	d.h, d.opts, d.hovered = h^, opts, res.hovered
	d.opts.colors = nil   // copied below: the caller's slice may not outlive the build
	d.scale = graph_scale(h, opts)
	for i in 0 ..< HISTORY_SERIES { d.colors[i] = i < len(opts.colors) ? opts.colors[i] : color("accent") }
	d.track = color("track")
	d.budget_c = color("weak text")
	if tags("warn") { d.warn_c = color("text") }
	if tags("bad") { d.bad_c = color("text") }
	d.hover_c = color("text")
	b.custom = graph_draw
	b.custom_user = d
	return
}

@(private)
graph_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Graph_Draw)(user)
	h := &d.h
	r := b.rect
	sc := scale()
	draw.rect(dc, r, tuned(Color{d.track.r, d.track.g, d.track.b, d.track.a * 0.55}), rad(b.font_size * 0.2))
	height := r.max.y - r.min.y
	slots, w, first := graph_slots(h, d.opts, r.max.x - r.min.x)
	gap: f32 = w >= 3 * sc ? max(1, math.floor(sc)) : 0
	y_of :: proc(v, top, height: f32, bottom: f32) -> f32 { return bottom - clamp(v / top, 0, 1) * height }
	cap_h := max(1, math.round(1.5 * sc))
	for k in 0 ..< slots {
		i := first + k
		if i < 0 || i >= h.count { continue }
		s := history_at(h, i)
		x0 := math.round(r.min.x + f32(k) * w)
		x1 := math.round(r.min.x + f32(k + 1) * w) - gap
		if x1 <= x0 { x1 = x0 + 1 }
		acc, counted: f32
		lit := i == d.hovered
		if hl, ok := d.opts.highlight.?; ok && hl == i { lit = true }
		for c in 0 ..< clamp(d.opts.series > 0 ? d.opts.series : h.series, 0, HISTORY_SERIES) {
			v := s.v[c]
			if c < h.series { counted += max(v, 0) }
			if v <= 0 { continue }
			y0 := y_of(acc + v, d.scale, height, r.max.y)
			y1 := y_of(acc, d.scale, height, r.max.y)
			acc += v
			if y1 - y0 < 0.25 { continue }
			col := d.colors[c]
			if lit { col = draw.Color{min(col.r * 1.25 + 0.08, 1), min(col.g * 1.25 + 0.08, 1), min(col.b * 1.25 + 0.08, 1), col.a} }
			draw.rect(dc, {{x0, y0}, {x1, y1}}, col)
		}
		// over a threshold (the history's own series), or past the top: a cap mark
		mark: Color
		if d.opts.bad > 0 && counted > d.opts.bad { mark = d.bad_c } else if d.opts.warn > 0 && counted > d.opts.warn { mark = d.warn_c }
		if acc > d.scale && mark.a == 0 { mark = d.bad_c }
		if mark.a > 0 {
			top := y_of(acc, d.scale, height, r.max.y)
			draw.rect(dc, {{x0, top}, {x1, min(top + cap_h, r.max.y)}}, mark)
		}
		if i == d.hovered {
			draw.rect(dc, {{x0, r.min.y}, {x1, r.max.y}}, tuned(Color{d.hover_c.r, d.hover_c.g, d.hover_c.b, 0.12}))
		}
	}
	// the budget: a dashed line
	if d.opts.budget > 0 && d.opts.budget < d.scale {
		y := math.round(y_of(d.opts.budget, d.scale, height, r.max.y))
		dash, space := 4 * sc, 3 * sc
		lw := max(1, math.round(sc))
		c := d.budget_c
		c.a *= 0.85
		for x := r.min.x; x < r.max.x; x += dash + space {
			draw.rect(dc, {{x, y - lw * 0.5}, {min(x + dash, r.max.x), y + lw * 0.5}}, c)
		}
	}
}

////////////////////////////////
// Status bar

// `if status_bar("###status") { ... }`: a row along the bottom of a window (theme tags "bar"), its text a little
// smaller than the window's. Its items are laid out left to right; `spacer(fill())` pushes the rest to the right.
@(deferred_none = status_bar_end)
status_bar :: proc(id: string, height_em: f32 = 1.9, text_scale: f32 = 0.88) -> bool {
	em := font_size()
	push_tags("bar")
	next({width = fill(), height = px(dense(em * height_em)), radius = 0})
	set_next_axis(.X, .Center)
	bar := build_box({.Draw_Background, .Draw_Side_Top}, id)
	a11y_default(bar, {role = .Status})
	push_parent(bar)
	st := top_style()^
	st.font_size = math.round(em * text_scale)
	append(&g.style_stack, st)
	spacer(px(em * 0.6))
	return true
}

@(private)
status_bar_end :: proc() {
	spacer(px(font_size() * 0.6))
	pop_style()
	pop_parent()
	pop_tags()
}

// `if status_fill("###left") { ... }`: the flexible part of a status bar: takes the room the other items leave, its
// items clipped when they do not fit (a bar's items keep their natural width).
@(deferred_none = pop_parent)
status_fill :: proc(id: string) -> bool {
	next({width = fill(), height = pct(1)})
	set_next_axis(.X, .Center)
	push_parent(build_box({.Clip}, id))
	return true
}

// A compact item of the status bar: text as wide as it needs, or `width` (text too long for it ends with "...").
// `tone`: "", "weak", "good", "warn", "bad". Clickable when `clickable` (the signal says so); `mono`: in the monospace
// font, so digits do not dance as values change.
status_item :: proc(id: string, tone := "weak", mono := false, clickable := false, width: Maybe(Size) = nil) -> Signal {
	em := font_size()
	if tone != "" { push_tags(tone) }
	m := Style_Mod{width = width.? or_else text_size(em * 0.15), height = pct(1), text_pad = em * 0.35}
	if mono { m.font = mono_font() }
	flags := Box_Flags{.Draw_Text}
	if clickable { flags += {.Clickable, .Draw_Hot_Effects}; m.radius = em * 0.3 }
	next(m)
	b := build_box(flags, id)
	if clickable { b.cursor = .Hand }
	if tone != "" { pop_tags() }
	return signal(b)
}

// A thin vertical rule between groups of status items.
status_separator :: proc() {
	em := font_size()
	spacer(px(em * 0.25))
	c := color("border")
	next({width = px(max(1, math.round(scale()))), height = px(em * 1.1), bg = c})
	build_box({.Draw_Background})
	spacer(px(em * 0.25))
}

////////////////////////////////
// Detail rows

// A colour swatch the size of the text (legends of graphs).
swatch :: proc(c: Color, id: string = "") {
	em := font_size()
	next({width = px(math.round(em * 0.75)), height = px(math.round(em * 0.75)), bg = c, radius = em * 0.15})
	if row(.Center, {.Draw_Background}, id) {}
}

// `label .......... value` across `width`: the label weak, the value right-aligned (monospace when `mono`).
// `color` not zero: a swatch before the label (a legend row). `tone`: tags of the value ("", "good", "warn", "bad").
stat_row :: proc(id, label, value: string, width: f32, mono := true, swatch_color := Color{}, tone := "") {
	em := font_size()
	next({width = px(width), height = px(dense(em * 1.55))})
	if row(.Center, {}, fmt.tprintf("###sr_%s", id)) {
		spacer(px(em * 0.9))
		if swatch_color.a > 0 {
			swatch(swatch_color, "###sw")
			spacer(px(em * 0.45))
		}
		if tags("weak") {
			next({width = fill(), height = pct(1), text_pad = 0})
			build_box({.Draw_Text}, fmt.tprintf("%s###l", label))
		}
		if tone != "" { push_tags(tone) }
		m := Style_Mod{width = text_size(0, 1), height = pct(1), text_pad = 0, text_align = .Right}
		if mono { m.font = mono_font() }
		next(m)
		build_box({.Draw_Text, .No_Text_Trunc}, fmt.tprintf("%s###v", value))
		if tone != "" { pop_tags() }
		spacer(px(em * 0.9))
	}
}

// A section title inside a panel: small, weak, with space above.
stat_heading :: proc(id, text: string, width: f32) {
	em := font_size()
	spacer(px(em * 0.35))
	next({width = px(width), height = px(dense(em * 1.6))})
	if row(.Center, {}, fmt.tprintf("###sh_%s", id)) {
		spacer(px(em * 0.9))
		if tags("weak") {
			next({width = fill(), height = pct(1), text_pad = 0, font_size = math.round(em * 0.85)})
			build_box({.Draw_Text}, fmt.tprintf("%s###t", text))
		}
	}
}

////////////////////////////////
// Popover

Popover_Side :: enum u8 { Above, Below }

// `if popover("###stats", anchor_rect, width, .Above) { ... }`: a floating panel next to `anchor` (above or below it,
// on the other side when it does not fit; right-aligned with the anchor when `align_right`), clamped to the window.
// It stays open as long as the app builds it: the app decides when it closes (a toggle, a close button, Escape).
// It takes the clicks that land on it; `popover_rect` tells the app where it is (input it routes itself).
@(deferred_none = popover_end)
popover :: proc(id: string, anchor: Rect, width: f32, side := Popover_Side.Above, align_right := true) -> bool {
	s := g
	em := font_size()
	key := key_from_string(s.root.key, id)
	prev := s.boxes[key]
	size := prev != nil ? prev.size : Vec2{width, em * 12}
	gap := em * 0.35
	x := align_right ? anchor.max.x - size.x : anchor.min.x
	y := side == .Above ? anchor.min.y - gap - size.y : anchor.max.y + gap
	if side == .Above && y < 0 && anchor.max.y + gap + size.y <= s.window_size.y { y = anchor.max.y + gap }
	if side == .Below && y + size.y > s.window_size.y && anchor.min.y - gap - size.y >= 0 { y = anchor.min.y - gap - size.y }
	pos := clamp_popup({x, y}, size, s.window_size)
	push_parent(s.root)
	push_tags("floating")
	push_style_copy()
	set_next_axis(.Y)
	g.next_mod.fixed_x = pos.x
	g.next_mod.fixed_y = pos.y
	g.next_mod.width = px(width)
	g.next_mod.height = children_sum()
	g.next_mod.radius = em * 0.5
	if prev == nil { g.next_mod.transparency = 1; s.anim_busy = true }   // measured on this frame, shown on the next
	p := build_box({.Clickable, .Draw_Background, .Draw_Border, .Draw_Shadow, .Clip}, id)
	p.cursor = .Arrow
	_ = signal(p)
	push_parent(p)
	append(&s.popup_stack, true)
	return true
}

@(private)
popover_end :: proc() { ctx_menu_end() }

// Where the popover `id` was laid out last frame (ok false: it was not built).
popover_rect :: proc(id: string) -> (r: Rect, ok: bool) {
	b := g.boxes[key_from_string(g.root.key, id)]
	if b == nil || b.last_build + 1 < g.build_index { return {}, false }
	return b.rect, true
}
