// The look of a dock's tabs (src/md/features/tabs.md): the strip's line, out of which the chosen tab rises joined to its
// panel; the first tab at the stack's edge; the other tabs with no face; the words in the middle of the shape; a tab's
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
	leaf := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect
	testing.expectf(t, a.rect.min.x == leaf.min.x + app.dock.origin.x, "the first tab at the stack's edge: %v, the stack at %v", a.rect.min.x, leaf.min.x)
	testing.expect_value(t, a.rect.max.y - a.rect.min.y, f32(app.dock.metrics.strip))
	bottom := int(a.rect.max.y) - 1
	// the line under an unchosen tab and on the empty part of the strip; none under the chosen one
	testing.expectf(t, session.near(session.pixel(img, int(session.center(b).x), bottom), line, 6), "the line under an unchosen tab: %v, the border %v", session.pixel(img, int(session.center(b).x), bottom), line)
	testing.expectf(t, session.near(session.pixel(img, LOOK_SIZE.x / 2, bottom), line, 6), "the line along the strip: %v", session.pixel(img, LOOK_SIZE.x / 2, bottom))
	for x in ([]int{int(a.rect.min.x) + 1, int(session.center(a).x), int(a.rect.max.x) - 2}) {
		p := session.pixel(img, x, bottom)
		testing.expectf(t, session.near(p, page, 4), "the chosen tab's last row is the page at x %d: %v, the page %v", x, p, page)
	}
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), bottom + 1), page, 4), "and the panel's first row")
	// the chosen tab's left side at the stack's edge goes straight down: its first column is its outline to the line
	edge := session.pixel(img, int(a.rect.min.x), bottom - 2)
	testing.expectf(t, !session.near(edge, page, 4), "a straight side at the stack's edge: %v", edge)
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
	x := int(title.rect.min.x) - 2
	for y in int(c.rect.min.y + (c.rect.max.y - c.rect.min.y) * 0.3) ..< int(c.rect.max.y) - 3 {
		p := session.pixel(img, x, y)
		if !session.near(p, strip, 3) { testing.expectf(t, false, "an unchosen tab has a face: %v at row %d, the strip %v", p, y, strip); break }
	}
	// the words in the middle of the visible shape, below the strip's ground over it
	words := session.get(s, "dock_title", a)
	mid := (words.rect.min.y + words.rect.max.y) * 0.5
	testing.expectf(t, mid > (a.rect.min.y + a.rect.max.y) * 0.5, "the words sit lower than the strip's middle: %v in %v", mid, a.rect)
	// a panel's content starts where its tab's words start
	testing.expect_value(t, words.rect.min.x - a.rect.min.x, math.round(ui.DOCK_TAB_PAD_EM * app.dock.metrics.em))
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
	n := session.count_other(img, {int(r.min.x), int(r.min.y) + 3}, {int(r.max.x) - 3, int(r.max.y) - 3}, strip)
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
