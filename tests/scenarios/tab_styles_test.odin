package scenarios_test

// Rows of tabs over the surface they frame (src/md/features/tab-styles.md), in a ui.tab_panel of each style: where the
// tab meets its panel (a Folder's chosen tab joined, no line under it; an Underline's strip with no border before its
// panel; a Segmented's key on its track; a Header's chosen tab a hole in its band), one frame round all of it, and what
// ui.tabs_ex tells a program (a right click, the Menu key, a middle click; a tab's own content).

import "core:fmt"
import "core:testing"
import "gt:platform"
import "gt:testkit/session"
import "gt:testkit/unwatched"
import "gt:ui"

@(private = "file", rodata) STYLE_TABS := [?]string{"Alpha", "Beta", "Gamma"}
@(private = "file") STYLE_GROUND :: ui.Color{0.02, 0.15, 0.30, 1}   // (the panel's surface: none of the theme's colours)

@(private = "file")
Style_Run :: struct {
	style:   ui.Tab_Style,
	sel:     int,
	menu:    int,
	menu_at: [2]f32,
	closed:  int,
	custom:  bool,
	calls:   int,   // the content callback's calls in the last build
	chosen:  int,   // the index it was told is chosen
}

@(private = "file")
style_build :: proc(s: ^session.Session) {
	r := (^Style_Run)(s.user)
	r.calls = 0
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if !ui.column(id = "###page") { return }
	ui.spacer(ui.px(20))
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if !ui.row(id = "###margin") { return }
	ui.spacer(ui.px(20))
	o := ui.Tab_Panel_Options{surface = {ground = STYLE_GROUND}, tabs = {style = r.style}}
	if r.custom {
		o.tabs.user = r
		o.tabs.content = proc(user: rawptr, t: ui.Tab_Content) {
			r := (^Style_Run)(user)
			r.calls += 1
			if t.on { r.chosen = t.index }
			em := ui.font_size()
			ui.spacer(ui.px(em))
			ui.next({width = ui.text_size(), height = ui.pct(1)})
			ui.build_box({.Draw_Text}, fmt.tprintf("%s*###mine_c", t.label))
			ui.spacer(ui.px(em))
		}
	}
	ui.next({width = ui.px(400), height = ui.px(200)})
	if res, ok := ui.tab_panel("###panel", STYLE_TABS[:], nil, &r.sel, o); ok {
		if res.menu >= 0 { r.menu, r.menu_at = res.menu, res.menu_at }
		if res.closed >= 0 { r.closed = res.closed }
		ui.spacer(ui.px(10))
	}
}

@(private = "file")
style_start :: proc(t: ^testing.T, r: ^Style_Run) -> ^session.Session {
	r.menu, r.closed = -1, -1
	s := session.start(t, {size = {480, 280}, user = r, build = style_build})
	session.move(s, {470, 270})   // (the pointer on no tab)
	session.wait_idle(s)
	return s
}

@(private = "file")
rgba :: proc(c: u32) -> session.Color { return {u8(c >> 24), u8(c >> 16), u8(c >> 8), u8(c)} }

// The rows of column `x` from the frame's top to its bottom whose colour is the frame's edge (its bottom row's).
@(private = "file")
edge_rows :: proc(img: session.Image, frame: ^ui.Box, x: int) -> (n: int, edge: session.Color) {
	edge = session.pixel(img, x, int(frame.rect.max.y) - 1)
	for y in int(frame.rect.min.y) ..< int(frame.rect.max.y) { if session.near(session.pixel(img, x, y), edge, 6) { n += 1 } }
	return
}

// A Folder: the chosen tab joined to its panel (no line under it), the line under the others, one frame.
@(test)
a_folder_tab_is_joined_to_its_panel_in_one_frame :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Folder}
	s := style_start(t, &r)
	img := session.capture(s)
	session.save_png(s, "folder.png")
	strip := session.get(s, "tab_panel_strip")
	frame := strip.parent
	a, c := session.get(s, "panel_0"), session.get(s, "panel_2")
	x := int(frame.rect.max.x) - 15
	n, edge := edge_rows(img, frame, x)
	testing.expectf(t, n == 2, "one frame: the line and the bottom edge, %d rows of the edge's colour", n)
	line := int(strip.rect.max.y) - 1
	ground := session.pixel(img, x, int(frame.rect.max.y) - 20)
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), line), ground, 4), "no line under the chosen tab: %v, the surface %v", session.pixel(img, int(session.center(a).x), line), ground)
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), line - 3), ground, 4), "the chosen tab is the surface")
	testing.expectf(t, session.near(session.pixel(img, int(session.center(c).x), line), edge, 6), "the line under an unchosen tab")
	testing.expectf(t, !session.near(session.pixel(img, int(c.rect.min.x) + 4, line - 3), ground, 6), "an unchosen tab is no surface: it stands on the strip")
}) }

