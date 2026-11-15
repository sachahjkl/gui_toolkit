package ui

// Scroll bars for every scroll region: a vertical one for a box with .View_Scroll_Y whose content is taller than it, at its
// right edge (the left one with .Scrollbar_Left); a horizontal one for a box with .View_Scroll_X whose content is wider,
// along its bottom edge (short of the vertical one). A text area places its own (text_edit.odin) and draws them here.
// The form is the desktop's (src/md/features/scroll-bar.md): a trough, an arrow button at each end, a thumb with a grip.
// A bar shows whenever its content overflows, and never hides. A vertical bar can carry marks (scroll_marks.odin): it is
// then wider, its marks are drawn on its track under a thumb that lets them show, and a press on a mark goes there.
// And corner rounding control.

import "core:math"
import "../draw"

// Corner rounding factor for every rounded shape the toolkit draws: 0 = square corners, 1 = default, up to 2. The edged
// finish has square corners whatever it is set to (rounding returns 0 there): its hairlines run straight to the corners.
set_rounding :: proc(s: ^State, r: f32) { s.rounding = clamp(r, 0, 2) }
rounding :: proc(s: ^State) -> f32 { return s.theme != nil && s.theme.finish == .Edged ? 0 : s.rounding }

// A radius scaled by the current rounding (for custom draw procs that want to follow the setting).
rad :: proc(r: f32) -> f32 { return radius_drawn(gs(), r) }

// A radius that is a widget's shape, not a corner (a switch's pill, a slider's slot): the rounding setting scales it, the
// edged finish's square corners leave it.
shape_rad :: proc(r: f32) -> f32 { return r * gs().rounding }

// How thick every scroll bar is: Thin (the default) or Wide (the standard's 17 px).
Scrollbar_Size :: enum u8 { Thin, Wide }

set_scrollbar_size :: proc(s: ^State, size: Scrollbar_Size) { s.scrollbar_size = size }

// Scroll bars that show only while their content moves, while the pointer is over their box or one of them is held, and
// for a moment after scrollbar_reveal; they fade otherwise. Off by default: a bar always shows while its content
// overflows. A hidden bar is still there to take as soon as the pointer comes.
set_scrollbar_autohide :: proc(s: ^State, on: bool) { s.scrollbar_autohide = on }

// Scroll bars drawn over the edge of their content, which then keeps no room for them (as macOS draws them). Off by
// default: a scroll box's content is laid out beside its bars, never under them (layout, Box.bar_room).
set_scrollbar_overlay :: proc(s: ^State, on: bool) { s.scrollbar_overlay = on }

// The room a scroll box keeps for its bars, from its last layout, pixels: along X a vertical bar's, along Y a
// horizontal bar's (0: none, it fits or its bars overlay). A box outside the scroll box that lines up with its content
// (a table's titles over its rows) leaves the same room.
scrollbar_room :: proc(b: ^Box, axis: Axis) -> f32 { return b == nil ? 0 : b.bar_room[int(axis)] }

// Whether a scroll box's content overflows along `axis` in its last layout, so that it shows a bar there.
@(private = "file")
scrollbar_overflows :: proc(s: ^State, b: ^Box, axis: Axis) -> bool {
	a := int(axis)
	flag := axis == .Y ? Box_Flag.View_Scroll_Y : Box_Flag.View_Scroll_X
	if flag not_in b.flags || .Scrollbar_None in b.flags { return false }
	return b.view_bounds[a] > b.size[a] + SCROLLBAR_FIT_SLACK_PX && b.size[a] >= SCROLLBAR_VIEW_MIN_PX * s.scale
}

