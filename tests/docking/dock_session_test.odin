// Docking, the widgets (ui/docking.odin) through the test session's input: a tab dragged onto each drop target, along its
// strip, out (floating) and back by a double click on the floating panel's title; Escape cancels a drag; the keyboard (the
// arrows along a strip, Ctrl+Tab, the menu); a handle resized and folded; the roles screen readers get; the save.
//   odin test tests/docking -vet -define:ODIN_TEST_THREADS=1
package docking_test

import "core:fmt"
import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") TAB_CLOSE_SEARCH :: 8

@(private = "file")
App :: struct {
	dock:   ui.Dock,
	built:  [6]bool,     // the panels whose content was built this frame
	saves:  int,
	result: ui.Dock_Result,
	hide:   bool,        // the dock is not built
	windowed: u32,      // the panel the dock let go to a window of its own
}

@(private = "file")
TITLES := [?]string{"", "Alpha", "Beta", "Gamma", "Delta", "Epsilon"}

@(private = "file")
build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.hide { return }
	ui.dock_begin(&app.dock, "###dock", {
		title = proc(user: rawptr, id: u32) -> string { return TITLES[id] },
		on_save = proc(user: rawptr, d: ^ui.Dock) { (^App)(user).saves += 1 },
		user = app, close_buttons = true, windows = true,
	})
	for p in u32(1) ..= 4 {
		app.built[p] = false
		if ui.dock_panel(&app.dock, p) {
			app.built[p] = true
			ui.label(fmt.tprintf("%s content###content", TITLES[p]))
		}
	}
	app.result = ui.dock_end(&app.dock)
	if app.result.windowed != ui.DOCK_NO_PANEL { app.windowed = app.result.windowed }
}

// a and b in one stack at the left, c at the right
@(private = "file")
setup :: proc(t: ^testing.T, app: ^App) -> ^session.Session {
	ui.dock_init(&app.dock)
	ok := ui.dock_parse(&app.dock, "dock1 x0.500([*a,b] [*c])", id_of, nil)
	testing.expect(t, ok)
	s := session.start(t, {build = build, user = app, no_renderer = true})
	session.frames(s, 2)
	return s
}

@(private = "file")
layout :: proc(app: ^App) -> string { return ui.dock_format(&app.dock, name_of, nil) }

@(private = "file")
mid :: proc(r: ui.Rect) -> [2]f32 { return (r.min + r.max) * 0.5 }

@(private = "file")
tab :: proc(s: ^session.Session, name: string) -> [2]f32 { return session.center(session.get(s, name)) }

// The user leaves the window in the middle of a drag: no release came, nothing is dropped.
@(test)
a_drag_cut_by_the_window_drops_nothing :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	right := ui.dock_leaf_of(&app.dock, 3)
	target := mid(ui.dock_markers(app.dock.nodes[right].rect, app.dock.metrics)[.Center]) + app.dock.origin
	at := tab(s, "dock_tab_2")
	session.press(s, at)
	before := layout(&app)   // (the press showed its tab)
	session.move(s, target)
	session.frames(s, 2)
	testing.expect(t, app.result.dragging, "dragging")
	session.activate(s, false)
	session.frames(s, 2)
	testing.expect(t, !app.result.dragging, "over")
	testing.expect_value(t, layout(&app), before)
}

// Two closes asked in one frame: both are done.
@(test)
two_closes_in_one_frame_both_close :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	b := tab(s, "dock_tab_2")
	c: [2]f32   // (the close button of the last stack's tab)
	for i in 0 ..< TAB_CLOSE_SEARCH { if k := session.find(s, "dock_close", i); k != nil { c = session.center(k) } }
	session.event(s, {kind = .Mouse_Move, pos = c})
	session.frame(s)
	session.event(s, {kind = .Mouse_Press, button = .Left, pos = c})
	session.frame(s)
	session.event(s, {kind = .Mouse_Press, button = .Middle, pos = b})
	session.event(s, {kind = .Mouse_Release, button = .Middle, pos = b})
	session.event(s, {kind = .Mouse_Release, button = .Left, pos = c})
	session.frames(s, 2)
	testing.expect(t, !ui.dock_has(&app.dock, 2), "the tab of the middle click")
	testing.expect(t, !ui.dock_has(&app.dock, 3), "the tab of the close button")
}

