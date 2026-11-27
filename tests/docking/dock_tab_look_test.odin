// The look of a dock's tabs (src/md/features/tab-styles.md, tabs.md). A dock's stack is an Underline: its strip on the
// panel's surface, no line nor border between them, the shown tab's words over an accent bar, the first tab at the
// stack's edge, a panel's content under its words. A dock asked for Folders: the line, out of which the chosen tab rises
// joined to its panel, every foot flowing into it at every scale. A tab's close button hidden at rest on the others, its
// room kept.
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
Look_App :: struct { dock: ui.Dock, style: Maybe(ui.Tab_Style), inset: f32 }   // (inset: dock_content_inset() in a panel)

@(private = "file")
look_build :: proc(s: ^session.Session) {
	app := (^Look_App)(s.user)
	ui.dock_begin(&app.dock, "###dock", {title = proc(user: rawptr, id: u32) -> string { return LOOK_TITLES[id] }, user = app, close_buttons = true, tab_style = app.style})
	for p in u32(1) ..< len(LOOK_TITLES) {
		if ui.dock_panel(&app.dock, p) {
			if p == 1 { app.inset = ui.dock_content_inset() }
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
an_underline_stack_is_one_surface_with_its_panel :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup(t, &app)
	a, b := tab(&app, 1), tab(&app, 2)
	if !testing.expect(t, a != nil && b != nil, "the tabs") { return }
	img := session.capture(s)
	pal := ui.palette_of("Midnight")
	page, line, accent := rgba(pal.bg), rgba(pal.border), rgba(pal.accent)
	stack := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect.min.x + app.dock.origin.x
	// the first tab at the stack's edge (no room for a foot), the strip's height
	testing.expect_value(t, a.rect.min.x - stack, f32(0))
	testing.expect_value(t, a.rect.max.y - a.rect.min.y, f32(app.dock.metrics.strip))
	bottom := int(a.rect.max.y) - 1
	// no line: under an unchosen tab, along the strip's free part, the strip's last row and the panel's first are the page
	for x in ([]int{int(session.center(b).x), LOOK_SIZE.x / 2}) {
		for y in ([]int{bottom - 1, bottom, bottom + 1, bottom + 2}) {
			q := session.pixel(img, x, y)
			testing.expectf(t, session.near(q, page, 4) && !session.near(q, line, 4), "no border between the strip and its panel at %d,%d: %v, the page %v", x, y, q, page)
		}
	}
	// the shown tab: an accent bar along its bottom, inside its sides
	q := session.pixel(img, int(session.center(a).x), bottom)
	testing.expectf(t, session.near(q, accent, 12), "the shown tab's bar: %v, the accent %v", q, accent)
	testing.expectf(t, session.near(session.pixel(img, int(a.rect.min.x) + 1, bottom), page, 4), "the bar inside the tab's sides")
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), bottom + 1), page, 4), "the panel's first row under the bar: the page")
}

@(test)
an_unchosen_tab_has_no_face_and_the_words_sit_in_the_strip :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	s := look_setup(t, &app)
	a, c := tab(&app, 1), tab(&app, 3)
	if !testing.expect(t, a != nil && c != nil, "the tabs") { return }
	img := session.capture(s)
	page := rgba(ui.palette_of("Midnight").bg)
	// inside the third tab, before its words: the page at every row
	title := session.get(s, "dock_title", c)
	x := int(title.rect.min.x) - 1
	for y in int(c.rect.min.y) ..< int(c.rect.max.y) {
		p := session.pixel(img, x, y)
		if !session.near(p, page, 3) { testing.expectf(t, false, "an unchosen tab has a face: %v at row %d, the page %v", p, y, page); break }
	}
	// the words in the middle of the strip
	words := session.get(s, "dock_title", a)
	mid := (words.rect.min.y + words.rect.max.y) * 0.5
	testing.expectf(t, abs(mid - (a.rect.min.y + a.rect.max.y) * 0.5) <= 1, "the words in the strip's middle: %v in %v", mid, a.rect)
	// a panel's content starts where the first tab's words start (dock_content_inset): the tab's pad from the edge
	stack := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect.min.x + app.dock.origin.x
	testing.expect_value(t, words.rect.min.x - stack, math.round(ui.DOCK_TAB_PAD_EM * app.dock.metrics.em))
	// and the panel's content reads that inset inside its dock_panel (its stack's scope open there, not closed when
	// dock_panel returned: a Folder's inset, a foot more)
	testing.expect_value(t, app.inset, words.rect.min.x - stack)
}