// After a layout: each scroll box keeps its bars' room where its content overflows, and gives it back where it fits.
// True when a room changed: the layout runs again in the same build. Measured with the room it had, the decision has a
// hysteresis: a content that overflows only beside a bar never takes the room (it was measured without it), and a
// content that keeps the room gives it back once it fits beside the bar (it then fits without it too). The room never
// goes and comes from one build to the next. A box with .Scrollbar_Reserve keeps the room of each bar it can show,
// overflowing or not (a content that grows past its view does not narrow then); .Scrollbar_None keeps none.
@(private)
scrollbar_rooms_update :: proc(s: ^State, b: ^Box) -> (changed: bool) {
	if b.flags & {.View_Scroll_X, .View_Scroll_Y} != {} {
		want: Vec2
		if !s.scrollbar_overlay && .Scrollbar_None not_in b.flags {
			reserve := .Scrollbar_Reserve in b.flags
			if (reserve && .View_Scroll_Y in b.flags) || scrollbar_overflows(s, b, .Y) { want.x = scroll_marks_of(b) != nil ? scroll_marks_rest_width(b) : scrollbar_thickness(s) }
			if (reserve && .View_Scroll_X in b.flags) || scrollbar_overflows(s, b, .X) { want.y = scrollbar_thickness(s) }
		}
		if want != b.bar_room { b.bar_room, changed = want, true }
	} else if b.bar_room != {} {
		b.bar_room, changed = {}, true
	}
	for c := b.first; c != nil; c = c.next { if scrollbar_rooms_update(s, c) { changed = true } }
	return
}

// Scrolled by something other than the pointer (the keyboard): its bar shows for a moment, wherever the pointer is.
scrollbar_reveal :: proc(b: ^Box) {
	if b == nil { return }
	b.bar_until = gs().time_ms + SCROLLBAR_REVEAL_MS
}

// How much a box's bar shows, 0..1: 1 without auto-hide. A bar with marks always shows: its marks are a map of the
// content, not a sign that it scrolls.
scrollbar_opacity :: proc(s: ^State, b: ^Box) -> f32 { return (s.scrollbar_autohide && scroll_marks_of(b) == nil) ? b.bar_t : 1 }

// Where a box's bar is heading with auto-hide, each build (update_animations): shown while its view moves, the pointer
// is over the box or its bar is held, and until the time scrollbar_reveal set.
@(private)
scrollbar_shown :: proc(s: ^State, b: ^Box) -> bool {
	inside := s.mouse_valid && draw.rect_contains(b.rect, s.mouse)
	held := s.active_key[.Left] == scrollbar_key(b) || s.active_key[.Left] == scrollbar_key(b, .X)
	moving := b.view_off != b.view_target || b.view_anim[0].active || b.view_anim[1].active
	if inside || held || moving { return true }
	left := b.bar_until - s.time_ms
	if left <= 0 { return false }
	wake_within(s, int(left) + 1)
	return true
}

// A part of a scroll bar. Mark: a mark of a bar with marks (scroll_marks.odin).
Scrollbar_Part :: enum u8 { None, Start, End, Track, Thumb, Mark }

// Where the parts of a bar are, window pixels. `start` and `end` are its arrow buttons (`arrows` false: none, the track
// is the whole bar).
Scrollbar_Parts :: struct {
	bar, start, end, track, thumb: Rect,
	axis:   Axis,
	arrows: bool,
}

// How a bar is drawn: `lit` (the pointer over it, or a part of it held), the part under the pointer, the part held.
Scrollbar_Look :: struct {
	lit:       bool,
	hot, held: Scrollbar_Part,
}