// An Underline: the strip on the panel's surface, no border between them, the chosen tab's accent bar, one frame.
@(test)
an_underline_strip_has_no_border_before_its_panel :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Underline}
	s := style_start(t, &r)
	img := session.capture(s)
	session.save_png(s, "underline.png")
	strip := session.get(s, "tab_panel_strip")
	frame := strip.parent
	a, c := session.get(s, "panel_0"), session.get(s, "panel_2")
	x := int(frame.rect.max.x) - 15
	n, _ := edge_rows(img, frame, x)
	testing.expectf(t, n == 2, "one frame: its top and bottom edges, %d rows of the edge's colour", n)
	ground := session.pixel(img, x, int(frame.rect.max.y) - 20)
	bottom := int(strip.rect.max.y)
	for y in bottom - 3 ..< bottom + 3 {
		q := session.pixel(img, int(session.center(c).x), y)
		testing.expectf(t, session.near(q, ground, 4), "no border between the strip and the panel at row %d: %v, the surface %v", y, q, ground)
		q = session.pixel(img, x, y)
		testing.expectf(t, session.near(q, ground, 4), "nor along the strip's free part at row %d: %v", y, q)
	}
	accent := rgba(ui.palette_of("Midnight").accent)
	q := session.pixel(img, int(session.center(a).x), bottom - 1)
	testing.expectf(t, session.near(q, accent, 12), "the chosen tab's bar: %v, the accent %v", q, accent)
}) }

// A Segmented: a track on the surface, the chosen key on it, one frame round the switcher and its page.
@(test)
a_segmented_switcher_sits_inside_its_one_frame :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Segmented}
	s := style_start(t, &r)
	img := session.capture(s)
	session.save_png(s, "segmented.png")
	strip := session.get(s, "tab_panel_strip")
	frame := strip.parent
	a, c := session.get(s, "panel_0"), session.get(s, "panel_2")
	x := int(frame.rect.max.x) - 15
	n, _ := edge_rows(img, frame, x)
	testing.expectf(t, n == 2, "one frame, %d rows of the edge's colour", n)
	testing.expect(t, strip.rect.min.y > frame.rect.min.y + 4, "the switcher inside the frame")
	ground := session.pixel(img, x, int(frame.rect.max.y) - 20)
	y := int(session.center(a).y)
	key, track := session.pixel(img, int(a.rect.min.x) + 4, y), session.pixel(img, int(c.rect.min.x) + 4, y)
	testing.expectf(t, !session.near(track, ground, 4), "the track off the surface: %v, the surface %v", track, ground)
	testing.expectf(t, !session.near(key, track, 4) && !session.near(key, ground, 4), "the chosen key off its track: %v, the track %v", key, track)
}) }

// A Header: the strip a band of the panel, the chosen tab a hole in it onto the surface, one frame.
@(test)
a_header_tab_is_a_hole_in_its_band :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Header}
	s := style_start(t, &r)
	img := session.capture(s)
	session.save_png(s, "header.png")
	strip := session.get(s, "tab_panel_strip")
	frame := strip.parent
	a, c := session.get(s, "panel_0"), session.get(s, "panel_2")
	x := int(frame.rect.max.x) - 15
	n, _ := edge_rows(img, frame, x)
	testing.expectf(t, n == 2, "one frame, %d rows of the edge's colour", n)
	ground := session.pixel(img, x, int(frame.rect.max.y) - 20)
	bottom := int(strip.rect.max.y)
	testing.expectf(t, session.near(session.pixel(img, int(session.center(a).x), bottom - 1), ground, 4), "the chosen tab is the surface down to the panel")
	band := session.pixel(img, int(session.center(c).x), bottom - 1)
	testing.expectf(t, !session.near(band, ground, 4), "an unchosen tab stands on the band: %v, the surface %v", band, ground)
	testing.expectf(t, session.near(session.pixel(img, int(session.center(c).x), bottom), ground, 4), "no line under the band")
}) }

// A right click on a tab asks for its menu where the pointer is and chooses nothing; the Menu key on the focused tab
// asks for its menu under it; a middle click asks to close a tab.
@(test)
a_tab_says_its_menu_and_its_close :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Folder}
	s := style_start(t, &r)
	b := session.get(s, "panel_1")
	at := session.center(b)
	session.click_at(s, at, platform.Mouse_Button.Right)
	session.frames(s, 2)
	testing.expect_value(t, r.menu, 1)
	testing.expectf(t, abs(r.menu_at.x - at.x) < 1 && abs(r.menu_at.y - at.y) < 1, "the menu at the pointer: %v, the click %v", r.menu_at, at)
	testing.expect_value(t, r.sel, 0)
	r.menu = -1
	session.click(s, "panel_0")
	session.key(s, platform.Key.Menu)
	session.frames(s, 2)
	testing.expect_value(t, r.menu, 0)
	a := session.get(s, "panel_0")
	testing.expectf(t, r.menu_at.y >= a.rect.max.y - 1, "the keyboard's menu under the tab: %v, the tab %v", r.menu_at, a.rect)
	session.click_at(s, session.center(session.get(s, "panel_2")), platform.Mouse_Button.Middle)
	session.frames(s, 2)
	testing.expect_value(t, r.closed, 2)
	testing.expect_value(t, r.sel, 0)
}) }

// Tabs_Options.content builds each tab's content, told its index and whether it is chosen; a click still chooses.
@(test)
a_tab_s_own_content_is_built_in_it :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Underline, custom = true, sel = 1}
	s := style_start(t, &r)
	testing.expect_value(t, r.calls, len(STYLE_TABS))
	testing.expect_value(t, r.chosen, 1)
	for i in 0 ..< len(STYLE_TABS) {
		tab := session.get(s, fmt.tprintf("panel_%d", i))
		mine := session.find(s, "mine_c", 0, tab)
		if !testing.expectf(t, mine != nil, "tab %d: its own content", i) { continue }
		testing.expect_value(t, mine.text, fmt.tprintf("%s*", STYLE_TABS[i]))
	}
	session.click(s, "panel_2")
	session.frames(s, 2)
	testing.expect_value(t, r.sel, 2)
	testing.expect_value(t, r.chosen, 2)
}) }
