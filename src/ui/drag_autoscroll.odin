package ui

// A selecting drag held near or past an edge of a scroll view scrolls that view toward the pointer, faster the farther
// the pointer is (src/md/features/drag-autoscroll.md). A widget marks its drag in each build while the drag is held.
// The mark lives one build: the release, a lost capture or a box that goes ends it, and nothing is left to clear.
// The speed is the middle-click curve (autoscroll_axis_speed), so the two autoscrolls feel the same.

// The speed curve of a selecting drag, in logical pixels: autoscroll_axis_speed of the distance past the inner edge of
// the band, with no dead zone. 600 px/s as soon as the pointer is in the band (a maximised window leaves the pointer no
// room past the edge: the band alone must scroll fast), about 830 px/s at the view's edge, 3000 px/s 100 px past it,
// 8000 px/s from 170 px past it.
DRAG_AUTOSCROLL :: Autoscroll_Settings{
	dead_zone = 0,
	min_speed = 600,
	max_speed = 8000,
	full_dist = 200,
	doubling  = 50,
}

// The band inside each edge of a view where a selecting drag starts to scroll it, in ems of the dragged box's font.
DRAG_AUTOSCROLL_BAND_EM :: 2

// An offset this close to an end of its range is at that end: the next view out takes the drag.
@(private = "file") DRAG_AUTOSCROLL_END_EPS :: 0.5

// This build's selecting drag: the box that holds it and the axes the views around it may scroll on.
@(private)
Drag_Autoscroll :: struct {
	key:   Key,
	build: u64,           // the build that marked it: a mark of an older build is no drag
	axes:  [Axis]bool,    // false: the drag does not follow that axis, or the box scrolled itself on it
}

// Marks the drag held on box `key` as selecting. Near or past an edge of the innermost scroll view around the box (the
// box included) that can still scroll that way, that view scrolls toward the pointer. Call it in each build while the
// drag is held; stop calling it when the drag ends. `axes`: the directions the selection follows (.X for one line).
//
//   if sig.dragging { ui.drag_autoscroll(sig.box.key) }
drag_autoscroll :: proc(key: Key, axes := Autoscroll_Axes.Both) {
	drag_autoscroll_mark(gs(), key, drag_axes(axes))
}

// For a box that scrolls itself (.Scroll_Self, an editor): its selecting drag moves its own `scroll` (within 0 ..
// `limit`), over its text `view` (window coordinates; the part on screen counts). An axis its own scroll cannot move
// that way goes to the views around it, as with drag_autoscroll. Call it in each build while the drag is held, before
// the pointer becomes a place in the text. Returns whether its scroll moved.
drag_autoscroll_own :: proc(key: Key, view: Rect, scroll: ^[2]f32, limit: [2]f32, axes := Autoscroll_Axes.Both) -> (moved: bool) {
	s := gs()
	b := s.boxes[key] if key != 0 else nil
	if b == nil || autoscroll_active(&s.auto) { return false }
	shown := rect_clip(view, visible_rect(b))
	band := drag_band(b)
	cfg := drag_frame_settings(s)
	want := drag_axes(axes)
	rest: [Axis]bool
	for axis in Axis {
		if !want[axis] { continue }
		i := int(axis)
		top := max(limit[i], 0)
		speed := drag_autoscroll_speed(s.mouse[i], shown.min[i], shown.max[i], band, cfg)
		if speed != 0 && drag_can_scroll(scroll[i], top, speed) {
			scroll[i] = clamp(scroll[i] + speed * s.dt, 0, top)
			moved = true
			continue
		}
		rest[axis] = true
	}
	drag_autoscroll_mark(s, key, rest)
	if moved { s.anim_busy = true }
	return
}

// The speed, in pixels per second, that a selecting drag asks of a view on one axis: the pointer at `p`, the view's
// visible span `lo` .. `hi`, a band `band` wide inside each edge. Negative toward the start; 0 between the bands. A view
// smaller than two bands gives each band half of it. Pure.
drag_autoscroll_speed :: proc(p, lo, hi, band: f32, cfg := DRAG_AUTOSCROLL) -> f32 {
	if hi <= lo { return 0 }
	w := clamp(band, 0, (hi - lo) * 0.5)
	if p < lo + w { return -autoscroll_axis_speed(lo + w - p, cfg) }
	if p > hi - w { return autoscroll_axis_speed(p - (hi - w), cfg) }
	return 0
}