// The standard's numbers, logical pixels (scroll-bar.md): the thickness, the grip's line length and the rows of a
// triangle, wide and thin. Thin is 9, not 8.5: odd, its grip and its triangles' points have a middle column.
@(private = "file") SCROLLBAR_WIDE_PX :: 17
@(private = "file") SCROLLBAR_THIN_PX :: 9
@(private = "file") SCROLLBAR_GRIP_WIDE_PX :: 7
@(private = "file") SCROLLBAR_GRIP_THIN_PX :: 3
@(private = "file") SCROLLBAR_ARROW_ROWS_WIDE :: 4
@(private = "file") SCROLLBAR_ARROW_ROWS_THIN :: 3
@(private = "file") SCROLLBAR_GRIP_LINES :: 4
@(private = "file") SCROLLBAR_GRIP_THUMB_PX :: 20   // a thumb shorter than this has no grip
@(private = "file") SCROLLBAR_THUMB_LEAST :: 0.08   // of the track
@(private = "file") SCROLLBAR_THUMB_RADIUS_PX :: 3
@(private = "file") SCROLLBAR_ARROW_RADIUS_PX :: 2
@(private = "file") SCROLLBAR_REPEAT_DELAY_MS :: 400
@(private = "file") SCROLLBAR_REPEAT_INTERVAL_MS :: 60
// Where the stops of the gradients across the bar are, 0..1: the trough's middle stop, the thumb's two middle ones.
@(private = "file") SCROLLBAR_TROUGH_MIDDLE :: 0.5
@(private = "file") SCROLLBAR_THUMB_MIDDLE_A :: 0.45
@(private = "file") SCROLLBAR_THUMB_MIDDLE_B :: 0.55
@(private = "file") SCROLLBAR_REVEAL_MS :: 900   // auto-hide: how long a bar shows after scrollbar_reveal
@(private) SCROLLBAR_HIDDEN_ALPHA :: 0.01   // auto-hide: a bar that shows no more than this is not drawn
@(private) SCROLLBAR_FIT_SLACK_PX :: 0.5   // content this much larger than the view still fits
@(private = "file") SCROLLBAR_VIEW_MIN_PX :: 8   // a view smaller than this shows no bar
// What takes the press beyond the bar: toward the content, and away from it (scrollbar_grab).
@(private = "file") SCROLLBAR_GRAB_IN_PX :: 4
@(private = "file") SCROLLBAR_GRAB_OUT_PX :: 2
@(private = "file") SCROLLBAR_KEY_SALT :: 0x5c5c_5c5c
@(private = "file") SCROLLBAR_X_KEY_SALT :: 0x5c5c_5c5d

@(private)
scrollbar_key :: proc(b: ^Box, axis := Axis.Y) -> Key { return key_from_u64(b.key, axis == .Y ? SCROLLBAR_KEY_SALT : SCROLLBAR_X_KEY_SALT) }

// The thumb of a box's vertical bar is held: the view goes where the pointer puts it, and nothing must move it under the
// pointer (a list that keeps its row in view). A held arrow or a page moves the view as the wheel does.
@(private)
scrollbar_thumb_held :: proc(s: ^State, b: ^Box) -> bool { return s.active_key[.Left] == scrollbar_key(b) && s.sb_held == .Thumb }

// The axis of a box's bar by its key.
@(private)
scrollbar_axis :: proc(b: ^Box, sbk: Key) -> Axis { return sbk == scrollbar_key(b, .X) ? .X : .Y }

// What takes the press beyond a bar: toward the content, and away from it.
@(private)
scrollbar_grab :: proc() -> (toward, away: f32) { return SCROLLBAR_GRAB_IN_PX * gs().scale, SCROLLBAR_GRAB_OUT_PX * gs().scale }

// The odd number of pixels nearest below `x` (at least 1): a part with a middle column, so that what is centred on the
// bar (a triangle's point, the grip) is on a pixel.
@(private)
odd_px :: proc(x: f32) -> f32 { return 2 * math.floor(max(x, 1) * 0.5) + 1 }

// A border, the thumb's inner line, a line of the grip and a row of a triangle: one logical pixel at the scale.
@(private = "file")
scrollbar_unit :: proc(s: ^State) -> f32 { return max(1, math.round(s.scale)) }

// How thick a bar is, pixels: the setting's at the window's scale, odd.
@(private)
scrollbar_thickness :: proc(s: ^State) -> f32 {
	return odd_px((s.scrollbar_size == .Wide ? SCROLLBAR_WIDE_PX : SCROLLBAR_THIN_PX) * s.scale)
}

// A bar's thickness, pixels: the room a scroll box's layout keeps for it (a bar with marks keeps more: scrollbar_room
// says what a box keeps). Content leaves nothing for the bar itself: the layout does.
scrollbar_gutter :: proc() -> f32 { return scrollbar_thickness(gs()) }

// How far a bar keeps from the ends of the edge it lies on: the box's drawn corner, so that it stays inside a rounded box.
@(private)
scrollbar_inset :: proc(s: ^State, b: ^Box) -> f32 { return math.round(box_drawn_radius(s, b)) }