// The stack's menu of a panel that closes: not left open with nothing to say.
@(test)
the_menu_of_a_closed_panel_closes :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	ui.dock_open_menu(&app.dock, 1, {100, 100})
	session.frames(s, 2)
	testing.expect(t, ui.menu_any_open(), "open")
	ui.dock_close(&app.dock, 1)
	session.frames(s, 2)
	testing.expect(t, !ui.menu_any_open(), "closed")
}

// The stack a drag was over goes before the drop: the panel stays where it is, nothing drops on a slot soon something else.
@(test)
a_drop_on_a_stack_that_went_drops_nothing :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	right := ui.dock_leaf_of(&app.dock, 3)
	target := mid(ui.dock_markers(app.dock.nodes[right].rect, app.dock.metrics)[.Center]) + app.dock.origin
	session.press(s, tab(s, "dock_tab_2"))
	session.move(s, target)
	session.frames(s, 2)
	testing.expect(t, app.result.dragging, "dragging")
	ui.dock_close(&app.dock, 3)
	session.release(s, target)
	session.frames(s, 2)
	testing.expect(t, ui.dock_has(&app.dock, 2), "the panel dragged is in the dock")
	testing.expect_value(t, ui.dock_leaf_of(&app.dock, 2), ui.dock_leaf_of(&app.dock, 1))
}

@(test)
a_tab_dragged_onto_each_target :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	testing.expect(t, app.built[1] && !app.built[2] && app.built[3], "the shown panels are built")
	for k in ui.Dock_Marker {
		testing.expect(t, ui.dock_parse(&app.dock, "dock1 x0.500([*a,b] [*c])", id_of, nil))
		session.frames(s, 2)
		right := ui.dock_leaf_of(&app.dock, 3)
		target := mid(ui.dock_markers(app.dock.nodes[right].rect, app.dock.metrics)[k]) + app.dock.origin
		saves := app.saves
		session.drag(s, tab(s, "dock_tab_2"), target)
		session.frames(s, 2)
		got := layout(&app)
		// (a stays where it was: the main tree is [a] then the split of the right stack)
		switch k {
		case .Center: testing.expect_value(t, got, "dock1 x0.500([*a] [c,*b])")
		case .Left:   testing.expect_value(t, got, "dock1 x0.500([*a] x0.500([*b] [*c]))")
		case .Right:  testing.expect_value(t, got, "dock1 x0.500([*a] x0.500([*c] [*b]))")
		case .Top:    testing.expect_value(t, got, "dock1 x0.500([*a] y0.500([*b] [*c]))")
		case .Bottom: testing.expect_value(t, got, "dock1 x0.500([*a] y0.500([*c] [*b]))")
		}
		testing.expect(t, app.saves > saves, "saved when dropped")
	}
}

@(test)
a_tab_dragged_to_the_edges_of_the_space :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)

	for k in ([]ui.Dock_Marker{.Left, .Right, .Top, .Bottom}) {
		testing.expect(t, ui.dock_parse(&app.dock, "dock1 x0.500([*a,b] [*c])", id_of, nil))
		session.frames(s, 2)
		target := mid(ui.dock_edge_markers(app.dock.size, app.dock.metrics)[k]) + app.dock.origin
		session.drag(s, tab(s, "dock_tab_3"), target)
		session.frames(s, 2)
		got := layout(&app)
		// c's stack goes; the rest of the tree is split at that edge
		switch k {
		case .Left:   testing.expect_value(t, got, "dock1 x0.250([*c] [*a,b])")
		case .Right:  testing.expect_value(t, got, "dock1 x0.750([*a,b] [*c])")
		case .Top:    testing.expect_value(t, got, "dock1 y0.250([*c] [*a,b])")
		case .Bottom: testing.expect_value(t, got, "dock1 y0.750([*a,b] [*c])")
		case .Center:
		}
	}
}

@(test)
a_tab_moved_along_its_strip :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	ui.dock_add(&app.dock, 4, ui.dock_with(&app.dock, 1))   // [a,b,*d]
	session.frames(s, 2)
	d4 := session.get(s, "dock_tab_4")
	to := [2]f32{d4.rect.max.x - 2, mid(d4.rect).y}
	session.drag(s, tab(s, "dock_tab_1"), to)
	testing.expect_value(t, layout(&app), "dock1 x0.500([b,d,*a] [*c])")
	// into the other stack's strip, before its tab
	c := session.get(s, "dock_tab_3")
	session.drag(s, tab(s, "dock_tab_2"), {c.rect.min.x + 2, mid(c.rect).y})
	testing.expect_value(t, layout(&app), "dock1 x0.500([*d,a] [*b,c])")
}

