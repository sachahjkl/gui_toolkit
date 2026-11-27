package scenarios_test

// Rows of tabs over the surface they frame (src/md/features/tab-styles.md), in a ui.tab_panel of each style: where the
// tab meets its panel (a Folder's chosen tab joined, no line under it; an Underline's strip with no border before its
// panel; a Segmented's key on its track; a Header's chosen tab a hole in its band), one frame round all of it, and what
// ui.tabs_ex tells a program (a right click, the Menu key, a middle click; a tab's own content).

import "core:fmt"
import "core:math"
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
	menu_keyboard: bool,
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
	in_page := ui.column(id = "###page")
	if !in_page { return }
	ui.spacer(ui.px(20))
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	in_margin := ui.row(id = "###margin")
	if !in_margin { return }
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
		if res.menu >= 0 { r.menu, r.menu_at, r.menu_keyboard = res.menu, res.menu_at, res.menu_keyboard }
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

// A right click on a tab asks for its menu where the pointer is and chooses nothing; the Menu key or Shift+F10 on the
// focused tab asks for its menu under it, from the keyboard; a middle click asks to close a tab.
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
	testing.expect(t, !r.menu_keyboard, "a right click's menu is the pointer's")
	testing.expect_value(t, r.sel, 0)
	r.menu = -1
	session.click(s, "panel_0")
	session.key(s, platform.Key.Menu)
	session.frames(s, 2)
	testing.expect_value(t, r.menu, 0)
	testing.expect(t, r.menu_keyboard, "the Menu key's menu is the keyboard's: its first item lit")
	a := session.get(s, "panel_0")
	testing.expectf(t, r.menu_at.y >= a.rect.max.y - 1, "the keyboard's menu under the tab: %v, the tab %v", r.menu_at, a.rect)
	r.menu, r.menu_keyboard = -1, false
	session.key(s, platform.Key.F10, {.Shift})
	session.frames(s, 2)
	testing.expect_value(t, r.menu, 0)
	testing.expect(t, r.menu_keyboard, "Shift+F10 asks the menu as the Menu key does")
	testing.expect_value(t, r.sel, 0)
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

// The keyboard's focus on the chosen tab of `st`: a ring inside the strip, clear of its edges, so the accent bar along
// the strip's bottom (Underline) or the hole's top (Header) still shows. Round the whole box, the ring covered the bar.
@(private = "file")
focus_keeps_the_bar :: proc(t: ^testing.T, r: ^Style_Run) {
	s := style_start(t, r)
	before := session.capture(s)
	session.key(s, platform.Key.Tab)
	session.wait_idle(s)
	after := session.capture(s)
	session.save_png(s, fmt.tprintf("focus-%v.png", r.style))
	b := session.get(s, "panel_1")
	x0, x1 := int(b.rect.min.x), int(b.rect.max.x)
	y0, y1 := int(b.rect.min.y), int(b.rect.max.y)
	changed := 0
	for y in y0 ..< y1 { for x in x0 ..< x1 { if !session.near(session.pixel(before, x, y), session.pixel(after, x, y), 8) { changed += 1 } } }
	testing.expectf(t, changed > 2 * (x1 - x0), "the focus shows: %d pixels changed", changed)
	for x in x0 ..< x1 {
		for y in ([?]int{y0, y0 + 1, y1 - 2, y1 - 1}) {
			p, q := session.pixel(before, x, y), session.pixel(after, x, y)
			testing.expectf(t, session.near(p, q, 8), "the strip's edge rows keep their pixels (the bar) at %d,%d: %v, before %v", x, y, q, p)
		}
	}
}

@(test)
an_underline_s_focus_ring_keeps_its_bar :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Underline, sel = 1}
	focus_keeps_the_bar(t, &r)
}) }

@(test)
a_header_s_focus_ring_keeps_its_accent :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r := Style_Run{style = .Header, sel = 1}
	focus_keeps_the_bar(t, &r)
}) }