// The parts of a bar laid along `bar`: a view `view` long over a content `content` long, scrolled `t` (0..1) of the way.
@(private)
scrollbar_layout :: proc(s: ^State, bar: Rect, axis: Axis, view, content, t: f32) -> (p: Scrollbar_Parts) {
	a := int(axis)
	w := scrollbar_thickness(s)
	p.bar, p.axis, p.track = bar, axis, bar
	length := bar.max[a] - bar.min[a]
	// (two buttons and a least thumb, or no buttons: the track takes the bar)
	if length >= 3 * w {
		p.arrows = true
		p.start, p.end = bar, bar
		p.start.max[a] = bar.min[a] + w
		p.end.min[a] = bar.max[a] - w
		p.track.min[a], p.track.max[a] = p.start.max[a], p.end.min[a]
	}
	avail := p.track.max[a] - p.track.min[a]
	thumb := min(max(avail * view / max(content, 1), avail * SCROLLBAR_THUMB_LEAST, w), avail)
	thumb = math.round(thumb)
	at := math.round(p.track.min[a] + clamp(t, 0, 1) * (avail - thumb))
	p.thumb = p.track
	p.thumb.min[a], p.thumb.max[a] = at, at + thumb
	return
}

// The parts of a scroll box's bar along `axis`, or ok = false when everything fits.
@(private)
scrollbar_parts :: proc(b: ^Box, axis := Axis.Y) -> (p: Scrollbar_Parts, ok: bool) {
	s := gs()
	a := int(axis)
	view, content := b.size[a], b.view_bounds[a]
	flag := axis == .Y ? Box_Flag.View_Scroll_Y : Box_Flag.View_Scroll_X
	if flag not_in b.flags || .Scrollbar_None in b.flags || content <= view + SCROLLBAR_FIT_SLACK_PX || view < SCROLLBAR_VIEW_MIN_PX * s.scale { return }
	w := scrollbar_thickness(s)
	// (inside the box's border, in the room its layout kept; along the edge, clear of its rounded corners too)
	edge := border_inset(b)
	inset := max(scrollbar_inset(s, b), edge)
	bar: Rect
	if axis == .Y {
		top := b.rect.min.y + inset
		// (a bar with marks: wider, and below the room of its filter's button)
		if k := scroll_marks_of(b); k != nil { w, top = scroll_marks_bar_width(b), top + k.head }
		bottom := b.rect.max.y - inset
		if bottom - top < SCROLLBAR_VIEW_MIN_PX * s.scale { return }
		bar = {{b.rect.max.x - edge - w, top}, {b.rect.max.x - edge, bottom}}
		if .Scrollbar_Left in b.flags { bar.min.x, bar.max.x = b.rect.min.x + edge, b.rect.min.x + edge + w }
	} else {
		bar = {{b.rect.min.x + inset, b.rect.max.y - edge - w}, {b.rect.max.x - inset, b.rect.max.y - edge}}
		// (short of the vertical bar's corner, on whichever side it is)
		if y, has := scrollbar_parts(b, .Y); has {
			if .Scrollbar_Left in b.flags { bar.min.x = max(bar.min.x, y.bar.max.x) } else { bar.max.x = min(bar.max.x, y.bar.min.x) }
		}
		if bar.max.x - bar.min.x < SCROLLBAR_VIEW_MIN_PX * s.scale { return }
	}
	limit := view_limit(b, axis)
	t := limit > 0 ? b.view_off[a] / limit : 0
	return scrollbar_layout(s, bar, axis, view, content, t), true
}

// The track and the thumb a scroll box shows (ok = false: everything fits, no bar), window pixels. For tests and tools.
scrollbar_rects :: proc(b: ^Box, axis := Axis.Y) -> (track, thumb: Rect, ok: bool) {
	p, has := scrollbar_parts(b, axis)
	return p.track, p.thumb, has
}

// The arrow buttons of a scroll box's bar, at the start and at the end of its track (ok = false: no bar, or one too
// short for them), window pixels.
scrollbar_arrow_rects :: proc(b: ^Box, axis := Axis.Y) -> (start, end: Rect, ok: bool) {
	p, has := scrollbar_parts(b, axis)
	if !has || !p.arrows { return }
	return p.start, p.end, true
}

