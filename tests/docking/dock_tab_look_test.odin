// The look of a dock's tabs (src/md/features/tabs.md): the strip's line, out of which the chosen tab rises joined to its
// panel; every tab with both feet, the first a foot's room and a short run of the line from the stack's edge; the other tabs with no face; the words in the middle of the shape; a tab's
// close button hidden at rest on the others, its room kept.
//   odin test tests/docking -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package docking_test

import "core:fmt"
import "core:math"
import "core:testing"
import "gt:testkit/session"
import "gt:ui"

@(private = "file") LOOK_SIZE :: [2]int{700, 300}
@(private = "file") LOOK_TITLES := [?]string{"", "Alpha", "Beta", "Gamma"}

@(private = "file")
Look_App :: struct { dock: ui.Dock }

@(private = "file")
look_build :: proc(s: ^session.Session) {
	app := (^Look_App)(s.user)
	ui.dock_begin(&app.dock, "###dock", {title = proc(user: rawptr, id: u32) -> string { return LOOK_TITLES[id] }, user = app, close_buttons = true})
	for p in u32(1) ..< len(LOOK_TITLES) {
		if ui.dock_panel(&app.dock, p) {
			ui.spacer(ui.px(40))   // (the body's top rows hold no letter)
			ui.label(fmt.tprintf("%s content###content", LOOK_TITLES[p]))
		}
	}
	ui.dock_end(&app.dock)
}

@(private = "file")
rgba :: proc(c: u32) -> session.Color { return {u8(c >> 24), u8(c >> 16), u8(c >> 8), u8(c)} }

// One stack of three tabs, the first one shown, the pointer away from them.
@(private = "file")
look_setup :: proc(t: ^testing.T, app: ^Look_App) -> ^session.Session {
	ui.dock_init(&app.dock)
	testing.expect(t, ui.dock_parse(&app.dock, "dock1 [*a,b,c]", proc(user: rawptr, name: string) -> (u32, bool) {
		for n, i in ([?]string{"", "a", "b", "c"}) { if i > 0 && n == name { return u32(i), true } }
		return 0, false
	}, nil))
	s := session.start(t, {build = look_build, user = app, size = LOOK_SIZE})
	session.move(s, {f32(LOOK_SIZE.x) - 5, f32(LOOK_SIZE.y) - 5})
	session.frames(s, 3)
	return s
}

@(private = "file")
tab :: proc(app: ^Look_App, p: u32) -> ^ui.Box {
	return ui.box_from_key(ui.dock_tab_key(&app.dock, ui.dock_leaf_of(&app.dock, p), p))
}

@(test)
the_chosen_tab_rises_out_of_the_line_joined_to_its_panel :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup(t, &app)
	a, b := tab(&app, 1), tab(&app, 2)
	if !testing.expect(t, a != nil && b != nil, "the tabs") { return }
	img := session.capture(s)
	pal := ui.palette_of("Midnight")
	page, line := rgba(pal.bg), rgba(pal.border)
	stack := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect.min.x + app.dock.origin.x
	// the first tab a small inset from the stack's edge: its left foot's room and the line's short run (tab_strip_inset)
	testing.expect_value(t, a.rect.min.x - stack, look_inset(&app))
	testing.expect_value(t, a.rect.max.y - a.rect.min.y, f32(app.dock.metrics.strip))
	bottom := int(a.rect.max.y) - 1
	strip := session.pixel(img, LOOK_SIZE.x - 60, int(session.center(a).y))
	// the line under an unchosen tab and on the empty part of the strip; none under the chosen one
	testing.expectf(t, session.near(session.pixel(img, int(session.center(b).x), bottom), line, 6), "the line under an unchosen tab: %v, the border %v", session.pixel(img, int(session.center(b).x), bottom), line)
	testing.expectf(t, session.near(session.pixel(img, LOOK_SIZE.x / 2, bottom), line, 6), "the line along the strip: %v", session.pixel(img, LOOK_SIZE.x / 2, bottom))
	for x in ([]int{int(a.rect.min.x) + 1, int(session.center(a).x), int(a.rect.max.x) - 2}) {
		p := session.pixel(img, x, bottom)
		testing.expectf(t, session.near(p, page, 4), "the chosen tab's last row is the page at x %d: %v, the page %v", x, p, page)
	}
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), bottom + 1), page, 4), "and the panel's first row")
	// from the stack's edge the line runs a few pixels, then the first tab's left foot curves up out of it: just left of
	// the tab, above the line, the foot (its fill and its outline), not the strip's ground; at the edge, the ground
	x0 := int(stack) + 1
	testing.expectf(t, session.near(session.pixel(img, x0, bottom), line, 6), "the line from the stack's edge: %v", session.pixel(img, x0, bottom))
	testing.expectf(t, session.near(session.pixel(img, x0, bottom - 2), strip, 3), "the strip's ground over the line's run: %v", session.pixel(img, x0, bottom - 2))
	foot := session.pixel(img, int(a.rect.min.x) - 1, bottom - 1)
	testing.expectf(t, !session.near(foot, strip, 3), "the first tab's left foot, left of its box: %v, the strip %v", foot, strip)
}