@(test)
dropped_outside_it_floats_and_a_double_click_docks_it_back :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	// over the left stack's body but on no square: floating there
	left := app.dock.nodes[ui.dock_leaf_of(&app.dock, 1)].rect
	at := [2]f32{left.min.x + 120, left.min.y + 150} + app.dock.origin
	session.drag(s, tab(s, "dock_tab_2"), at)
	testing.expect_value(t, len(app.dock.floats), 1)
	testing.expect(t, ui.dock_is_floating(&app.dock, ui.dock_leaf_of(&app.dock, 2)))
	testing.expect(t, app.built[2], "the floating panel is built")
	testing.expect(t, session.find(s, fmt.tprintf("dock_float_%d", app.dock.floats[0])) != nil)
	// moved by the empty part of its strip
	root := app.dock.floats[0]
	before := app.dock.nodes[root].rect
	grab := session.find(s, "dock_grab", 2)   // (the main tree's two stacks, then the floating one)
	if !testing.expect(t, grab != nil) { return }
	g := [2]f32{grab.rect.max.x - 10, mid(grab.rect).y}
	session.drag(s, g, g + {30, 20})
	after := app.dock.nodes[root].rect
	testing.expect_value(t, after.min - before.min, ui.Vec2{30, 20})
	// a double click on it: back into the stack it came from
	session.click_at(s, g + {30, 20}, count = 2)
	testing.expect_value(t, len(app.dock.floats), 0)
	testing.expect_value(t, layout(&app), "dock1 x0.500([a,*b] [*c])")
}

@(test)
escape_cancels_a_drag :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click(s, "dock_tab_2")
	before := layout(&app)
	from := tab(s, "dock_tab_2")
	right := ui.dock_leaf_of(&app.dock, 3)
	target := mid(ui.dock_markers(app.dock.nodes[right].rect, app.dock.metrics)[.Left]) + app.dock.origin
	session.press(s, from)
	session.move(s, from + {20, 0})
	session.move(s, target)
	testing.expect(t, app.result.dragging, "dragging: the targets show")
	testing.expect(t, session.find(s, "dock_overlay") != nil)
	testing.expect_value(t, app.dock.drag.target.place, ui.Dock_Place.Left)
	session.key(s, .Escape)
	testing.expect(t, !app.result.dragging)
	testing.expect(t, session.find(s, "dock_overlay") == nil)
	session.release(s, target)
	testing.expect_value(t, layout(&app), before)
}

// A tab held over the left of c's stack, past the threshold.
@(private = "file")
hold_tab :: proc(s: ^session.Session, app: ^App, name: string) -> (target: [2]f32) {
	right := ui.dock_leaf_of(&app.dock, 3)
	target = mid(ui.dock_markers(app.dock.nodes[right].rect, app.dock.metrics)[.Left]) + app.dock.origin
	from := tab(s, name)
	session.press(s, from)
	session.move(s, from + {20, 0})
	session.move(s, target)
	return
}

// The panel leaves the dock while its tab is held: the drop brings nothing back.
@(test)
a_panel_closed_while_its_tab_is_held_stays_closed :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click(s, "dock_tab_2")
	target := hold_tab(s, &app, "dock_tab_2")
	testing.expect(t, app.result.dragging, "dragging")
	ui.dock_close(&app.dock, 2)
	session.frame(s)
	testing.expect(t, !app.result.dragging, "the drag ended with it")
	session.release(s, target)
	session.frames(s, 2)
	testing.expect(t, !ui.dock_has(&app.dock, 2), "closed it stays")
}

// The last panel of a floating root goes while the root is held: the root is gone, and nothing reads it.
@(test)
a_floating_panel_closed_while_held_ends_the_drag :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	testing.expect(t, ui.dock_float(&app.dock, 2, {{50, 50}, {250, 200}}))
	session.frames(s, 2)
	grab := session.find(s, "dock_grab", 2)
	if !testing.expect(t, grab != nil) { return }
	g := [2]f32{grab.rect.max.x - 10, mid(grab.rect).y}
	session.press(s, g)
	session.move(s, g + {30, 20})
	testing.expect(t, app.result.dragging, "dragging")
	ui.dock_close(&app.dock, 2)
	session.frame(s)
	testing.expect(t, !app.result.dragging, "the drag ended with it")
	session.release(s, g + {30, 20})
	session.frames(s, 2)
	testing.expect_value(t, len(app.dock.floats), 0)
}