// The bar of `b` that takes a press at `p` (window pixels): the one it shows, a little wider toward the content. ok = false:
// none. A program that hears the pointer before the interface (a terminal's grid in a box that scrolls) leaves such a press
// to it.
scrollbar_under :: proc(b: ^Box, p: Vec2) -> (axis: Axis, ok: bool) {
	grab_in, away := scrollbar_grab()
	// (toward the content only over it: a bar in its own room ends where the content starts, whose last pixels are its own)
	if y, has := scrollbar_parts(b); has {
		toward := b.bar_room.x > 0 ? 0 : grab_in
		grab := Rect{{y.bar.min.x - toward, y.bar.min.y}, {y.bar.max.x + away, y.bar.max.y}}
		if .Scrollbar_Left in b.flags { grab.min.x, grab.max.x = y.bar.min.x - away, y.bar.max.x + toward }
		if draw.rect_contains(grab, p) { return .Y, true }
	}
	if x, has := scrollbar_parts(b, .X); has {
		toward := b.bar_room.y > 0 ? 0 : grab_in
		if draw.rect_contains(Rect{{x.bar.min.x, x.bar.min.y - toward}, {x.bar.max.x, x.bar.max.y + away}}, p) { return .X, true }
	}
	return
}

// The part of a bar at `at`, along its axis (what is beside the bar, in its grab margin, is the part it is beside).
@(private)
scrollbar_part_at :: proc(p: Scrollbar_Parts, at: Vec2) -> Scrollbar_Part {
	a := int(p.axis)
	if p.arrows {
		if at[a] < p.start.max[a] { return .Start }
		if at[a] >= p.end.min[a] { return .End }
	}
	if at[a] >= p.thumb.min[a] && at[a] < p.thumb.max[a] { return .Thumb }
	return .Track
}

// The rule of a held arrow (repeat_fires with the standard's times): true at the press, then after 400 ms, then every
// 60 ms while the pointer is on it. `key` names the bar.
@(private)
scrollbar_repeat :: proc(s: ^State, key: Key, pressed, on: bool) -> bool {
	return repeat_fires_every(s, key, pressed, true, on, SCROLLBAR_REPEAT_DELAY_MS, SCROLLBAR_REPEAT_INTERVAL_MS)
}

// An arrow's step: the view moves a line toward `dir` (eased like the wheel's).
@(private = "file")
scrollbar_step :: proc(b: ^Box, axis: Axis, dir: f32) {
	a := int(axis)
	b.view_target[a] = clamp(b.view_target[a] + dir * line_height_of(b), 0, view_limit(b, axis))
}

// A press on the track: the view moves a page (its own length) toward `dir`.
@(private = "file")
scrollbar_page :: proc(b: ^Box, axis: Axis, dir: f32) {
	a := int(axis)
	b.view_target[a] = clamp(b.view_target[a] + dir * b.size[a], 0, view_limit(b, axis))
}

// Press on a scroll bar (events, against the layout under the press): an arrow steps the view, the track pages it, the
// thumb is held where it was taken, a mark is left to scroll_marks.
@(private)
scrollbar_press :: proc(s: ^State, sbk: Key, p: Vec2) {
	s.sb_held = .None
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	axis := scrollbar_axis(b, sbk)
	parts, has := scrollbar_parts(b, axis)
	if !has { return }
	a := int(axis)
	part := scrollbar_part_at(parts, p)
	// (a mark: the build goes there, scroll_marks)
	if part == .Track && axis == .Y {
		if k := scroll_marks_of(b); k != nil && scroll_marks_hit(k, b, p) >= 0 {
			s.sb_held = .Mark
			return
		}
	}
	s.sb_held = part
	#partial switch part {
	case .Start, .End:
		if scrollbar_repeat(s, sbk, true, true) { scrollbar_step(b, axis, part == .Start ? -1 : 1) }
	case .Thumb:
		s.sb_grab = p[a] - parts.thumb.min[a]
	case .Track:
		scrollbar_page(b, axis, p[a] < parts.thumb.min[a] ? -1 : 1)
	}
}