// The room before the first tab (tab_strip_inset) in the session's theme and scale: its left foot's and the line's run.
@(private = "file")
look_inset :: proc(app: ^Look_App) -> f32 {
	return math.round(app.dock.metrics.em * ui.SHAPE_DEFAULT[.Control] * 0.8) + 3
}

@(test)
an_unchosen_tab_has_no_face_and_the_words_sit_in_the_shape :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup(t, &app)
	a, c := tab(&app, 1), tab(&app, 3)
	if !testing.expect(t, a != nil && c != nil, "the tabs") { return }
	img := session.capture(s)
	strip := session.pixel(img, LOOK_SIZE.x - 60, int(session.center(a).y))
	// inside the third tab's outline, before its words: the strip's own colour from under its top to above the line
	title := session.get(s, "dock_title", c)
	x := int(title.rect.min.x) - 1   // (between its outline's side and its words)
	// (below its top corner's arc, down to above the line)
	for y in int(c.rect.min.y + (c.rect.max.y - c.rect.min.y) * 0.6) ..< int(c.rect.max.y) - 3 {
		p := session.pixel(img, x, y)
		if !session.near(p, strip, 3) { testing.expectf(t, false, "an unchosen tab has a face: %v at row %d, the strip %v", p, y, strip); break }
	}
	// the words in the middle of the visible shape, below the strip's ground over it
	words := session.get(s, "dock_title", a)
	mid := (words.rect.min.y + words.rect.max.y) * 0.5
	testing.expectf(t, mid > (a.rect.min.y + a.rect.max.y) * 0.5, "the words sit lower than the strip's middle: %v in %v", mid, a.rect)
	// a panel's content starts where the first tab's words start (dock_content_inset)
	stack := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect.min.x + app.dock.origin.x
	testing.expect_value(t, words.rect.min.x - stack, look_inset(&app) + math.round(ui.DOCK_TAB_PAD_EM * app.dock.metrics.em))
}

@(test)
an_unchosen_tab_shows_its_close_button_under_the_pointer_only :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup(t, &app)
	a, b := tab(&app, 1), tab(&app, 2)
	if !testing.expect(t, a != nil && b != nil, "the tabs") { return }
	close_a, close_b := session.get(s, "dock_close", a), session.get(s, "dock_close", b)
	testing.expect(t, .Draw_Text in close_a.flags, "the chosen tab shows its close button")
	testing.expect(t, .Draw_Text not_in close_b.flags, "an unchosen tab hides it at rest")
	testing.expect(t, close_b.a11y != nil && close_b.a11y.role == .Button, "hidden, it is still a button for a screen reader")
	// at rest: no pixel of the button over the strip (clear of the tab's outline, which runs above it and down its right)
	img := session.capture(s)
	strip := session.pixel(img, LOOK_SIZE.x - 60, int(session.center(b).y))
	r := close_b.rect
	n := session.count_other(img, {int(r.min.x), int(r.min.y) + 3}, {int(r.max.x) - 5, int(r.max.y) - 3}, strip)
	testing.expectf(t, n == 0, "%d pixels of a hidden close button", n)
	// its room is kept: the tab is as wide under the pointer
	w := b.rect.max.x - b.rect.min.x
	session.move(s, session.center(b))
	session.frames(s, 3)
	b = tab(&app, 2)
	close_b = session.get(s, "dock_close", b)
	testing.expect(t, .Draw_Text in close_b.flags, "under the pointer the tab shows its close button")
	testing.expect_value(t, b.rect.max.x - b.rect.min.x, w)
}

// One stack of three tabs, the first one shown, at `dpi` (`size`: physical pixels).
@(private = "file")
look_setup_at :: proc(t: ^testing.T, app: ^Look_App, dpi: f32) -> ^session.Session {
	ui.dock_init(&app.dock)
	testing.expect(t, ui.dock_parse(&app.dock, "dock1 [*a,b,c]", proc(user: rawptr, name: string) -> (u32, bool) {
		for n, i in ([?]string{"", "a", "b", "c"}) { if i > 0 && n == name { return u32(i), true } }
		return 0, false
	}, nil))
	s := session.start(t, {build = look_build, user = app, size = {900, 400}, dpi_scale = dpi})
	session.move(s, {895, 395})
	session.frames(s, 3)
	return s
}

// Whether `c` is `a` within `tolerance` on each channel (colours of different alpha compared by their colour only).
@(private = "file")
close_to :: proc(c, a: session.Color, tolerance := 3) -> bool {
	for i in 0 ..< 3 { if abs(int(c[i]) - int(a[i])) > tolerance { return false } }
	return true
}

// Whether `c` is nearer `a` than `b` (the sum of its channels' distances).
@(private = "file")
nearer :: proc(c, a, b: session.Color) -> bool {
	da, db := 0, 0
	for i in 0 ..< 3 { da += abs(int(c[i]) - int(a[i])); db += abs(int(c[i]) - int(b[i])) }
	return da < db
}

