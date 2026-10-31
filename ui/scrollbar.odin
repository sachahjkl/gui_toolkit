package ui

// Scrollbars for every vertical scroll region (boxes with .View_Scroll_Y whose content is taller than the box),
// and corner rounding control. Scrollbars are drawn over the content at the right edge (the left one with
// .Scrollbar_Left), can be dragged, and a press on the track jumps there.

import "core:math"
import "../draw"

// Corner rounding factor for every rounded shape the toolkit draws: 0 = square corners, 1 = default, up to 2.
set_rounding :: proc(s: ^State, r: f32) { s.rounding = clamp(r, 0, 2) }
rounding :: proc(s: ^State) -> f32 { return s.rounding }

// A radius scaled by the current rounding (for custom draw procs that want to follow the setting).
rad :: proc(r: f32) -> f32 { return r * g.rounding }

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

@(private)
scrollbar_key :: proc(b: ^Box) -> Key { return key_from_u64(b.key, SCROLLBAR_KEY_SALT) }

// What takes the press beyond a bar's track: toward the content, and away from it.
@(private)
scrollbar_grab :: proc() -> (toward, away: f32) { return SCROLLBAR_GRAB_IN_PX * g.scale, SCROLLBAR_GRAB_OUT_PX * g.scale }

// A bar's width and its margin from the edges of its box.
@(private)
scrollbar_size :: proc(font_size: f32) -> (w, m: f32) {
	w = max(SCROLLBAR_WIDTH_MIN_PX * g.scale, math.round(font_size * SCROLLBAR_WIDTH_EM))
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

// Track and thumb rects of a scroll box, or ok = false when everything fits.
@(private)
scrollbar_geom :: proc(b: ^Box) -> (track, thumb: Rect, ok: bool) {
	view := b.size.y
	content := b.view_bounds.y
	if .View_Scroll_Y not_in b.flags || content <= view + SCROLLBAR_FIT_SLACK_PX || view < SCROLLBAR_VIEW_MIN_PX * g.scale { return }
	w, m := scrollbar_size(b.font_size)
	track = {{b.rect.max.x - w - m, b.rect.min.y + m}, {b.rect.max.x - m, b.rect.max.y - m}}
	if .Scrollbar_Left in b.flags { track.min.x, track.max.x = b.rect.min.x + m, b.rect.min.x + m + w }
	th_avail := track.max.y - track.min.y
	maxoff := content - view
	at, th := scrollbar_thumb(b.font_size, th_avail, view, content, clamp(b.view_off.y / maxoff, 0, 1))
	y := track.min.y + at
	thumb = {{track.min.x, y}, {track.max.x, y + th}}
	ok = true
	return
}

// The track and the thumb a scroll box shows (ok = false: everything fits, no bar), window pixels. For tests and tools.
scrollbar_rects :: proc(b: ^Box) -> (track, thumb: Rect, ok: bool) { return scrollbar_geom(b) }

// Press on a scrollbar: remember where the thumb was grabbed (a press on the track centres the thumb there).
@(private)
scrollbar_press :: proc(s: ^State, sbk: Key, p: Vec2) {
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	_, thumb, has := scrollbar_geom(b)
	if !has { return }
	if p.y >= thumb.min.y && p.y < thumb.max.y { s.sb_grab = p.y - thumb.min.y } else { s.sb_grab = (thumb.max.y - thumb.min.y) * 0.5 }
}

// While a scrollbar is held, map the pointer to a scroll offset (applied at once, no easing: the thumb follows).
@(private)
scrollbar_drag :: proc(s: ^State) {
	sbk := s.active_key[.Left]
	owner, ok := s.sb_owner[sbk]
	if !ok { return }
	b := s.boxes[owner]
	if b == nil { return }
	track, thumb, has := scrollbar_geom(b)
	if !has { return }
	span := (track.max.y - track.min.y) - (thumb.max.y - thumb.min.y)
	if span <= 0 { return }
	t := clamp((s.mouse.y - s.sb_grab - track.min.y) / span, 0, 1)
	b.view_target.y = t * (b.view_bounds.y - b.size.y)
	b.view_off.y = b.view_target.y
	s.anim_busy = true
}

@(private)
draw_scrollbar :: proc(s: ^State, dc: ^draw.Context, b: ^Box) {
	track, thumb, ok := scrollbar_geom(b)
	if !ok { return }
	sbk := scrollbar_key(b)
	hot := s.hot_key == sbk
	active := s.active_key[.Left] == sbk
	c := color_from_tags(s, b.tags_key, "text")
	w := track.max.x - track.min.x
	if hot || active {
		tc := c; tc.a = SCROLLBAR_TRACK_HOT_ALPHA
		draw.rect(dc, track, tuned(tc), w * 0.5 * s.rounding)
	}
	c.a = active ? SCROLLBAR_THUMB_HELD_ALPHA : (hot ? SCROLLBAR_THUMB_HOT_ALPHA : SCROLLBAR_THUMB_REST_ALPHA)
	draw.rect(dc, thumb, tuned(c), w * 0.5 * s.rounding)
}