// A Folder's chosen tab at fractional scales: its line runs on the frame's top edge rows (the same rows beside each foot
// and at the frame's far end), and no edge row under the tab. A line a row off the frame's edge was a step at a foot.
// At 175 % the tabs overflow and the strip's arrow stands at the far end: it leaves the frame's edge showing (an opaque
// arrow the strip's height cut it).
@(test)
a_folder_s_line_is_its_frame_s_edge_at_every_scale :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	for dpi in ([?]f32{1.25, 1.5, 1.75}) {
		r := Style_Run{style = .Folder, sel = 1, menu = -1, closed = -1}
		s := session.start(t, {size = {600, 520}, user = &r, build = style_build, dpi_scale = dpi})
		session.move(s, {595, 515})
		session.wait_idle(s)
		img := session.capture(s)
		session.save_png(s, fmt.tprintf("folder-%v.png", dpi))
		strip := session.get(s, "tab_panel_strip")
		frame := strip.parent
		b := session.get(s, "panel_1")
		far := int(frame.rect.max.x) - 20
		edge := session.pixel(img, far, int(frame.rect.max.y) - 1)
		bottom := int(math.round(strip.rect.max.y))
		rows :: proc(img: session.Image, x, from, to: int, edge: session.Color) -> (set: u32) {
			for y in from ..< to { if session.near(session.pixel(img, x, y), edge, 10) { set |= 1 << u32(y - from) } }
			return
		}
		from, to := bottom - 6, bottom + 6
		want := rows(img, far, from, to, edge)
		testing.expectf(t, want != 0, "%v: the frame's top edge at its far end", dpi)
		foot := int(math.ceil(f32(b.rect.max.y - b.rect.min.y)))   // (well past a foot: the straight line)
		for x in ([?]int{int(b.rect.min.x) - foot, int(b.rect.max.x) + foot}) {
			got := rows(img, x, from, to, edge)
			testing.expectf(t, got == want, "%v: beside a foot at x %d the line's rows %b, the frame's edge %b", dpi, x, got, want)
		}
		under := rows(img, int(session.center(b).x), from, to, edge)
		testing.expectf(t, under == 0, "%v: no edge under the chosen tab: rows %b", dpi, under)
	}
}) }

@(private = "file")
Scope_Run :: struct { sel: int, inside_panel, after_panel, after_tabs: ui.Tab_Style, ground_inside: ui.Color }

// tabs_over scopes nest and close where they are closed: a tab_panel's lasts over its page (a row of tabs there frames
// its surface) and ends with it; ui.tabs_ex's ends with the strip; the scope around both is still in force after them.
// (A scope opened with tabs_over's deferred end inside the toolkit closed when its procedure returned, and its explicit
// end then closed the scope around it.)
@(test)
tabs_over_scopes_nest :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Scope_Run
	build :: proc(s: ^session.Session) {
		r := (^Scope_Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		in_page := ui.column(id = "###page")
		if !in_page { return }
		if ui.tabs_over(.Header, {ground = STYLE_GROUND}) {
			ui.next({width = ui.px(400), height = ui.px(160)})
			if _, ok := ui.tab_panel("###panel", STYLE_TABS[:], nil, &r.sel, {surface = {ground = {0.3, 0.1, 0.1, 1}}, tabs = {style = .Segmented}}); ok {
				r.inside_panel = ui.tab_style_now()
				r.ground_inside = ui.tab_surface_now().ground
			}
			r.after_panel = ui.tab_style_now()
			_ = ui.tabs_ex("###strip", STYLE_TABS[:], nil, &r.sel, {style = .Underline})
			r.after_tabs = ui.tab_style_now()
		}
	}
	s := session.start(t, {size = {480, 280}, user = &r, build = build})
	session.wait_idle(s)
	testing.expect_value(t, r.inside_panel, ui.Tab_Style.Segmented)
	testing.expect_value(t, r.ground_inside, ui.Color{0.3, 0.1, 0.1, 1})
	testing.expect_value(t, r.after_panel, ui.Tab_Style.Header)
	testing.expect_value(t, r.after_tabs, ui.Tab_Style.Header)
	testing.expect_value(t, ui.tab_style_now(), ui.Tab_Style.Folder)
}) }