// The button went up while the dock was not built: what comes back is what was there, no drop from long ago.
@(test)
a_drag_the_dock_did_not_see_end_drops_nothing :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click(s, "dock_tab_2")
	before := layout(&app)
	target := hold_tab(s, &app, "dock_tab_2")
	app.hide = true
	session.frame(s)
	session.release(s, target)
	session.frames(s, 2)
	app.hide = false
	session.frames(s, 2)
	testing.expect_value(t, layout(&app), before)
}

// Enter on the tab held is no new press: the drag goes on.
@(test)
a_key_on_a_held_tab_leaves_the_drag_alone :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click(s, "dock_tab_2")
	target := hold_tab(s, &app, "dock_tab_2")
	session.key(s, .Return)
	testing.expect(t, app.result.dragging, "still dragging")
	session.release(s, target)
}

@(test)
the_preview_shows_where_it_lands :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	ui.dock_init(&app.dock)
	testing.expect(t, ui.dock_parse(&app.dock, "dock1 x0.500([*a,b] [*c])", id_of, nil))
	s := session.start(t, {build = build, user = &app})
	session.frames(s, 2)
	right := app.dock.nodes[ui.dock_leaf_of(&app.dock, 3)].rect
	probe := [2]int{int(right.min.x) + 20, int(right.max.y) - 20}   // in the lower half of c's stack, on no square
	high := int(right.min.y) + 60   // (the upper half, under the strip)
	before := session.capture(s)
	rest, rest_high := session.pixel(before, probe.x, probe.y), session.pixel(before, probe.x, high)
	from := tab(s, "dock_tab_2")
	session.press(s, from)
	session.move(s, from + {20, 0})
	session.move(s, mid(ui.dock_markers(right, app.dock.metrics)[.Bottom]) + app.dock.origin)
	during := session.capture(s)
	testing.expect(t, !session.near(rest, session.pixel(during, probe.x, probe.y)), "the lower half of the stack is tinted")
	testing.expect(t, session.near(rest_high, session.pixel(during, probe.x, high)), "the upper half is not")
	session.release(s, s.pointer)
	testing.expect_value(t, layout(&app), "dock1 x0.500([*a] y0.500([*c] [*b]))")
}

@(test)
the_keyboard_goes_along_the_strip_and_through_the_menu :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click(s, "dock_tab_1")
	testing.expect_value(t, session.focused_name(s), "dock_tab_1")
	session.key(s, .Right)
	testing.expect(t, ui.dock_shown(&app.dock, 2) && app.built[2])
	testing.expect_value(t, session.focused_name(s), "dock_tab_2")
	session.key(s, .Tab, {.Ctrl})
	testing.expect(t, ui.dock_shown(&app.dock, 1), "Ctrl+Tab: the next panel of the stack")
	testing.expect_value(t, session.focused_name(s), "dock_tab_1")
	session.key(s, .Right, {.Ctrl, .Shift})
	testing.expect_value(t, layout(&app), "dock1 x0.500([b,*a] [*c])")
	// the menu: every target, from the keyboard
	session.key(s, .Menu)
	testing.expect(t, ui.menu_any_open())
	session.click_text(s, "Float")
	testing.expect_value(t, len(app.dock.floats), 1)
	testing.expect(t, ui.dock_is_floating(&app.dock, ui.dock_leaf_of(&app.dock, 1)))
	// roles: a tab list of tabs, each controlling its panel
	strip := session.get(s, fmt.tprintf("dock_leaf_%d", ui.dock_leaf_of(&app.dock, 3)))
	testing.expect(t, strip.a11y != nil && strip.a11y.role == .Tab_List)
	tb := session.get(s, "dock_tab_3")
	testing.expect(t, tb.a11y != nil && tb.a11y.role == .Tab && tb.a11y.selected.? == true)
	body := session.get(s, "dock_body_3")
	testing.expect(t, body.a11y != nil && body.a11y.role == .Tab_Panel)
	testing.expect_value(t, tb.a11y.controls, body.key)
}

@(test)
a_handle_resizes_and_folds :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	split := app.dock.main
	h := session.get(s, fmt.tprintf("dock_split_%d", split))
	testing.expect(t, h.a11y != nil && h.a11y.role == .Splitter)
	c := session.center(h)
	session.drag(s, c, c + {100, 0})
	testing.expect(t, app.dock.nodes[split].ratio > 0.6 && app.dock.nodes[split].ratio < 0.65)
	// a double click folds the second side
	h = session.get(s, fmt.tprintf("dock_split_%d", split))
	session.click_at(s, session.center(h), count = 2)
	testing.expect(t, app.dock.nodes[split].fold)
	testing.expect(t, !app.built[3], "folded: not built")
	// showing it brings it back
	ui.dock_activate(&app.dock, 3)
	session.frames(s, 2)
	testing.expect(t, app.built[3])
}

