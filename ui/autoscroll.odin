package ui

// Middle-click autoscroll, as Chrome, Firefox and Edge do it on Windows: a press of the middle button on a scrollable
// area drops an anchor; moving the pointer away from the anchor scrolls, the farther the faster, along an acceleration
// curve. A marker (a ring with arrows for the directions that can scroll) is drawn at the anchor, and the cursor shows
// the direction. The mode ends on a click of any button, Escape, loss of the pointer capture, a wheel notch or a move
// of the window.
//
// This module is PURE and free of any platform or box dependency on its own: `Autoscroll` holds the state, and
// `autoscroll_velocity` turns a pointer-to-anchor offset into a scroll velocity. A host (the toolkit's scroll regions,
// or an application's document view) owns one `Autoscroll` per active session, feeds it pointer offsets and dt, and
// applies the returned velocity to whatever it scrolls. See `autoscroll_state` in state.odin for the toolkit's own
// wiring of the scroll regions, and the unit tests in tests/autoscroll.
//
// Two engagement modes, both of them live at once (like the browsers):
//   * Hold:   press, keep the button down, move, release -> the move ends when the button is released.
//   * Toggle: a quick press and release (shorter than `tap_ms`, with little movement) latches the mode on; it stays on,
//             scrolling as the pointer moves, until the next click anywhere.
// The host tells the two apart by watching the button and the elapsed time (autoscroll_press / autoscroll_release).

import "core:math"
import "../platform"

// How the speed grows with the distance of the pointer from the anchor. All distances are in the host's pointer units
// (logical pixels for the toolkit); the returned speed is in scroll units per second. Pure and fully parameterised so
// it can be unit tested on its own.
Autoscroll_Settings :: struct {
	dead_zone:  f32,   // no scroll while the pointer is within this many px of the anchor (a disc)
	max_speed:  f32,   // speed cap, scroll units per second, reached at `full_dist` from the edge of the dead zone
	full_dist:  f32,   // distance past the dead zone at which the speed reaches `max_speed`
	exponent:   f32,   // curve shape: 1 = linear, > 1 = gentle near the anchor and steep far out (power curve)
	toggle:     bool,  // a quick tap latches the mode on (toggle mode); always paired with hold here
	tap_ms:     f32,   // a press shorter than this, with little movement, is a tap: it latches toggle mode
	tap_slop:   f32,   // a press that moved more than this many px before release is a drag, never a tap
}

DEFAULT_AUTOSCROLL :: Autoscroll_Settings{
	dead_zone = 12,
	max_speed = 2800,
	full_dist = 420,
	exponent  = 2,
	toggle    = true,
	tap_ms    = 250,
	tap_slop  = 4,
}

// The scroll axes an area offers: a marker and the velocity are limited to these. Most document views scroll on Y only;
// a pane that scrolls both ways offers the four directions.
Autoscroll_Axes :: enum u8 { Y, X, Both }

Autoscroll :: struct {
	active:    bool,
	latched:   bool,     // toggle mode: on until the next click (no button held)
	axes:      Autoscroll_Axes,
	anchor:    Vec2,     // where the marker sits (host pointer coordinates)
	pointer:   Vec2,     // last pointer position fed in
	press_ms:  f64,      // when the engaging press happened (for the tap test); 0 when latched without a held button
	press_pos: Vec2,     // where the engaging press happened (for the tap-slop test)
	moved:     f32,      // greatest distance from press_pos seen while the button was held (tap-slop test)
	held:      bool,     // the engaging button is still down (hold mode in progress)
}

// The velocity, in scroll units per second, the pointer offset from the anchor asks for on one axis. Pure: a dead zone
// around the anchor (|off| <= dead_zone -> 0), then a curve that rises with the distance, is clamped to max_speed, and
// is symmetric about the anchor (f(-x) == -f(x)). With exponent 1 it is linear; above 1 it eases in near the dead zone
// and climbs faster far out. Independent of frame rate: it is a speed, integrated by the caller against its own dt.
autoscroll_axis_speed :: proc(off: f32, cfg: Autoscroll_Settings) -> f32 {
	dead := max(cfg.dead_zone, 0)
	mag := abs(off)
	if mag <= dead { return 0 }
	full := max(cfg.full_dist, 1)
	t := clamp((mag - dead) / full, 0, 1)
	exp := max(cfg.exponent, 0.01)
	shaped := math.pow(t, exp)
	speed := shaped * cfg.max_speed
	return off < 0 ? -speed : speed
}