// A panel that names its surface: its body painted with it, the strip on it, the shown tab's bar over it.
@(test)
a_panel_surface_paints_its_body_and_its_strip :: proc(t: ^testing.T) {
	app: Look_App
	defer ui.dock_destroy(&app.dock)
	ui.dock_init(&app.dock)
	testing.expect(t, ui.dock_parse(&app.dock, "dock1 [*a,b,c]", proc(user: rawptr, name: string) -> (u32, bool) {
		for n, i in ([?]string{"", "a", "b", "c"}) { if i > 0 && n == name { return u32(i), true } }
		return 0, false
	}, nil))
	build :: proc(s: ^session.Session) {
		app := (^Look_App)(s.user)
		ui.dock_begin(&app.dock, "###dock", {
			title = proc(user: rawptr, id: u32) -> string { return LOOK_TITLES[id] }, user = app,
			surface = proc(user: rawptr, id: u32) -> ui.Tab_Surface { return {ground = {0.02, 0.2, 0.05, 1}} },
		})
		for p in u32(1) ..< len(LOOK_TITLES) { if ui.dock_panel(&app.dock, p) { ui.spacer(ui.px(40)) } }
		ui.dock_end(&app.dock)
	}
	s := session.start(t, {build = build, user = &app, size = LOOK_SIZE})
	session.move(s, {f32(LOOK_SIZE.x) - 5, f32(LOOK_SIZE.y) - 5})
	session.frames(s, 3)
	b := tab(&app, 2)
	if !testing.expect(t, b != nil, "the tabs") { return }
	img := session.capture(s)
	ground := session.pixel(img, LOOK_SIZE.x / 2, LOOK_SIZE.y - 20)
	page := rgba(ui.palette_of("Midnight").bg)
	testing.expectf(t, !session.near(ground, page, 6), "the body painted with its surface: %v, the page %v", ground, page)
	for y in ([]int{int(b.rect.min.y) + 2, int(b.rect.max.y) - 1, int(b.rect.max.y)}) {
		q := session.pixel(img, int(b.rect.max.x) + 30, y)
		testing.expectf(t, session.near(q, ground, 4), "the strip on the panel's surface at row %d: %v, the surface %v", y, q, ground)
	}
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

// One stack of three Folder tabs, the first one shown, at `dpi` (`size`: physical pixels).
@(private = "file")
look_setup_at :: proc(t: ^testing.T, app: ^Look_App, dpi: f32) -> ^session.Session {
	app.style = .Folder   // (the feet are a Folder's)
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

// A dock of Folders: the chosen tab's feet at 100, 125, 150 and 200 %: around each foot nothing of the outline below the line's row nor
// beside the fillet, the line unbroken from the strip's edge into the fillet, and the right foot the mirror of the left
// (the reference profile: one shape, drawn the same on both sides). An unchosen tab draws nothing on the line.
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
		// an unchosen tab: nothing of it on the line, the line's rows under it the line's colour
		for x in int(c.rect.min.x) ..< int(c.rect.max.x) {
			for y in line_row ..< bottom {
				q := session.pixel(img, x, y)
				if !close_to(q, line, 4) { testing.expectf(t, false, "%.2f: an unchosen tab draws on the line at %d,%d: %v", dpi, x, y, q); break }
			}
		}
	}
}
