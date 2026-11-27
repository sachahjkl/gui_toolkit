package scenarios_test

// The look of a row of tabs (src/md/features/tabs.md) at 100, 125 and 150 %, `ui.tabs` in a program's row wider than its
// tabs (fidget's, the debug window's): the line along the row's bottom lies on whole pixels (no blurred row above it),
// and the chosen last tab has a foot on each side (mirror images), the line curving up into it.

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") FACE_SIZE :: [2]int{600, 120}
@(private = "file") FACE_LABELS := [?]string{"Alpha", "Beta", "Gamma"}
@(private = "file") FACE_SCALES := [?]f32{1, 1.25, 1.5}

@(private = "file")
Face_Run :: struct { chosen: int }

@(private = "file")
face_build :: proc(s: ^session.Session) {
	r := (^Face_Run)(s.user)
	ui.next({width = ui.fill(), height = ui.px(math.round(ui.font_size() * 2.6)), axis = .X})
	row: ^ui.Box
	if ui.tags("bar") { row = ui.build_box({.Draw_Background}, "###tab_row") }
	row.custom = ui.tab_line_draw
	if ui.parent(row) { _ = ui.tabs("tabs", FACE_LABELS[:], nil, &r.chosen) }
}

@(private = "file")
rgba :: proc(c: u32) -> session.Color { return {u8(c >> 24), u8(c >> 16), u8(c >> 8), u8(c)} }

@(test)
the_line_is_sharp_and_a_tab_inside_the_row_has_both_feet :: proc(t: ^testing.T) {
	for scale in FACE_SCALES {
		run := Face_Run{chosen = len(FACE_LABELS) - 1}
		s := session.start(t, {build = face_build, user = &run, size = FACE_SIZE, dpi_scale = scale})
		session.move(s, {f32(FACE_SIZE.x) - 5, f32(FACE_SIZE.y) - 5})
		session.frames(s, 3)
		row := session.get(s, "tab_row")
		last := session.get(s, fmt.tprintf("tabs_%d", len(FACE_LABELS) - 1))
		img := session.capture(s)
		line := rgba(ui.palette_of("Midnight").border)
		ground := session.pixel(img, int(row.rect.max.x) - 10, int(row.rect.min.y) + 4)
		testing.expectf(t, row.rect.max.y == math.round(row.rect.max.y), "at %v: the row ends on a whole pixel (%v)", scale, row.rect.max.y)
		// the line on the row's empty part, past the tabs: its rows the border's colour, the row above it the bar's
		p := int(max(1, math.round(scale)))
		bottom := int(row.rect.max.y)
		x := int(row.rect.max.x) - 20
		for y in bottom - p ..< bottom {
			testing.expectf(t, session.near(session.pixel(img, x, y), line, 4), "at %v: the line's row %d is %v, the border %v", scale, y, session.pixel(img, x, y), line)
		}
		// every column of the line is the border's but under the chosen tab and its feet, where the line curves up into it
		// (no outline's end on it, nothing under it)
		page := rgba(ui.palette_of("Midnight").bg)
		// (the foot's reach: the control radius at the session's text size and scale, a pixel's slack)
		foot := int(math.round(f32(session.BASE_FONT_SIZE) * scale * ui.SHAPE_DEFAULT[.Control])) + p
		spill, under := 0, 0
		for c in 0 ..< int(row.rect.max.x) {
			if c >= int(last.rect.min.x) - foot && c < int(last.rect.max.x) + foot { continue }
			for y in bottom - p ..< bottom { if !session.near(session.pixel(img, c, y), line, 4) { spill += 1 } }
			if !session.near(session.pixel(img, c, bottom), page, 4) { under += 1 }
		}
		testing.expectf(t, spill == 0, "at %v: %d pixels of the line are not the border's", scale, spill)
		testing.expectf(t, under == 0, "at %v: %d pixels under the line are not the page's", scale, under)
		above := session.pixel(img, x, bottom - p - 1)
		testing.expectf(t, session.near(above, ground, 4), "at %v: the row above the line is the bar's (%v), not a blur (%v)", scale, ground, above)
		// the chosen last tab is not at the row's end: its right foot mirrors its left one (no straight side)
		// (two device pixels out and three up: inside the foot, clear of the next tab's outline)
		x0, x1 := int(last.rect.min.x), int(last.rect.max.x)
		differ := 0
		for k in 0 ..< 2 * p {
			for y in bottom - 4 * p ..< bottom - p {
				if !session.near(session.pixel(img, x0 - 1 - k, y), session.pixel(img, x1 + k, y), 12) { differ += 1 }
			}
		}
		testing.expectf(t, differ <= p, "at %v: the chosen tab's right side is not the mirror of its left one (%d pixels differ)", scale, differ)
	}
}

// The keyboard's focus on a tab goes round the shape a person sees: nothing of the ring over the strip's ground above
// it, and the ring at the shape's top.
@(test)
the_focus_ring_follows_the_tabs_shape :: proc(t: ^testing.T) {
	run := Face_Run{chosen = 1}
	s := session.start(t, {build = face_build, user = &run, size = FACE_SIZE, dpi_scale = 1.5})
	session.move(s, {f32(FACE_SIZE.x) - 5, f32(FACE_SIZE.y) - 5})
	session.frames(s, 2)
	session.key(s, .Tab)
	session.frames(s, 6)
	tab := session.get(s, "tabs_1")
	if !testing.expect(t, s.state.focus_key == tab.key, "the chosen tab has the keyboard") { return }
	img := session.capture(s)
	row := session.get(s, "tab_row")
	ground := session.pixel(img, int(row.rect.max.x) - 10, int(row.rect.min.y) + 4)
	mid := int(session.center(tab).x)
	testing.expectf(t, session.near(session.pixel(img, mid, int(tab.rect.min.y) + 1), ground, 4), "the strip's ground above the tab, no ring: %v", session.pixel(img, mid, int(tab.rect.min.y) + 1))
	// (down the tab's middle, the first row that is not the strip's ground: the ring, at the shape's top)
	top := -1
	for y in int(tab.rect.min.y) ..< int(tab.rect.max.y) {
		if !session.near(session.pixel(img, mid, y), ground, 4) { top = y; break }
	}
	testing.expectf(t, top > int(tab.rect.min.y) + 2, "the ring's top at the shape's top, below the box's: row %d, the box from %v", top, tab.rect.min.y)
}
