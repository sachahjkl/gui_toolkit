package ui

import "core:fmt"
import "core:math"
import "../platform"

_ :: fmt   // used by the UI_PROBE debug output only

// Input is resolved once per frame, in begin_build, against LAST frame's layout (the tree is still intact at that
// point): hot / active / pressed / clicked keys are plain lookups afterwards, so `signal` is just a comparison.

@(private)
process_events :: proc(s: ^State, events: []platform.Event, zoom_keys: bool) {
	clear(&s.events.list)
	clear(&s.events.consumed)
	clear(&s.typed)
	clear(&s.mouse_events)
	left := platform.Mouse_Button.Left
	s.mouse_moved = false

	for e in events {
		#partial switch e.kind {
		case .Mouse_Move:
			if e.pos != s.mouse { s.mouse_moved = true }
			s.mouse = e.pos
			s.mouse_valid = true
		case .Mouse_Leave:
			s.mouse_valid = false
		case .Mouse_Press:
			append(&s.mouse_events, e)
			s.mouse = e.pos
			s.mouse_valid = true
			s.mods = e.mods
			hot := hit_test(s, e.pos)
			when #config(UI_PROBE, false) {
				hb := s.boxes[hot] if hot != 0 else nil
				fmt.eprintf("press pos=(%.0f,%.0f) hit=%v rect=%v text=%q\n", e.pos.x, e.pos.y, hot, hb != nil ? hb.rect : Rect{}, hb != nil ? hb.text : "")
			}
			s.active_key[e.button] = hot
			s.press_pos[e.button] = e.pos
			s.pressed_key[e.button] = hot
			s.pressed_any[e.button] = true
			if e.button == .Left { scrollbar_press(s, hot, e.pos) }
			if e.button == .Left {
				if hot != 0 && hot == s.last_click_key && s.time_ms - s.last_click_ms < 400 {
					s.double_key = hot
					s.last_click_key = 0
				} else {
					s.last_click_key = hot
					s.last_click_ms = s.time_ms
				}
				// keyboard focus follows the click
				b := s.boxes[hot] if hot != 0 else nil
				s.focus_key = (b != nil && .Focusable in b.flags) ? hot : 0
				s.focus_visible = false
			}
		case .Mouse_Release:
			append(&s.mouse_events, e)
			s.mouse = e.pos
			hot := hit_test(s, e.pos)
			s.released_key[e.button] = s.active_key[e.button]
			if s.active_key[e.button] != 0 && s.active_key[e.button] == hot { s.clicked_key[e.button] = hot }
			s.active_key[e.button] = 0
		case .Scroll:
			s.mouse = e.pos
			s.mouse_valid = true   // (the wheel is where its event says: a first notch with no move before it scrolls too)
			if zoom_keys && .Ctrl in e.mods {
				// Ctrl+wheel zooms (wheel up = delta.y < 0 = bigger) instead of scrolling
				s.zoom = clamp(s.zoom * math.pow(ZOOM_STEP, -e.delta.y), ZOOM_MIN, ZOOM_MAX)
			} else {
				s.scroll_delta += e.delta
			}
		case .Text:
			append(&s.typed, e.text)
		case .Key_Press:
			s.mods = e.mods
			if zoom_keys && .Ctrl in e.mods && .Alt not_in e.mods {
				#partial switch e.key {
				case .Equal, .Num_Add: s.zoom = clamp(s.zoom * ZOOM_STEP, ZOOM_MIN, ZOOM_MAX); continue
				case .Minus, .Num_Subtract: s.zoom = clamp(s.zoom / ZOOM_STEP, ZOOM_MIN, ZOOM_MAX); continue
				case .N0:    s.zoom = 1; continue
				case:
				}
			}
			append(&s.events.list, e)
			append(&s.events.consumed, false)
		case:
		}
	}
	_ = left

	// hot box: the topmost clickable box under the mouse; while a button is held, only the pressed box can be hot
	hit: Key
	if s.mouse_valid { hit = hit_test(s, s.mouse) }
	active := s.active_key[.Left]
	s.hot_key = (active == 0 || hit == active) ? hit : 0
	scrollbar_drag(s)
	s.scroll_key = (s.scroll_delta != {} && s.mouse_valid) ? scroll_hit_test(s, s.mouse) : 0
	if s.hot_key != s.hover_key { s.hover_key = s.hot_key; s.hover_since_ms = s.time_ms }
	autoscroll_handle_input(s)   // middle-click autoscroll (autoscroll_region.odin): after hit tests, may swallow clicks
}

// Topmost Clickable box at `p`: later siblings draw on top, so walk them last to first.
@(private)
hit_test :: proc(s: ^State, p: Vec2) -> Key {
	if s.root == nil { return 0 }
	return hit_test_box(s.root, p, s.root.rect)
}

@(private)
hit_test_box :: proc(b: ^Box, p: Vec2, clip: Rect) -> Key {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return 0 }
	if track, _, ok := scrollbar_geom(b); ok {
		grab := Rect{{track.min.x - 4, track.min.y}, {track.max.x + 2, track.max.y}}   // a little wider than it looks (toward the content)
		if .Scrollbar_Left in b.flags { grab.min.x, grab.max.x = track.min.x - 2, track.max.x + 4 }
		if contains(grab, p) {
			k := scrollbar_key(b)
			g.sb_owner[k] = b.key
			return k
		}
	}
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		if k := hit_test_box(c, p, child_clip); k != 0 { return k }
	}
	if .Clickable in b.flags && .Disabled not_in b.flags && box_contains(b, p) { return b.key }
	return 0
}

