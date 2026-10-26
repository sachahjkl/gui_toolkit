package ui

// Panes the user resizes and sections the user folds:
//   * splitter: a handle between two panes; dragging it changes the size of one of them (the app keeps the size and
//     persists it), within limits on both sides; a double click puts the default back; with the keyboard focus the
//     arrow keys move it. Resize cursor; nothing is drawn or animated at rest.
//   * accordion: a header with a chevron that folds and unfolds the content under it; the content's height is animated
//     (no frame at rest); Enter / Space on the focused header toggle it. The open state is the app's.

import "core:math"
import "../draw"
import "../platform"

Splitter_Options :: struct {
	default_size: f32,    // a double click (or Enter) puts it back (0: no reset)
	after:        bool,   // the pane sized is after the handle (right of it, below it): dragging towards it shrinks it
	total:        f32,    // the room of both panes, in the units of `size` (0: unknown): the other pane keeps min_other
	min_other:    f32,
	thickness:    f32,    // the grab area across the handle in frame pixels (0: 5 logical pixels)
	unit:         f32,    // frame pixels per unit of `size` (0: the scale: `size` in logical pixels; a pane's room in
	                      // pixels: `size` is a fraction of it)
	step:         f32,    // an arrow key's move in units of `size` (0: 10 logical pixels; Ctrl: a fifth of it)
	no_keyboard:  bool,   // not a Tab stop (a handle the mouse alone moves)
}

Splitter_Result :: struct {
	using sig: Signal, // (dragging: the handle is held)
	changed:   bool,   // `size` changed this frame
	finished:  bool,   // a drag, a reset or a key ended this frame: the moment to persist the size
}

// The limits of a pane's size: its own, and what the other side needs. The smaller limit wins when they cross.
splitter_limits :: proc(min_size, max_size: f32, opts: Splitter_Options) -> (lo, hi: f32) {
	lo, hi = min_size, max_size
	if opts.total > 0 { hi = min(hi, opts.total - opts.min_other) }
	if hi < lo { hi = lo }
	return
}

// A handle along `axis` (.X: a vertical bar between side-by-side panes, .Y: a horizontal bar between stacked panes)
// that resizes the pane whose size is `size` (in logical pixels unless `opts.unit` says otherwise). Its length fills the
// parent unless `next` sets it.
splitter :: proc(id: string, axis: Axis, size: ^f32, min_size, max_size: f32, opts := Splitter_Options{}) -> (res: Splitter_Result) {
	s := g
	unit := opts.unit > 0 ? opts.unit : s.scale
	grab := opts.thickness > 0 ? opts.thickness : math.round(5 * s.scale)
	m := s.has_next ? s.next_mod : Style_Mod{}
	if axis == .X {
		m.width = px(grab)
		if m.height == nil { m.height = fill() }
	} else {
		m.height = px(grab)
		if m.width == nil { m.width = fill() }
	}
	cur := axis == .X ? platform.Cursor.Resize_H : platform.Cursor.Resize_V
	m.cursor = cur
	next(m)
	flags := Box_Flags{.Clickable}
	if !opts.no_keyboard { flags += {.Focusable} }
	b := build_box(flags, id)
	enter := !opts.no_keyboard && s.focus_key == b.key && key_pressed_peek(.Return)   // (signal takes Enter as a click)
	res.sig = signal(b)
	lo, hi := splitter_limits(min_size, max_size, opts)
	before := size^
	if v, ok := a11y_numeric_request(b.key, size^, opts.step > 0 ? opts.step : 10 * s.scale / unit); ok {
		size^ = clamp(v, lo, hi)
		res.finished = true
	}

	if res.sig.pressed { drag_store({size^, 0, 0, 0}) }
	if res.sig.dragging {
		s.cursor_request = cur   // (also when the pointer runs ahead of the handle)
		d := (axis == .X ? res.sig.drag_delta.x : res.sig.drag_delta.y) / unit
		if opts.after { d = -d }
		size^ = clamp(drag_load()[0] + d, lo, hi)
	}
	if res.sig.released { res.finished = true }
	if res.sig.double_clicked && opts.default_size > 0 {
		size^ = clamp(opts.default_size, lo, hi)
		drag_store({size^, 0, 0, 0})   // (the button is still down: a move from here starts at the default)
		res.finished = true
	}
	if res.sig.focused && !opts.no_keyboard {
		step := opts.step > 0 ? opts.step : 10 * s.scale / unit
		dir: f32
		back, fwd: platform.Key = axis == .X ? .Left : .Up, axis == .X ? .Right : .Down
		for mods in ([]platform.Modifiers{{}, {.Ctrl}}) {
			k := .Ctrl in mods ? step / 5 : step
			if key_press(back, mods) { dir -= k }
			if key_press(fwd, mods) { dir += k }
		}
		if opts.after { dir = -dir }
		if dir != 0 { size^ = clamp(size^ + dir, lo, hi); res.finished = true }
		if key_press(.Home) { size^ = lo; res.finished = true }
		if key_press(.End) { size^ = hi; res.finished = true }
		if enter && opts.default_size > 0 { size^ = clamp(opts.default_size, lo, hi); res.finished = true }
	}
	// (a size outside the limits at rest is left alone: the window shrank, the app draws the pane clamped and the user's
	// size comes back when there is room again)
	res.changed = size^ != before

	d := frame_new(Splitter_Draw)
	d.hot = res.sig.hovering || res.dragging || (res.sig.focused && s.focus_visible)
	d.color = d.hot ? color("accent") : color("border")
	d.line = max(math.round(s.scale), 1)
	b.custom, b.custom_user = splitter_draw, d
	// (a bar between side-by-side panes is vertical: its orientation is across `axis`)
	a11y_default(b, {role = .Splitter, numeric = f64(size^), min = f64(lo), max = f64(hi), orientation = axis == .X ? Axis.Y : Axis.X,
		actions = opts.no_keyboard ? {} : {.Increment, .Decrement, .Set_Value}})
	return
}