// dock_held: the left button on one of the dock's controls, for as long as that press lasts and no longer.
@(test)
the_dock_is_held_as_long_as_the_press :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	testing.expect(t, !ui.dock_held(&app.dock), "nothing held")
	// a tab, pressed then dragged; the release ends it
	at := tab(s, "dock_tab_2")
	session.press(s, at)
	testing.expect(t, ui.dock_held(&app.dock), "a tab pressed")
	session.move(s, at + {20, 0})
	testing.expect(t, app.result.dragging && ui.dock_held(&app.dock), "a tab dragged")
	session.release(s, at + {20, 0})
	testing.expect(t, !ui.dock_held(&app.dock), "released")
	// a split's handle; the user leaving the window ends it
	h := session.center(session.get(s, fmt.tprintf("dock_split_%d", app.dock.main)))
	session.press(s, h)
	session.move(s, h + {10, 0})
	testing.expect(t, ui.dock_held(&app.dock), "a handle held")
	session.activate(s, false)
	session.frame(s)
	testing.expect(t, !ui.dock_held(&app.dock), "the user left the window")
	session.activate(s, true)
	session.release(s, h + {10, 0})
	// another button on a tab is no hold of the dock's
	session.press(s, tab(s, "dock_tab_3"), .Right)
	testing.expect(t, !ui.dock_held(&app.dock), "the right button")
	session.release(s, tab(s, "dock_tab_3"), .Right)
	// a floating panel's corner; its box going ends it
	testing.expect(t, ui.dock_float(&app.dock, 2, {{50, 50}, {250, 200}}))
	session.frames(s, 2)
	g := session.center(session.get(s, fmt.tprintf("dock_grip_%d", app.dock.floats[0])))
	session.press(s, g)
	session.move(s, g + {10, 10})
	testing.expect(t, ui.dock_held(&app.dock), "a corner held")
	app.hide = true
	session.frames(s, 2)
	app.hide = false
	session.frames(s, 2)
	testing.expect(t, !ui.dock_held(&app.dock), "its box went: the press with it")
	session.release(s, g + {10, 10})
}

// A floating panel's corner shows the cursor of a bottom right corner, as a window's and a dialog's do: it showed the
// double arrow of a diagonal (nwse-resize), which a theme without it drew the other way.
@(test)
a_floating_panels_corner_has_a_corners_cursor :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	testing.expect(t, ui.dock_float(&app.dock, 2, {{50, 50}, {250, 200}}))
	session.frames(s, 2)
	session.move(s, session.center(session.get(s, fmt.tprintf("dock_grip_%d", app.dock.floats[0]))))
	session.frames(s, 2)
	testing.expect_value(t, session.cursor(s), platform.Cursor.Resize_SE)
}

@(test)
a_close_button_closes_the_panel :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	session.click_at(s, session.center(session.acts_on(session.find(s, "dock_close", 0))))
	testing.expect_value(t, layout(&app), "dock1 x0.500([*b] [*c])")
	session.click(s, "dock_tab_3", button = platform.Mouse_Button.Middle)
	testing.expect_value(t, layout(&app), "dock1 [*b]")
}

// "Open in a window" (Dock_Options.windows): the panel leaves the layout, its content is no longer built in the dock, the
// result names it once, and the layout is saved; dock_add brings it back.
@(test)
a_panel_goes_to_a_window_of_its_own_and_comes_back :: proc(t: ^testing.T) {
	app: App
	defer ui.dock_destroy(&app.dock)
	s := setup(t, &app)
	saves := app.saves
	ui.dock_open_menu(&app.dock, 2, {100, 100})
	session.frame(s)
	session.click_text(s, "Open in a window")
	testing.expect_value(t, app.windowed, 2)
	testing.expect(t, !ui.dock_has(&app.dock, 2) && !app.built[2], "out of the dock")
	testing.expect_value(t, layout(&app), "dock1 x0.500([*a] [*c])")
	testing.expect(t, app.saves > saves, "the layout saved")
	testing.expect_value(t, app.result.windowed, ui.DOCK_NO_PANEL)   // (told once)
	ui.dock_add(&app.dock, 2, ui.dock_with(&app.dock, 1))
	session.frames(s, 2)
	testing.expect(t, ui.dock_has(&app.dock, 2), "the window closed: back in the dock")
}