// The chosen tab's feet at 100, 125, 150 and 200 %: around each foot nothing of the outline below the line's row nor
// beside the fillet, the line unbroken from the strip's edge into the fillet, and the right foot the mirror of the left
// (the reference profile: one shape, drawn the same on both sides). An unchosen tab's outline never draws on the line.
@(test)
the_feet_flow_into_the_line_at_every_scale :: proc(t: ^testing.T) {
	pal := ui.palette_of("Midnight")
	page, line := rgba(pal.bg), rgba(pal.border)
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup_at(t, &app, 1)
	for dpi in ([]f32{1, 1.25, 1.5, 2}) {
		session.set_dpi(s, dpi)
		session.frames(s, 3)
		a, c := tab(&app, 1), tab(&app, 3)
		if !testing.expect(t, a != nil && c != nil, "the tabs") { continue }
		img := session.capture(s)
		px := max(1, int(math.round(dpi)))
		em := app.dock.metrics.em
		foot := int(math.min(math.round(em * ui.SHAPE_DEFAULT[.Control] * 0.8), math.round(em * ui.SHAPE_DEFAULT[.Control])))
		stack := int(app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect.min.x + app.dock.origin.x)
		bottom := int(math.round(a.rect.max.y))          // the line's bottom edge
		line_row := bottom - px                           // its first row
		// the sides' columns: the stroke's first column, inside the tab's box
		left, right := int(math.round(a.rect.min.x)), int(math.round(a.rect.max.x)) - px
		ground := session.pixel(img, 880, int(session.center(a).y))
		// below the line: the panel, in every column of both feet
		for x in left - foot - 3 ..= right + foot + 3 {
			for y in bottom ..< bottom + 3 {
				q := session.pixel(img, x, y)
				if !close_to(q, page) { testing.expectf(t, false, "%.2f: the outline below the line at %d,%d: %v, the page %v", dpi, x, y, q, page); break }
			}
		}
		// the line from the strip's edge to the left fillet: its rows the line's colour, nothing above it but the strip
		for x in stack + 1 ..< left - foot {
			for y in line_row ..< bottom {
				q := session.pixel(img, x, y)
				if !close_to(q, line, 4) { testing.expectf(t, false, "%.2f: the line broken at %d,%d: %v, the border %v", dpi, x, y, q, line); break }
			}
			q := session.pixel(img, x, line_row - 1)
			if !close_to(q, ground) { testing.expectf(t, false, "%.2f: something beside the left fillet at %d,%d: %v, the strip %v", dpi, x, line_row - 1, q, ground); break }
		}
		// through the fillet the outline is continuous: each of its columns has a pixel of the edge's colour above the line
		for x in left - foot ..= left {
			found := false
			for y in line_row - foot - px ..< bottom { if close_to(session.pixel(img, x, y), line, 24) { found = true; break } }
			testing.expectf(t, found, "%.2f: the left fillet broken at column %d", dpi, x)
		}
		// no hook: where the fillet's stroke stands clear of a pixel of the line's rows (its edge more than its soft edge
		// away), the line under it is gone (the fill covers it): the curve meets the line tangent at the fillet's outer end,
		// the line does not run on under the curve to the side. (The distance is the pixel's centre to the arc, across it:
		// near the side the arc stands almost upright, and its soft edge reaches a pixel its height alone says is clear.)
		hp := f32(px) * 0.5
		arc := [2]f32{f32(left) + hp - f32(foot), f32(bottom) - hp - f32(foot)}   // (the stroke's centres, as tab_draw snaps them)
		for k in 1 ..< foot {
			for y in line_row ..< bottom {
				at := [2]f32{f32(left - k) + 0.5, f32(y) + 0.5}
				if math.sqrt((at.x - arc.x) * (at.x - arc.x) + (at.y - arc.y) * (at.y - arc.y)) - f32(foot) - hp < 0.75 { continue }
				q := session.pixel(img, left - k, y)
				testing.expectf(t, nearer(q, page, line), "%.2f: the line runs under the left fillet %d px from the side, row %d: %v, the page %v", dpi, k, y, q, page)
				q = session.pixel(img, right + px - 1 + k, y)
				testing.expectf(t, nearer(q, page, line), "%.2f: the line runs under the right fillet %d px from the side, row %d: %v, the page %v", dpi, k, y, q, page)
			}
		}
		// the right foot mirrors the left, column by column, from the side outward
		for k in 0 ..= foot + 2 {
			for y in line_row - foot - px ..< bottom {
				l, r := session.pixel(img, left - k + px - 1, y), session.pixel(img, right + k, y)
				if !close_to(l, r, 10) { testing.expectf(t, false, "%.2f: the feet differ %d px out at row %d: left %v, right %v", dpi, k, y, l, r); break }
			}
		}
		// an unchosen tab: its outline ends above the line, the line's rows under it the line's colour
		for x in int(c.rect.min.x) ..< int(c.rect.max.x) {
			for y in line_row ..< bottom {
				q := session.pixel(img, x, y)
				if !close_to(q, line, 4) { testing.expectf(t, false, "%.2f: an unchosen tab draws on the line at %d,%d: %v", dpi, x, y, q); break }
			}
		}
	}
}
