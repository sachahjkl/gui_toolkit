package ui

// Wires the pure autoscroll state machine (autoscroll.odin) to the toolkit's scroll regions (boxes with
// .View_Scroll_X / .View_Scroll_Y). A middle press on such a box starts a session anchored where it was pressed; every
// frame while the session lives the pointer offset from the anchor is turned into a scroll velocity and integrated into
// the box's `view_target` against the frame's dt, so the glide is the same at 60 Hz and at 180 Hz. The anchor marker is
// drawn over the tree (draw_tree), and the cursor follows the direction.
//
// The session ends on a click of any button (the latched toggle mode), Escape, a wheel notch, the pointer leaving, or
// the box going away. It does not disturb the smooth wheel/keyboard scrolling of scroll_anim.odin: autoscroll writes
// `view_target` just as a wheel notch would, but every frame; the animation pass still eases `view_off` toward it,
// which keeps the motion smooth even if a frame is late.

import "core:math"
import "../draw"
import "../platform"

// Turns middle-click autoscroll on or off for every scroll region (off by default). An app that wants it calls this
// once after `init`; `set_autoscroll_settings` tunes the curve.
set_autoscroll_enabled :: proc(s: ^State, on: bool) {
	s.auto_enabled = on
	if !on { autoscroll_cancel(&s.auto); s.auto_box = 0 }
}

autoscroll_is_enabled :: proc(s: ^State) -> bool { return s.auto_enabled }

set_autoscroll_settings :: proc(s: ^State, cfg: Autoscroll_Settings) { s.auto_cfg = cfg; s.auto_cfg_set = true }
autoscroll_settings :: proc(s: ^State) -> Autoscroll_Settings { return s.auto_cfg_set ? s.auto_cfg : DEFAULT_AUTOSCROLL }

// Whether a session is live (an app may want to suppress its own middle-click behaviour while one runs).
autoscroll_running :: proc(s: ^State) -> bool { return s.auto.active }

// Called from process_events once the frame's input is resolved: starts, drives or ends the session. Runs after
// hit/scroll keys are known so it can pick the scroll box under a middle press and swallow the click that ends a
// latched session.
@(private)
autoscroll_handle_input :: proc(s: ^State) {
	if !s.auto_enabled {
		if s.auto.active { autoscroll_cancel(&s.auto); s.auto_box = 0 }
		return
	}
	cfg := autoscroll_settings(s)

	// a wheel notch, Escape or a left/right press ends a live session; a left/right press while latched is also the
	// click that latched sessions wait for (swallowed so it does nothing else).
	if s.auto.active {
		if s.scroll_delta != {} { autoscroll_cancel(&s.auto); s.auto_box = 0; return }
		if key_pressed_peek(.Escape) { _ = key_press(.Escape); autoscroll_cancel(&s.auto); s.auto_box = 0; return }
		if !s.mouse_valid { autoscroll_cancel(&s.auto); s.auto_box = 0; return }
	}

	// resolve each mouse event in order: a press/release of the middle button engages or ends hold mode; any other
	// click ends a latched session.
	for e in s.mouse_events {
		#partial switch e.kind {
		case .Mouse_Press:
			if s.auto.active && s.auto.latched {
				// the click that ends a latched session: swallow it (clear the pressed/clicked keys of this button)
				if autoscroll_click(&s.auto) { s.auto_box = 0; autoscroll_swallow(s, e.button) }
				continue
			}
			if e.button == .Middle && !s.auto.active {
				box := scroll_hit_test(s, e.pos)
				if box != 0 {
					b := s.boxes[box]
					if b != nil {
						axes := autoscroll_box_axes(b)
						autoscroll_begin(&s.auto, e.pos, axes, held = true, now_ms = s.time_ms)
						s.auto_box = box
						autoscroll_swallow(s, .Middle)   // the press itself does not click anything
					}
				}
			} else if s.auto.active && e.button != .Middle {
				autoscroll_cancel(&s.auto); s.auto_box = 0
			}
		case .Mouse_Release:
			if e.button == .Middle && s.auto.active && s.auto.held {
				if !autoscroll_release(&s.auto, cfg, s.time_ms) { s.auto_box = 0 }
			}
		}
	}

	if s.auto.active {
		autoscroll_point(&s.auto, s.mouse)
		// the box may be gone this build; verify next build in autoscroll_apply
		if s.auto_box != 0 {
			if b, ok := s.boxes[s.auto_box]; !ok || b == nil { autoscroll_cancel(&s.auto); s.auto_box = 0 }
		}
	}
}

// The axes a scroll box offers, for the marker and the velocity.
@(private)
autoscroll_box_axes :: proc(b: ^Box) -> Autoscroll_Axes {
	x := .View_Scroll_X in b.flags
	y := .View_Scroll_Y in b.flags
	if x && y { return .Both }
	if x { return .X }
	return .Y
}