// While a bar is held: a held arrow steps again by the clock while the pointer stays on it; a held thumb maps the pointer
// to the offset (at once, no easing: the thumb follows), once the pointer moved since the press.
@(private)
scrollbar_drag :: proc(s: ^State) {
	sbk := s.active_key[.Left]
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	axis := scrollbar_axis(b, sbk)
	parts, has := scrollbar_parts(b, axis)
	if !has { return }
	a := int(axis)
	#partial switch s.sb_held {
	case .Start, .End:
		on := draw.rect_contains(s.sb_held == .Start ? parts.start : parts.end, s.mouse)
		if scrollbar_repeat(s, sbk, false, on) { scrollbar_step(b, axis, s.sb_held == .Start ? -1 : 1) }
	case .Thumb:
		// (the thumb's place is whole pixels, coarser than a long content's offsets: no move, no shift)
		if s.mouse[a] == s.press_pos[.Left][a] { return }
		span := (parts.track.max[a] - parts.track.min[a]) - (parts.thumb.max[a] - parts.thumb.min[a])
		if span <= 0 { return }
		t := clamp((s.mouse[a] - s.sb_grab - parts.track.min[a]) / span, 0, 1)
		view_jump(b, t * view_limit(b, axis), axis)
		s.anim_busy = true
	}
}

// A scroll box's bar along `axis`, in its state.
@(private)
draw_scrollbar :: proc(s: ^State, dc: ^draw.Context, b: ^Box, axis := Axis.Y) {
	parts, ok := scrollbar_parts(b, axis)
	if !ok { return }
	sbk := scrollbar_key(b, axis)
	held := s.active_key[.Left] == sbk
	hot := s.hot_key == sbk
	look := Scrollbar_Look{lit = hot || held}
	if held && s.sb_held != .Mark { look.held = s.sb_held }
	if hot && s.mouse_valid { look.hot = scrollbar_part_at(parts, s.mouse) }
	scrollbar_paint(s, dc, b, parts, look)
}

// The colours of a bar (scroll-bar.md, "The colours come from the theme"): the standard's dark or light table, made of
// the theme's surfaces and accent.
@(private)
Scrollbar_Colors :: struct {
	trough:                                          [3]Color,
	trough_border, lit_border, thumb_border, hot_border: Color,
	button_lit, button_hot, button_pressed:          [2]Color,
	glyph, glyph_hot:                                Color,
	thumb_rest, thumb_lit, thumb_held:               [4]Color,
	thumb_line, grip, grip_lit:                      Color,
}