@(private)
Splitter_Draw :: struct { hot: bool, color: Color, line: f32 }

// A rule along the middle of the handle, twice as thick and in the accent colour while hot, held or focused.
@(private)
splitter_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Splitter_Draw)(user)
	r := b.rect
	th := d.hot ? d.line * 2 : d.line
	if r.max.x - r.min.x < r.max.y - r.min.y {
		x := math.round((r.min.x + r.max.x) * 0.5)
		draw.rect(dc, {{x - th * 0.5, r.min.y}, {x + th * 0.5, r.max.y}}, d.color)
	} else {
		y := math.round((r.min.y + r.max.y) * 0.5)
		draw.rect(dc, {{r.min.x, y - th * 0.5}, {r.max.x, y + th * 0.5}}, d.color)
	}
}

////////////////////////////////
// Accordion

// How fast a section unfolds (halvings per second of the distance left: about 0.2 s).
ACCORDION_RATE :: 28

// `if ui.accordion("###net", "Network", &app.net_open) { ...content... }`: a header that folds the content built in the
// block. The block runs while the section is open or still folding (the content is clipped to the animated height).
@(deferred_out = accordion_end)
accordion :: proc(id: string, title: string, open: ^bool) -> bool {
	s := g
	em := font_size()
	m := s.has_next ? s.next_mod : Style_Mod{}
	if m.width == nil { m.width = fill() }
	m.height = children_sum()
	m.axis = .Y
	next(m)
	outer := build_box({}, id)
	push_parent(outer)

	next({width = fill(), height = px(dense(em * 2.2)), axis = .X, cross = .Center})
	header := build_box({.Clickable, .Focusable, .Draw_Hot_Effects, .Draw_Focus_Ring}, "###accordion_header")
	sig := signal(header)
	if sig.clicked { open^ = !open^ }
	a11y_default(header, {role = .Button, expanded = open^})
	t := anim(key_from_string(outer.key, "t"), open^ ? 1 : 0, ACCORDION_RATE, open^ ? 1 : 0)
	if parent(header) {
		spacer(px(em * 0.5))
		next({width = px(em), height = px(em)})
		cd := frame_new(Chevron_Draw)
		cd.t = t
		cd.color = color("text")
		custom("###chevron", chevron_draw, cd)
		spacer(px(em * 0.5))
		next({width = fill(), height = pct(1)})
		build_box({.Draw_Text}, title)
	}
	if t <= 0 && !open^ { return false }

	// the body: as tall as its content when open and at rest, else that height times the animation
	inner_key := key_from_string(key_from_string(outer.key, "###accordion_body"), "###accordion_inner")
	body_h: Size = children_sum()
	if t < 1 {
		natural: f32 = 0
		if inner := box_from_key(inner_key); inner != nil { natural = inner.size.y }
		body_h = px(math.round(natural * t))
	}
	next({width = fill(), height = body_h, axis = .Y})
	body := build_box({.Clip, .Allow_Overflow_Y}, "###accordion_body")
	push_parent(body)
	next({width = fill(), height = children_sum(), axis = .Y})
	inner := build_box({}, "###accordion_inner")
	push_parent(inner)
	return true
}

accordion_end :: proc(built: bool) {
	if built { pop_parent(); pop_parent() }
	pop_parent()
}

@(private)
Chevron_Draw :: struct { t: f32, color: Color }

// ">" turning to "v" as the section opens (t: 0..1).
@(private)
chevron_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	d := (^Chevron_Draw)(user)
	c := draw.rect_center(b.rect)
	a := (b.rect.max.x - b.rect.min.x) * 0.22
	th := max(math.round(g.scale * 1.5), 1)
	draw.push_transform(dc, draw.affine_around(draw.affine_rotate(d.t * math.PI * 0.5), c))
	bar :: proc(dc: ^draw.Context, p0, p1: Vec2, th: f32, col: Color) {
		mid := (p0 + p1) * 0.5
		v := p1 - p0
		l := math.sqrt(v.x * v.x + v.y * v.y) + th
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.atan2(v.y, v.x)), mid))
		draw.rect(dc, {{mid.x - l * 0.5, mid.y - th * 0.5}, {mid.x + l * 0.5, mid.y + th * 0.5}}, col, th * 0.5)
		draw.pop_transform(dc)
	}
	bar(dc, {c.x - a * 0.5, c.y - a}, {c.x + a * 0.5, c.y}, th, d.color)
	bar(dc, {c.x + a * 0.5, c.y}, {c.x - a * 0.5, c.y + a}, th, d.color)
	draw.pop_transform(dc)
}