// The velocity vector (scroll units per second) for a pointer at `pointer`, given the anchor and the axes the area
// offers. The returned vector is zero on an axis the area does not scroll.
autoscroll_velocity :: proc(a: ^Autoscroll, cfg: Autoscroll_Settings) -> Vec2 {
	off := a.pointer - a.anchor
	v: Vec2
	if a.axes == .X || a.axes == .Both { v.x = autoscroll_axis_speed(off.x, cfg) }
	if a.axes == .Y || a.axes == .Both { v.y = autoscroll_axis_speed(off.y, cfg) }
	return v
}

// Starts a session at `anchor`, scrolling the given axes. `held` tells whether the engaging button is down (hold mode
// may still turn into a latched toggle on a quick release). `now_ms` is the press time for the tap test.
autoscroll_begin :: proc(a: ^Autoscroll, anchor: Vec2, axes: Autoscroll_Axes, held: bool, now_ms: f64) {
	a^ = Autoscroll{
		active    = true,
		axes      = axes,
		anchor    = anchor,
		pointer   = anchor,
		press_ms  = now_ms,
		press_pos = anchor,
		held      = held,
	}
}

// Feeds the latest pointer position (host coordinates) and updates the tap-slop distance while a button is held.
autoscroll_point :: proc(a: ^Autoscroll, pointer: Vec2) {
	if !a.active { return }
	a.pointer = pointer
	if a.held {
		d := pointer - a.press_pos
		a.moved = max(a.moved, math.sqrt(d.x * d.x + d.y * d.y))
	}
}

// The engaging button was released at `now_ms`. In a short, still press (a tap), toggle mode latches on and the session
// stays active with no button held; otherwise (hold mode) the session ends. Returns whether the session is still
// active. A later click (any button) ends a latched session: the host calls `autoscroll_click`.
autoscroll_release :: proc(a: ^Autoscroll, cfg: Autoscroll_Settings, now_ms: f64) -> (active: bool) {
	if !a.active || !a.held { return a.active }
	a.held = false
	tap := cfg.toggle && (now_ms - a.press_ms) <= f64(cfg.tap_ms) && a.moved <= cfg.tap_slop
	if tap {
		a.latched = true
		a.press_ms = 0
		return true
	}
	a.active = false
	return false
}

// A click happened (any button): a latched (toggle) session ends on it. Returns whether the click was consumed to end
// the session (the host should then swallow it, as the browsers do: the click that stops autoscroll does nothing else).
autoscroll_click :: proc(a: ^Autoscroll) -> (ended: bool) {
	if a.active && a.latched {
		a.active, a.latched = false, false
		return true
	}
	return false
}

// Ends the session for any other reason (Escape, a wheel notch, lost capture, a window move, the area going away).
autoscroll_cancel :: proc(a: ^Autoscroll) {
	a^ = {}
}

autoscroll_active :: proc(a: ^Autoscroll) -> bool { return a.active }

// The cursor that fits the current pointer offset: All_Scroll in the dead zone, else the directional resize cursor
// closest to the offset (the eight compass directions, restricted to the axes the area scrolls). A host whose cursor
// API lacks these falls back to All_Scroll for the whole session.
autoscroll_cursor :: proc(a: ^Autoscroll, cfg: Autoscroll_Settings) -> platform.Cursor {
	off := a.pointer - a.anchor
	if a.axes == .Y { off.x = 0 }
	if a.axes == .X { off.y = 0 }
	mag := math.sqrt(off.x * off.x + off.y * off.y)
	if mag <= max(cfg.dead_zone, 0) { return .All_Scroll }
	// angle of the offset (y down): pick the nearest of the eight compass directions the area allows
	ax, ay := abs(off.x), abs(off.y)
	up, down := off.y < 0, off.y > 0
	left, right := off.x < 0, off.x > 0
	if a.axes == .Y { return down ? .Resize_S : .Resize_N }
	if a.axes == .X { return right ? .Resize_E : .Resize_W }
	// both axes: diagonal when the two components are within ~2.4x of each other, else the dominant one
	diag := ax > ay * 0.41 && ay > ax * 0.41
	switch {
	case diag && up && right:   return .Resize_NE
	case diag && up && left:    return .Resize_NW
	case diag && down && right: return .Resize_SE
	case diag && down && left:  return .Resize_SW
	case ax >= ay && right:     return .Resize_E
	case ax >= ay:              return .Resize_W
	case down:                  return .Resize_S
	case:                       return .Resize_N
	}
}