// Clears the pressed / clicked / active record of a button for this frame so a swallowed press does nothing else.
@(private)
autoscroll_swallow :: proc(s: ^State, btn: platform.Mouse_Button) {
	s.pressed_key[btn] = 0
	s.pressed_any[btn] = false
	s.clicked_key[btn] = 0
	s.active_key[btn] = 0
	s.released_key[btn] = 0
}

// Called by update_animations each frame: integrates the velocity into the active box's scroll target and keeps the
// frame loop awake while the session lives.
@(private)
autoscroll_apply :: proc(s: ^State) {
	if !s.auto.active || s.auto_box == 0 { return }
	b, ok := s.boxes[s.auto_box]
	if !ok || b == nil || b.last_build != s.build_index {
		autoscroll_cancel(&s.auto); s.auto_box = 0
		return
	}
	cfg := autoscroll_settings(s)
	s.cursor_request = autoscroll_cursor(&s.auto, cfg)
	vel := autoscroll_velocity(&s.auto, cfg)   // scroll units per second
	if vel == {} {
		// in the dead zone: nothing to move, but stay awake so a later pointer move is picked up at once
		s.anim_busy = true
		return
	}
	dt := f64(s.dt)
	step := Vec2{f32(f64(vel.x) * dt), f32(f64(vel.y) * dt)}
	limit := Vec2{max(0, b.view_bounds.x - b.size.x), max(0, b.view_bounds.y - b.size.y)}
	if .View_Scroll_X in b.flags { b.view_target.x = clamp(b.view_target.x + step.x, 0, limit.x) }
	if .View_Scroll_Y in b.flags { b.view_target.y = clamp(b.view_target.y + step.y, 0, limit.y) }
	s.anim_busy = true
}

////////////////////////////////
// Marker

// The anchor marker a browser draws: a soft round plate with a thin ring, and small chevrons pointing in the
// directions the area can scroll. Drawn over the whole tree (after draw_box) so nothing hides it.
@(private)
autoscroll_draw :: proc(s: ^State, dc: ^draw.Context) {
	if !s.auto.active { return }
	c := s.auto.anchor
	r := math.round(13 * s.scale)
	plate := color_from_tags(s, 0, "background")
	ring := color_from_tags(s, 0, "text")
	// plate: a filled disc with a soft edge, then the ring on top
	disc := plate; disc.a = 0.9
	draw.rect(dc, {{c.x - r, c.y - r}, {c.x + r, c.y + r}}, tuned(disc), r, 0, 1.5 * s.scale)
	rc := ring; rc.a = 0.5
	draw.rect(dc, {{c.x - r, c.y - r}, {c.x + r, c.y + r}}, tuned(rc), r, max(1, math.round(1.5 * s.scale)))
	// a dot at the centre
	dot := ring; dot.a = 0.55
	dr := max(1.5, math.round(2 * s.scale))
	draw.rect(dc, {{c.x - dr, c.y - dr}, {c.x + dr, c.y + dr}}, tuned(dot), dr)
	// chevrons for the available directions
	arrow := ring; arrow.a = 0.75
	ac := tuned(arrow)
	gap := math.round(6 * s.scale)
	axes := s.auto.axes
	if axes == .Y || axes == .Both {
		autoscroll_chevron(dc, {c.x, c.y - gap}, .Up, s.scale, ac)
		autoscroll_chevron(dc, {c.x, c.y + gap}, .Down, s.scale, ac)
	}
	if axes == .X || axes == .Both {
		autoscroll_chevron(dc, {c.x - gap, c.y}, .Left, s.scale, ac)
		autoscroll_chevron(dc, {c.x + gap, c.y}, .Right, s.scale, ac)
	}
}

@(private) Chevron_Dir :: enum u8 { Up, Down, Left, Right }

// A small two-stroke chevron (a ">" turned the right way) drawn from short rects: the toolkit has no triangle
// primitive, so two thin bars meeting at the point make the arrowhead.
@(private)
autoscroll_chevron :: proc(dc: ^draw.Context, tip: Vec2, dir: Chevron_Dir, scale: f32, c: Color) {
	l := math.round(4 * scale)     // half-length of each stroke
	t := max(1, math.round(1.5 * scale))   // stroke thickness
	// two dots stepping back from the tip make a compact arrowhead that reads at any size
	step :: proc(tip: Vec2, dir: Chevron_Dir, i: f32, l: f32) -> (a, b: Vec2) {
		d := l * i
		switch dir {
		case .Up:    return {tip.x - d, tip.y + d}, {tip.x + d, tip.y + d}
		case .Down:  return {tip.x - d, tip.y - d}, {tip.x + d, tip.y - d}
		case .Left:  return {tip.x + d, tip.y - d}, {tip.x + d, tip.y + d}
		case .Right: return {tip.x - d, tip.y - d}, {tip.x - d, tip.y + d}
		}
		return tip, tip
	}
	for i in ([]f32{0, 1}) {
		a, b := step(tip, dir, i, l * 0.5)
		for p in ([]Vec2{a, b}) {
			draw.rect(dc, {{p.x - t, p.y - t}, {p.x + t, p.y + t}}, c, t)
		}
	}
}