@(private = "file")
Changed_Run :: struct {
	ex_sel, basic_sel, panel_sel:             int,
	ex_changes, basic_changes, panel_changes: int,
	ex_last, basic_last, panel_last:          bool,
}

// ui.tabs_ex, ui.tabs and ui.tab_panel report changed == true on the frame a click or arrow key changes selection,
// and false when selection does not change.
@(test)
tab_selection_reports_changed :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	r: Changed_Run
	build :: proc(s: ^session.Session) {
		r := (^Changed_Run)(s.user)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###page") {
			ui.next({width = ui.px(400), height = ui.px(36)})
			ex := ui.tabs_ex("###ex", STYLE_TABS[:], nil, &r.ex_sel, {style = .Segmented})
			r.ex_last = ex.changed
			if ex.changed { r.ex_changes += 1 }
			ui.next({width = ui.px(400), height = ui.px(36)})
			basic := ui.tabs("###basic", STYLE_TABS[:], nil, &r.basic_sel)
			r.basic_last = basic
			if basic { r.basic_changes += 1 }
			ui.next({width = ui.px(400), height = ui.px(160)})
			if res, ok := ui.tab_panel("###panel", STYLE_TABS[:], nil, &r.panel_sel, {tabs = {style = .Folder}}); ok {
				r.panel_last = res.changed
				if res.changed { r.panel_changes += 1 }
				ui.spacer(ui.px(10))
			}
		}
	}
	s := session.start(t, {size = {480, 320}, user = &r, build = build})
	session.wait_idle(s)
	testing.expect_value(t, r.ex_changes, 0)
	testing.expect_value(t, r.basic_changes, 0)
	testing.expect_value(t, r.panel_changes, 0)
	testing.expect(t, !r.ex_last && !r.basic_last && !r.panel_last, "unchanged while idle")

	// clicking the active tab reports no change
	session.click(s, "ex_0")
	session.frames(s, 2)
	testing.expect_value(t, r.ex_sel, 0)
	testing.expect_value(t, r.ex_changes, 0)
	testing.expect(t, !r.ex_last, "unchanged when clicking the active tab")

	// tabs_ex: click changes selection and reports changed once
	session.click(s, "ex_1")
	session.frames(s, 2)
	testing.expect_value(t, r.ex_sel, 1)
	testing.expect_value(t, r.ex_changes, 1)
	testing.expect(t, !r.ex_last, "false again on the following frame")

	// tabs_ex: click the active tab to focus it (no change), then Right moves to tab 2
	session.click(s, "ex_1")
	session.frames(s, 2)
	testing.expect_value(t, r.ex_changes, 1)
	testing.expect_value(t, s.state.focus_key, session.get(s, "ex_1").key)
	session.key(s, platform.Key.Right)
	session.frames(s, 2)
	testing.expect_value(t, r.ex_sel, 2)
	testing.expect_value(t, r.ex_changes, 2)
	testing.expect(t, !r.ex_last, "false again after keyboard navigation")

	// tabs_ex: Right at the last tab does not change selection
	session.key(s, platform.Key.Right)
	session.frames(s, 2)
	testing.expect_value(t, r.ex_sel, 2)
	testing.expect_value(t, r.ex_changes, 2)

	// ui.tabs: click changes selection and reports changed
	session.click(s, "basic_2")
	session.frames(s, 2)
	testing.expect_value(t, r.basic_sel, 2)
	testing.expect_value(t, r.basic_changes, 1)
	testing.expect(t, !r.basic_last, "false again after ui.tabs change")
	session.click(s, "basic_2")
	session.frames(s, 2)
	testing.expect_value(t, r.basic_changes, 1)

	// ui.tab_panel: click changes selection and reports changed
	session.click(s, "panel_1")
	session.frames(s, 2)
	testing.expect_value(t, r.panel_sel, 1)
	testing.expect_value(t, r.panel_changes, 1)
	testing.expect(t, !r.panel_last, "false again after ui.tab_panel change")
	session.click(s, "panel_1")
	session.frames(s, 2)
	testing.expect_value(t, r.panel_changes, 1)
}) }