@(private)
scrollbar_colors :: proc(s: ^State, b: ^Box) -> (c: Scrollbar_Colors) {
	opaque :: proc(c: Color) -> Color { return {c.r, c.g, c.b, 1} }
	m :: proc(a, b: Color, t: f32) -> Color { return srgb_mix(a, b, t) }
	white := Color{1, 1, 1, 1}
	under := box_under(b)
	track := opaque(color_from_tags(s, b.tags_key, "track"))
	line := opaque(color_from_tags(s, b.tags_key, "border"))
	weak := opaque(color_from_tags(s, b.tags_key, "weak text"))
	text := opaque(color_from_tags(s, b.tags_key, "text"))
	accent := opaque(color_from_tags(s, b.tags_key, "accent"))
	dark := s.theme != nil ? s.theme.dark : under.r + under.g + under.b < 1.5
	c.hot_border = accent
	if dark {
		edge := m(track, line, 0.5)
		c.trough = {edge, line, edge}
		c.trough_border = m(under, track, 0.5)
		c.lit_border = m(line, weak, 0.4)
		c.thumb_border = c.lit_border
		c.button_lit = {m(line, weak, 0.2), m(line, weak, 0.1)}
		c.button_hot = {m(track, accent, 0.28), m(track, accent, 0.2)}
		c.button_pressed = {m(track, accent, 0.4), m(track, accent, 0.32)}
		c.glyph = m(weak, text, 0.3)
		c.glyph_hot = m(text, accent, 0.2)
		c.thumb_rest = {m(line, weak, 0.3), m(line, weak, 0.24), m(line, weak, 0.18), m(line, weak, 0.12)}
		c.thumb_lit = {m(track, accent, 0.45), m(track, accent, 0.38), m(track, accent, 0.31), m(track, accent, 0.24)}
		c.thumb_held = {m(track, accent, 0.58), m(track, accent, 0.5), m(track, accent, 0.42), m(track, accent, 0.34)}
		c.thumb_line = {1, 1, 1, 0.12}
		c.grip = c.trough_border
		c.grip_lit = m(text, accent, 0.45)
	} else {
		edge := m(track, line, 0.5)
		c.trough = {edge, m(under, white, 0.3), edge}
		c.trough_border = line
		c.lit_border = m(line, weak, 0.5)
		c.thumb_border = c.lit_border
		c.button_lit = {m(under, white, 0.5), m(track, line, 0.6)}
		c.button_hot = {m(white, accent, 0.1), m(white, accent, 0.2)}
		c.button_pressed = {m(white, accent, 0.22), m(white, accent, 0.3)}
		c.glyph = weak
		c.glyph_hot = m(accent, text, 0.4)
		deep := m(line, weak, 0.25)
		c.thumb_rest = {m(white, deep, 0.2), m(white, deep, 0.45), m(white, deep, 0.7), deep}
		c.thumb_lit = {m(white, accent, 0.12), m(white, accent, 0.2), m(white, accent, 0.28), m(white, accent, 0.36)}
		c.thumb_held = {m(white, accent, 0.22), m(white, accent, 0.3), m(white, accent, 0.38), m(white, accent, 0.46)}
		c.thumb_line = {1, 1, 1, 0.4}
		c.grip = m(weak, line, 0.3)
		c.grip_lit = m(accent, text, 0.25)
	}
	return
}

// `r` filled with a gradient across a bar along `axis` (left to right on a vertical bar, top to bottom on a horizontal
// one), its stops `colors` at `at`, in sRGB values as the standard's.
@(private = "file")
scrollbar_fill :: proc(dc: ^draw.Context, r: Rect, axis: Axis, colors: []Color, at: []f32, radius: f32) {
	stops: [4]draw.Gradient_Stop
	n := min(len(colors), len(stops))
	for i in 0 ..< n { stops[i] = {color = colors[i], pos = at[i]} }
	size := r.max - r.min
	g := draw.Gradient{kind = .Linear, space = .Srgb, end = axis == .Y ? Vec2{size.x, 0} : Vec2{0, size.y}, stops = stops[:n]}
	draw.gradient(dc, r, g, {radius, radius, radius, radius})
}

