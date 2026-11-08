package ui

// Scrollbars for every vertical scroll region (boxes with .View_Scroll_Y whose content is taller than the box),
// and corner rounding control. Scrollbars are drawn over the content at the right edge (the left one with
// .Scrollbar_Left), can be dragged, and a press on the track jumps there. With set_scrollbar_arrows, a bar has an arrow
// button at each end: a press scrolls a step, held it repeats.

import "core:math"
import "../draw"

// Corner rounding factor for every rounded shape the toolkit draws: 0 = square corners, 1 = default, up to 2.
set_rounding :: proc(s: ^State, r: f32) { s.rounding = clamp(r, 0, 2) }
rounding :: proc(s: ^State) -> f32 { return s.rounding }

// Scroll bars that show only while the pointer is over their box, while one is held, and for a moment after
// scrollbar_reveal. Off by default: a bar always shows. Still there to grab as soon as the pointer comes.
set_scrollbar_autohide :: proc(s: ^State, on: bool) { s.scrollbar_autohide = on }

// Arrow buttons at both ends of every bar (classic scroll bars). Off by default: the track runs from end to end.
set_scrollbar_arrows :: proc(s: ^State, on: bool) { s.scrollbar_arrows = on }

// Scrolled by something other than the pointer (the keyboard): its bar shows for a moment, wherever the pointer is.
scrollbar_reveal :: proc(b: ^Box) {
	if b == nil { return }
	b.bar_until = gs().time_ms + SCROLLBAR_REVEAL_MS
}

// How much a box's bar shows, 0..1.
scrollbar_opacity :: proc(s: ^State, b: ^Box) -> f32 { return s.scrollbar_autohide ? b.bar_t : 1 }

// Where a box's bar is heading, each build (update_animations).
@(private)
scrollbar_shown :: proc(s: ^State, b: ^Box) -> bool {
	inside := s.mouse_valid && s.mouse.x >= b.rect.min.x && s.mouse.x < b.rect.max.x && s.mouse.y >= b.rect.min.y && s.mouse.y < b.rect.max.y
	if inside || s.active_key[.Left] == scrollbar_key(b) { return true }
	left := b.bar_until - s.time_ms
	if left <= 0 { return false }
	wake_within(s, int(left) + 1)
	return true
}

// A radius scaled by the current rounding (for custom draw procs that want to follow the setting).
rad :: proc(r: f32) -> f32 { return r * gs().rounding }

// Scrollbars of scroll boxes and of text_edit. Width and thumb in em, the margin as a fraction of the width.
@(private) SCROLLBAR_WIDTH_MIN_PX :: 6
@(private) SCROLLBAR_WIDTH_EM :: 0.5
@(private) SCROLLBAR_MARGIN_FRACTION :: 0.35
@(private) SCROLLBAR_THUMB_MIN_EM :: 1.6
@(private) SCROLLBAR_FIT_SLACK_PX :: 0.5   // content this much larger than the view still fits
@(private = "file") SCROLLBAR_VIEW_MIN_PX :: 8   // a view smaller than this shows no bar
// What takes the press beyond the bar's track: toward the content, and away from it (scrollbar_grab).
@(private = "file") SCROLLBAR_GRAB_IN_PX :: 4
@(private = "file") SCROLLBAR_GRAB_OUT_PX :: 2
@(private) SCROLLBAR_TRACK_HOT_ALPHA :: 0.06
@(private) SCROLLBAR_THUMB_REST_ALPHA :: 0.22
@(private = "file") SCROLLBAR_THUMB_HOT_ALPHA :: 0.4
@(private = "file") SCROLLBAR_THUMB_HELD_ALPHA :: 0.55
@(private = "file") SCROLLBAR_KEY_SALT :: 0x5c5c_5c5c
@(private = "file") SCROLLBAR_REVEAL_MS :: 900
@(private) SCROLLBAR_HIDDEN_ALPHA :: 0.01   // no more than this: not drawn
// Arrow buttons (set_scrollbar_arrows): each as long as the bar is broad (its width and margins), the triangle this much
// of the bar's width; a press scrolls a step, held it steps again after a delay and then at a rate (Chromium's timings).
@(private = "file") SCROLLBAR_ARROW_GLYPH_FRACTION :: 0.7
@(private = "file") SCROLLBAR_ARROW_STEP_EM :: 3
@(private = "file") SCROLLBAR_ARROW_DELAY_MS :: 250
@(private = "file") SCROLLBAR_ARROW_REPEAT_MS :: 50