// Whether `p` is on the box's shape: its rect, or the trapezoid `slant` makes of it.
box_contains :: proc(b: ^Box, p: Vec2) -> bool {
	if b.slant == {} { return contains(b.rect, p) }
	return platform.slanted_contains({b.rect.min, b.rect.max, b.slant}, p)
}

@(private)
scroll_hit_test :: proc(s: ^State, p: Vec2) -> Key {
	if s.root == nil { return 0 }
	return scroll_hit_box(s.root, p, s.root.rect)
}

@(private)
scroll_hit_box :: proc(b: ^Box, p: Vec2, clip: Rect) -> Key {
	if !(p.x >= clip.min.x && p.x < clip.max.x && p.y >= clip.min.y && p.y < clip.max.y) { return 0 }
	child_clip := clip
	if .Clip in b.flags {
		child_clip = Rect{{max(clip.min.x, b.rect.min.x), max(clip.min.y, b.rect.min.y)}, {min(clip.max.x, b.rect.max.x), min(clip.max.y, b.rect.max.y)}}
	}
	for c := b.last; c != nil; c = c.prev {
		if k := scroll_hit_box(c, p, child_clip); k != 0 { return k }
	}
	if (.View_Scroll_X in b.flags || .View_Scroll_Y in b.flags || .Scroll_Self in b.flags) && contains(b.rect, p) { return b.key }
	return 0
}

@(private)
contains :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }

// Consuming keyboard query: true once if a matching key press (exact modifiers) is pending.
key_press :: proc(key: platform.Key, mods: platform.Modifiers = {}) -> bool {
	s := g
	for e, i in s.events.list {
		if s.events.consumed[i] || e.key != key || e.mods != mods { continue }
		s.events.consumed[i] = true
		return true
	}
	return false
}

// Like key_press but does not consume (for global shortcuts that must not steal keys from a focused field).
key_pressed_peek :: proc(key: platform.Key, mods: platform.Modifiers = {}) -> bool {
	s := g
	for e, i in s.events.list { if !s.events.consumed[i] && e.key == key && e.mods == mods { return true } }
	return false
}

mouse_pos :: proc() -> Vec2 { return g.mouse }
// A press of `button` happened in this frame, on anything or on nothing (a popup the app closes on a press outside it).
mouse_pressed :: proc(button := platform.Mouse_Button.Left) -> bool { return g.pressed_any[button] }
hot_key :: proc() -> Key { return g.hot_key }

// Is the pointer on box `key` or on a clickable box inside it (by the last frame's tree)? For a row that shows its
// buttons while the pointer is anywhere on it.
hot_within :: proc(key: Key) -> bool {
	s := g
	if s.hot_key == 0 || key == 0 { return false }
	hb := s.boxes[s.hot_key] if s.hot_key != 0 else nil
	for p, depth := hb, 0; p != nil && depth < 64; p, depth = p.parent, depth + 1 {
		if p.key == key { return true }
		if p.last_build + 1 < s.build_index { break }
	}
	return false
}
active_key :: proc() -> Key { return g.active_key[.Left] }
focus_key :: proc() -> Key { return g.focus_key }
set_focus :: proc(k: Key) { g.focus_key = k }

// The signal of a box (call after building it, usually through a widget).
signal :: proc(b: ^Box) -> (sig: Signal) {
	s := g
	sig.box = b
	sig.mouse = s.mouse - b.rect.min
	sig.mods = s.mods
	sig.focused = s.focus_key == b.key
	if .Disabled in b.flags { return }
	if .Clickable in b.flags {
		sig.hovering = s.hot_key == b.key
		sig.pressed = s.pressed_key[.Left] == b.key
		sig.released = s.released_key[.Left] == b.key
		sig.clicked = s.clicked_key[.Left] == b.key
		sig.double_clicked = s.double_key == b.key
		sig.right_clicked = s.clicked_key[.Right] == b.key
		sig.middle_clicked = s.clicked_key[.Middle] == b.key
		if s.active_key[.Left] == b.key {
			sig.dragging = true
			sig.drag_delta = s.mouse - s.press_pos[.Left]
		}
		if sig.hovering && b.cursor != .Arrow { s.cursor_request = b.cursor }
		// keyboard activation of the focused Tab stop (text inputs handle their own keys)
		// (not while a context menu is open: Enter / Space then belong to the menu)
		if sig.focused && .Focusable in b.flags && .Text_Input not_in b.flags && len(s.menus) == 0 {
			if key_press(.Return) || key_press(.Space) {
				sig.clicked, sig.pressed, sig.released = true, true, true
			}
		}
	}
	if .Scroll_Self in b.flags && s.scroll_key == b.key { sig.scrolled = s.scroll_delta }
	if (.View_Scroll_X in b.flags || .View_Scroll_Y in b.flags) && s.scroll_key == b.key {
		step := b.font_size * 4
		d := s.scroll_delta
		if .View_Scroll_X in b.flags { b.view_target.x += d.x * step; sig.scrolled.x = d.x }
		if .View_Scroll_Y in b.flags { b.view_target.y += d.y * step; sig.scrolled.y = d.y }
		// clamp against last frame's bounds; the animation pass re-clamps with fresh ones
		limit := Vec2{max(0, b.view_bounds.x - b.size.x), max(0, b.view_bounds.y - b.size.y)}
		b.view_target = {clamp(b.view_target.x, 0, limit.x), clamp(b.view_target.y, 0, limit.y)}
	}
	return
}