// The point `p` (window coordinates) kept inside the part of `view` that is on screen around box `b`: where a selecting
// drag puts the moving end, so it stays on what is shown while the view scrolls.
@(private)
drag_point_in :: proc(b: ^Box, view: Rect, p: Vec2) -> Vec2 {
	r := rect_clip(view, visible_rect(b))
	if r.max.x <= r.min.x || r.max.y <= r.min.y { return p }
	return {clamp(p.x, r.min.x, r.max.x - DRAG_AUTOSCROLL_END_EPS), clamp(p.y, r.min.y, r.max.y - DRAG_AUTOSCROLL_END_EPS)}
}

// update_animations, after the middle-click autoscroll and before the ease of the offsets: the mark of this build
// moves the target of one view per axis.
@(private)
drag_autoscroll_apply :: proc(s: ^State) {
	d := s.drag_auto
	s.drag_auto = {}
	if d.key == 0 || d.build != s.build_index || autoscroll_active(&s.auto) { return }
	b := s.boxes[d.key]
	if b == nil || b.last_build != s.build_index { return }
	band := drag_band(b)
	cfg := drag_frame_settings(s)
	moved := false
	for axis in Axis {
		if !d.axes[axis] { continue }
		i := int(axis)
		flag := axis == .X ? Box_Flag.View_Scroll_X : Box_Flag.View_Scroll_Y
		for v := b; v != nil; v = v.parent {
			if flag not_in v.flags { continue }
			r := visible_rect(v)
			speed := drag_autoscroll_speed(s.mouse[i], r.min[i], r.max[i], band, cfg)
			limit := view_limit(v, axis)
			if speed == 0 || !drag_can_scroll(v.view_target[i], limit, speed) { continue }
			v.view_target[i] = clamp(clamp(v.view_target[i], 0, limit) + speed * s.dt, 0, limit)
			moved = true
			break
		}
	}
	if moved { s.anim_busy = true }
}

// Merges a mark into this build's (two calls of one box add their axes; a later box replaces an earlier one).
@(private)
drag_autoscroll_mark :: proc(s: ^State, key: Key, axes: [Axis]bool) {
	if key == 0 || (!axes[.X] && !axes[.Y]) { return }
	d := &s.drag_auto
	if d.build != s.build_index || d.key != key { d^ = {key = key, build = s.build_index} }
	for axis in Axis { if axes[axis] { d.axes[axis] = true } }
}

@(private = "file")
drag_axes :: proc(axes: Autoscroll_Axes) -> (out: [Axis]bool) {
	out[.X] = axes != .Y
	out[.Y] = axes != .X
	return
}

// Whether an offset `at` within 0 .. `limit` can still move toward the sign of `speed`.
@(private)
drag_can_scroll :: proc(at, limit, speed: f32) -> bool {
	if speed < 0 { return at > DRAG_AUTOSCROLL_END_EPS }
	return at < limit - DRAG_AUTOSCROLL_END_EPS
}

// The band of a box's drag, in frame pixels (its font size is scaled already).
@(private = "file")
drag_band :: proc(b: ^Box) -> f32 { return max(b.font_size, 1) * DRAG_AUTOSCROLL_BAND_EM }

// DRAG_AUTOSCROLL in frame pixels.
@(private = "file")
drag_frame_settings :: proc(s: ^State) -> Autoscroll_Settings {
	cfg := DRAG_AUTOSCROLL
	cfg.min_speed *= s.scale
	cfg.max_speed *= s.scale
	cfg.full_dist *= s.scale
	cfg.doubling *= s.scale
	return cfg
}

@(private = "file")
rect_clip :: proc(a, b: Rect) -> Rect {
	return {{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}, {min(a.max.x, b.max.x), min(a.max.y, b.max.y)}}
}
