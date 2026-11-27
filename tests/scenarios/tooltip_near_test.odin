package scenarios_test

// ui.tooltip_near: a tooltip about a rectangle, on the side that covers the least of it, inside the window, at each of
// the window's edges.

import "core:testing"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file") WINDOW :: [2]int{600, 400}

@(private = "file")
Near :: struct {
	at: ui.Rect,
}

@(private = "file")
build :: proc(s: ^session.Session) {
	n := (^Near)(s.user)
	if ui.tooltip_near(n.at) { _ = ui.tooltip_text("What the rectangle is about, in a few words") }
}

// The tooltip's rectangle with the anchor `at` (frames enough to measure it, then place it).
@(private = "file")
tip_at :: proc(s: ^session.Session, n: ^Near, at: ui.Rect) -> ui.Rect {
	n.at = at
	session.frames(s, 3)
	return session.get(s, "tooltip").rect
}

@(private = "file")
inside :: proc(r: ui.Rect) -> bool {
	return r.min.x >= 0 && r.min.y >= 0 && r.max.x <= f32(WINDOW.x) && r.max.y <= f32(WINDOW.y)
}

@(test)
a_tooltip_near_a_rectangle_takes_the_side_with_room :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	n: Near
	s := session.start(t, {size = WINDOW, user = &n, build = build})

	// room everywhere: below
	at := ui.Rect{{250, 40}, {350, 70}}
	tip := tip_at(s, &n, at)
	testing.expectf(t, tip.min.y >= at.max.y && inside(tip), "below: %v", tip)
	testing.expect(t, abs((tip.min.x + tip.max.x) * 0.5 - 300) < 1, "centred under it")

	// at the bottom edge: above
	at = {{250, 360}, {350, 390}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, tip.max.y <= at.min.y && inside(tip), "above: %v", tip)

	// a column as tall as the window on its left edge: to its right
	at = {{0, 0}, {150, f32(WINDOW.y)}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, tip.min.x >= at.max.x && inside(tip), "right: %v", tip)

	// the same on its right edge: to its left
	at = {{450, 0}, {f32(WINDOW.x), f32(WINDOW.y)}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, tip.max.x <= at.min.x && inside(tip), "left: %v", tip)

	// in the top-left corner: below, moved inside the window
	at = {{0, 0}, {40, 20}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, tip.min.y >= at.max.y && inside(tip), "below, inside: %v", tip)

	// a rectangle larger than the window: it covers some of it on every side, and stays inside
	at = {{-100, -80}, {f32(WINDOW.x) + 100, f32(WINDOW.y) + 80}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, inside(tip), "inside: %v", tip)

	// one that reaches past the bottom-right corner: above it or left of it, inside
	at = {{400, 300}, {f32(WINDOW.x) + 200, f32(WINDOW.y) + 200}}
	tip = tip_at(s, &n, at)
	testing.expectf(t, inside(tip) && (tip.max.y <= at.min.y || tip.max.x <= at.min.x), "above or left, inside: %v", tip)
}) }