@(private)
scrollbar_key :: proc(b: ^Box) -> Key { return key_from_u64(b.key, SCROLLBAR_KEY_SALT) }

// What takes the press beyond a bar's track: toward the content, and away from it.
@(private)
scrollbar_grab :: proc() -> (toward, away: f32) { return SCROLLBAR_GRAB_IN_PX * gs().scale, SCROLLBAR_GRAB_OUT_PX * gs().scale }

// A bar's width and its margin from the edges of its box.
@(private)
scrollbar_size :: proc(font_size: f32) -> (w, m: f32) {
	w = max(SCROLLBAR_WIDTH_MIN_PX * gs().scale, math.round(font_size * SCROLLBAR_WIDTH_EM))
	m = math.round(w * SCROLLBAR_MARGIN_FRACTION)
	return
}

// Along a track `avail` long: where the thumb starts (`t`: how far the view is scrolled, 0..1) and how long it is.
@(private)
scrollbar_thumb :: proc(font_size, avail, view, content, t: f32) -> (at, length: f32) {
	length = max(font_size * SCROLLBAR_THUMB_MIN_EM, avail * view / content)
	at = t * (avail - length)
	return
}

// The parts of a scroll box's bar, or ok = false when everything fits: the whole bar, its track (the bar less its arrow
// buttons) and the thumb; `arrow`: how long each arrow button is (0: none).
@(private)
scrollbar_parts :: proc(b: ^Box) -> (bar, track, thumb: Rect, arrow: f32, ok: bool) {
	view := b.size.y
	content := b.view_bounds.y
	if .View_Scroll_Y not_in b.flags || content <= view + SCROLLBAR_FIT_SLACK_PX || view < SCROLLBAR_VIEW_MIN_PX * gs().scale { return }
	w, m := scrollbar_size(b.font_size)
	bar = {{b.rect.max.x - w - m, b.rect.min.y + m}, {b.rect.max.x - m, b.rect.max.y - m}}
	if .Scrollbar_Left in b.flags { bar.min.x, bar.max.x = b.rect.min.x + m, b.rect.min.x + m + w }
	// arrows only on a bar long enough for both and some track
	if gs().scrollbar_arrows && bar.max.y - bar.min.y > 2 * (w + 2 * m) + w { arrow = w + 2 * m }
	track = {{bar.min.x, bar.min.y + arrow}, {bar.max.x, bar.max.y - arrow}}
	th_avail := track.max.y - track.min.y
	at, th := scrollbar_thumb(b.font_size, th_avail, view, content, clamp(b.view_off.y / view_limit(b), 0, 1))
	y := track.min.y + at
	thumb = {{track.min.x, y}, {track.max.x, y + th}}
	ok = true
	return
}

// Track and thumb rects of a scroll box, or ok = false when everything fits.
@(private)
scrollbar_geom :: proc(b: ^Box) -> (track, thumb: Rect, ok: bool) {
	_, track, thumb, _, ok = scrollbar_parts(b)
	return
}

// The track and the thumb a scroll box shows (ok = false: everything fits, no bar), window pixels. For tests and tools.
scrollbar_rects :: proc(b: ^Box) -> (track, thumb: Rect, ok: bool) { return scrollbar_geom(b) }

// The arrow buttons of a scroll box's bar, at the start and at the end of its track (ok = false: no bar, or no arrows),
// window pixels.
scrollbar_arrow_rects :: proc(b: ^Box) -> (start, end: Rect, ok: bool) {
	bar, track, _, arrow, has := scrollbar_parts(b)
	if !has || arrow <= 0 { return }
	return {bar.min, {bar.max.x, track.min.y}}, {{bar.min.x, track.max.y}, bar.max}, true
}

// A held arrow's step: the view moves by it toward `dir` (eased like the wheel's).
@(private = "file")
scrollbar_arrow_step :: proc(b: ^Box, dir: f32) {
	b.view_target.y = clamp(b.view_target.y + dir * b.font_size * SCROLLBAR_ARROW_STEP_EM, 0, view_limit(b))
}