// How a scroll bar looks, whatever scrolls (a view, a text area that scrolls itself), at the parts `p`, in the state
// `look`: the trough, the arrow buttons, the thumb with its border, its inner line and its grip. One look for every bar:
// a widget with a bar of its own draws it with this, at its own place.
//
// A vertical bar with marks (scroll_marks.odin) draws its marks on the trough: those out of the thumb's span under it,
// those within it over it, a little brighter (where the view is among them), and the mark under the pointer or the
// keyboard's last. Its thumb has no grip.
scrollbar_paint :: proc(s: ^State, dc: ^draw.Context, b: ^Box, p: Scrollbar_Parts, look: Scrollbar_Look) {
	// (auto-hide: the whole bar fades as one, its parts drawn as at full strength)
	shows := scrollbar_opacity(s, b)
	if shows <= SCROLLBAR_HIDDEN_ALPHA { return }
	draw.push_alpha(dc, shows)
	defer draw.pop_alpha(dc)
	c := scrollbar_colors(s, b)
	u := scrollbar_unit(s)
	axis := p.axis
	a := int(axis)
	trough_at := [3]f32{0, SCROLLBAR_TROUGH_MIDDLE, 1}
	thumb_at := [4]f32{0, SCROLLBAR_THUMB_MIDDLE_A, SCROLLBAR_THUMB_MIDDLE_B, 1}
	button_at := [2]f32{0, 1}
	scrollbar_fill(dc, p.bar, axis, c.trough[:], trough_at[:], 0)
	draw.rect(dc, p.bar, c.trough_border, 0, u)
	marks := axis == .Y ? scroll_marks_of(b) : nil
	if marks != nil { scroll_marks_draw(s, dc, b, marks, p.track, p.thumb, false) }

	if p.arrows {
		radius := radius_drawn(s, SCROLLBAR_ARROW_RADIUS_PX * s.scale)
		for part in ([2]Scrollbar_Part{.Start, .End}) {
			r := part == .Start ? p.start : p.end
			hot := look.hot == part
			fill: Maybe([2]Color)
			border: Maybe(Color)
			switch {
			case look.held == part: fill = c.button_pressed
			case hot:               fill = c.button_hot
			case look.lit:          fill = c.button_lit
			}
			switch {
			case hot || look.held == part: border = c.hot_border
			case look.lit:                 border = c.lit_border
			}
			if f, has := fill.?; has { scrollbar_fill(dc, r, axis, f[:], button_at[:], radius) }
			if k, has := border.?; has { draw.rect(dc, r, k, radius, u) }
			scrollbar_triangle(s, dc, r, axis, part == .Start, hot ? c.glyph_hot : c.glyph)
		}
	}

	// the thumb, over the trough's border: the whole thickness of the bar
	thumb := p.thumb
	radius := radius_drawn(s, SCROLLBAR_THUMB_RADIUS_PX * s.scale)
	stops := look.held == .Thumb ? c.thumb_held : (look.lit ? c.thumb_lit : c.thumb_rest)
	scrollbar_fill(dc, thumb, axis, stops[:], thumb_at[:], radius)
	draw.rect(dc, draw.rect_pad(thumb, -u), tuned(c.thumb_line), max(radius - u, 0), u)
	draw.rect(dc, thumb, look.lit ? c.hot_border : c.thumb_border, radius, u)
	along := thumb.max[a] - thumb.min[a]
	if marks == nil && along >= SCROLLBAR_GRIP_THUMB_PX * s.scale {
		gl := odd_px((s.scrollbar_size == .Wide ? SCROLLBAR_GRIP_WIDE_PX : SCROLLBAR_GRIP_THIN_PX) * s.scale)
		pitch := 2 * u
		first := math.round((thumb.min[a] + thumb.max[a]) * 0.5 - (f32(SCROLLBAR_GRIP_LINES) * pitch - u) * 0.5)
		x := 1 - a
		lo := thumb.min[x] + math.floor((thumb.max[x] - thumb.min[x] - gl) * 0.5)
		grip := look.lit ? c.grip_lit : c.grip
		for k in 0 ..< SCROLLBAR_GRIP_LINES {
			r: Rect
			r.min[a], r.max[a] = first + f32(k) * pitch, first + f32(k) * pitch + u
			r.min[x], r.max[x] = lo, lo + gl
			draw.rect(dc, r, grip)
		}
	}
	if marks != nil { scroll_marks_draw(s, dc, b, marks, p.track, p.thumb, true) }
}

// An arrow button's triangle, in rows of pixels: rows of 1, 3, 5… (one unit tall each, two units wider each), its point
// toward the start of the bar (`start`) or its end, centred in `r`.
@(private = "file")
scrollbar_triangle :: proc(s: ^State, dc: ^draw.Context, r: Rect, axis: Axis, start: bool, color: Color) {
	u := scrollbar_unit(s)
	rows := s.scrollbar_size == .Wide ? SCROLLBAR_ARROW_ROWS_WIDE : SCROLLBAR_ARROW_ROWS_THIN
	a := int(axis)
	x := 1 - a
	side := r.max[x] - r.min[x]
	along := r.min[a] + math.floor(((r.max[a] - r.min[a]) - f32(rows) * u) * 0.5)
	for i in 0 ..< rows {
		width := 1 + 2 * f32(i) * u
		row := start ? i : rows - 1 - i
		q: Rect
		q.min[a] = along + f32(row) * u
		q.max[a] = q.min[a] + u
		q.min[x] = r.min[x] + math.floor((side - width) * 0.5)
		q.max[x] = q.min[x] + width
		draw.rect(dc, q, color)
	}
}
