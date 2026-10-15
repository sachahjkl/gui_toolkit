package ui

// Scrollbars for every vertical scroll region (boxes with .View_Scroll_Y whose content is taller than the box),
// and corner rounding control. Scrollbars are drawn over the content at the right edge, can be dragged, and a
// press on the track jumps there.

import "core:math"
import "../draw"

// Corner rounding factor for every rounded shape the toolkit draws: 0 = square corners, 1 = default, up to 2.
set_rounding :: proc(s: ^State, r: f32) { s.rounding = clamp(r, 0, 2) }
rounding :: proc(s: ^State) -> f32 { return s.rounding }

// A radius scaled by the current rounding (for custom draw procs that want to follow the setting).
rad :: proc(r: f32) -> f32 { return r * g.rounding }

@(private)
scrollbar_key :: proc(b: ^Box) -> Key { return key_from_u64(b.key, 0x5c5c_5c5c) }

// Track and thumb rects of a scroll box, or ok = false when everything fits.
@(private)
scrollbar_geom :: proc(b: ^Box) -> (track, thumb: Rect, ok: bool) {
	view := b.size.y
	content := b.view_bounds.y
	if .View_Scroll_Y not_in b.flags || content <= view + 0.5 || view < 8 { return }
	w := max(6, math.round(b.font_size * 0.5))
	m := math.round(w * 0.35)
	track = {{b.rect.max.x - w - m, b.rect.min.y + m}, {b.rect.max.x - m, b.rect.max.y - m}}
	th_avail := track.max.y - track.min.y
	th := max(b.font_size * 1.6, th_avail * view / content)
	maxoff := content - view
	t := clamp(b.view_off.y / maxoff, 0, 1)
	y := track.min.y + t * (th_avail - th)
	thumb = {{track.min.x, y}, {track.max.x, y + th}}
	ok = true
	return
}

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
		tc := c; tc.a = 0.06
		draw.rect(dc, track, tc, w * 0.5 * s.rounding)
	}
	c.a = active ? 0.55 : (hot ? 0.4 : 0.22)
	draw.rect(dc, thumb, c, w * 0.5 * s.rounding)
}