// Press on a scrollbar: an arrow steps the view; else remember where the thumb was grabbed (a press on the track centres
// the thumb there).
@(private)
scrollbar_press :: proc(s: ^State, sbk: Key, p: Vec2) {
	s.sb_arrow = 0
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	_, thumb, has := scrollbar_geom(b)
	if !has { return }
	if start, end, arrows := scrollbar_arrow_rects(b); arrows && (contains(start, p) || contains(end, p)) {
		s.sb_arrow = contains(start, p) ? -1 : 1
		s.sb_arrow_next_ms = s.time_ms + SCROLLBAR_ARROW_DELAY_MS
		scrollbar_arrow_step(b, s.sb_arrow)
		wake_within(s, SCROLLBAR_ARROW_DELAY_MS)
		return
	}
	if p.y >= thumb.min.y && p.y < thumb.max.y { s.sb_grab = p.y - thumb.min.y } else { s.sb_grab = (thumb.max.y - thumb.min.y) * 0.5 }
}

// While a scrollbar is held, map the pointer to a scroll offset (applied at once, no easing: the thumb follows). A held
// arrow steps again by the clock while the pointer stays on it.
@(private)
scrollbar_drag :: proc(s: ^State) {
	sbk := s.active_key[.Left]
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	track, thumb, has := scrollbar_geom(b)
	if !has { return }
	if s.sb_arrow != 0 {
		start, end, _ := scrollbar_arrow_rects(b)
		if !contains(s.sb_arrow < 0 ? start : end, s.mouse) { return }
		if s.time_ms >= s.sb_arrow_next_ms {
			scrollbar_arrow_step(b, s.sb_arrow)
			s.sb_arrow_next_ms = s.time_ms + SCROLLBAR_ARROW_REPEAT_MS
		}
		wake_within(s, int(s.sb_arrow_next_ms - s.time_ms) + 1)
		return
	}
	span := (track.max.y - track.min.y) - (thumb.max.y - thumb.min.y)
	if span <= 0 { return }
	t := clamp((s.mouse.y - s.sb_grab - track.min.y) / span, 0, 1)
	view_jump(b, t * view_limit(b))
	s.anim_busy = true
}

@(private)
draw_scrollbar :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	track, thumb, ok := scrollbar_geom(b)
	if !ok { return }
	shows := scrollbar_opacity(s, b)
	if shows <= SCROLLBAR_HIDDEN_ALPHA { return }
	sbk := scrollbar_key(b)
	hot := s.hot_key == sbk
	active := s.active_key[.Left] == sbk
	c := color_from_tags(s, b.tags_key, "text")
	w := track.max.x - track.min.x
	if hot || active {
		tc := c; tc.a = SCROLLBAR_TRACK_HOT_ALPHA * shows
		draw.rect(dc, track, tuned(tc), w * 0.5 * s.rounding)
	}
	glyph := c
	c.a = (active && s.sb_arrow == 0 ? SCROLLBAR_THUMB_HELD_ALPHA : (hot ? SCROLLBAR_THUMB_HOT_ALPHA : SCROLLBAR_THUMB_REST_ALPHA)) * shows
	draw.rect(dc, thumb, tuned(c), w * 0.5 * s.rounding)
	start, end, arrows := scrollbar_arrow_rects(b)
	if !arrows { return }
	half := w * SCROLLBAR_ARROW_GLYPH_FRACTION * 0.5
	for r, i in ([2]Rect{start, end}) {
		dir: f32 = i == 0 ? -1 : 1
		held := active && s.sb_arrow == dir
		glyph.a = (held ? SCROLLBAR_THUMB_HELD_ALPHA : (hot && contains(r, s.mouse) ? SCROLLBAR_THUMB_HOT_ALPHA : SCROLLBAR_THUMB_REST_ALPHA)) * shows
		mid := draw.rect_center(r)
		draw.triangle(dc, {mid.x, mid.y + dir * half}, {mid.x - half, mid.y - dir * half}, {mid.x + half, mid.y - dir * half}, tuned(glyph))
	}
}