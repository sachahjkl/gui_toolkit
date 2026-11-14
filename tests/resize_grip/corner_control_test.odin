package resize_grip_test

// The close cross in a view's dialog header: the same margin from the dialog's top and right edges, its corners concentric
// with the dialog's, the header's controls (view_header_tools) clear of it and centered with it, the grips out of its way.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(test)
an_inset_corner_is_concentric :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.concentric_radius(12, 5), f32(7))
	testing.expect_value(t, ui.concentric_radius(12, 12), f32(0))
	testing.expect_value(t, ui.concentric_radius(12, 20), f32(0))   // (past the outer radius: square, never negative)
	outer := ui.Rect{{10, 20}, {110, 220}}
	Want :: struct { c: ui.Corner, r: ui.Rect }
	wants := []Want{
		{.Top_Left, {{14, 24}, {44, 34}}}, {.Top_Right, {{76, 24}, {106, 34}}},
		{.Bottom_Left, {{14, 206}, {44, 216}}}, {.Bottom_Right, {{76, 206}, {106, 216}}},
	}
	for w in wants {
		r, radius := ui.corner_place(outer, 9, w.c, {30, 10}, 4)
		testing.expectf(t, r == w.r, "%v: %v, not %v", w.c, r, w.r)
		testing.expect_value(t, radius, f32(5))
	}
}

@(private = "file")
Corner_Dialog :: struct {
	views:         ui.Views,
	opened:        bool,
	sized:         bool,     // resizable, else as tall as what is in it
	square:        bool,     // the dialog's corners square
	outer:         f32,      // the dialog's radius as drawn
	panel, corner: ui.Rect,
	state:         ^ui.State,
}

// (a header control as wide as the test needs: the header grows to it)
@(private = "file") WIDE_EM :: 6

@(private = "file")
corner_view :: proc(v: ^ui.View, d: ^Corner_Dialog) {
	if d.square { ui.parent_box().radius = 0 }
	d.outer = ui.box_drawn_radius(d.state, ui.parent_box())
	d.panel = ui.parent_box().rect   // (of the last layout: the test reads it after a few frames)
	if ui.view_header_tools(v) {
		ui.next({width = ui.px(ui.font_size() * WIDE_EM), height = ui.px(ui.font_size())})
		ui.build_box({.Draw_Background}, "###wide")
	}
	ui.next({width = ui.fill(), height = ui.px(120)})
	ui.build_box({}, "###body")
}

@(private = "file")
corner_dialog :: proc(t: ^testing.T, d: ^Corner_Dialog) -> ^session.Session {
	return session.start(t, {size = {500, 360}, user = d, build = proc(s: ^session.Session) {
		d := (^Corner_Dialog)(s.user)
		d.state = s.state
		if d.opened { return }
		d.opened = true
		em := ui.font_size()
		o := ui.View_Options{title = "Files", width_em = 320 / em}
		if d.sized { o.height_em, o.resizable = 200 / em, true }
		ui.view_register(&d.views, "corner", corner_view, o)
		ui.view_open(&d.views, "corner", d)
	}})
}

// The corner's control: the toolkit's close cross.
@(private = "file")
corner_box :: proc(s: ^session.Session, d: ^Corner_Dialog) -> ^ui.Box {
	return session.find(s, "dialog_close")
}

@(private = "file")
inset_alike :: proc(t: ^testing.T, square: bool) {
	d := Corner_Dialog{square = square}
	defer ui.views_destroy(&d.views)
	s := corner_dialog(t, &d)
	session.frames(s, 3)
	b := corner_box(s, &d)
	if !testing.expect(t, b != nil, "the corner control") { return }
	r := b.rect
	inset := r.min.y - d.panel.min.y
	testing.expect(t, inset > 0, "a margin from the dialog's top")
	testing.expect_value(t, d.panel.max.x - r.max.x, inset)
	testing.expect_value(t, r.max.x - r.min.x, r.max.y - r.min.y)
	testing.expect(t, .Fixed_Radius in b.flags, "its radius is as drawn")
	if square {
		testing.expect_value(t, b.radius, f32(0))
	} else {
		testing.expect(t, d.outer > inset, "the dialog's corner is rounder than the margin")
		testing.expect_value(t, b.radius, ui.concentric_radius(d.outer, inset))
	}
	// centered on the header's strip
	head := session.find(s, "view_header")
	if testing.expect(t, head != nil, "the header") {
		testing.expectf(t, abs(session.center(head).y - session.center(b).y) <= 1, "the strip's middle %v, the button's %v", session.center(head).y, session.center(b).y)
	}
}

@(test)
the_corner_control_is_inset_alike_from_the_top_and_the_right :: proc(t: ^testing.T) { inset_alike(t, false) }

@(test)
the_corner_control_of_a_square_dialog_is_square :: proc(t: ^testing.T) { inset_alike(t, true) }

// The header's controls (view_header_tools) and the Detach icon stay clear of the close cross. (A corner control of the
// program's own look has no API any more: the close cross is the toolkit's.)
@(test)
the_header_leaves_the_corner_to_its_control :: proc(t: ^testing.T) {
	d := Corner_Dialog{sized = true}
	defer ui.views_destroy(&d.views)
	s := corner_dialog(t, &d)
	session.frames(s, 3)
	corner, wide := corner_box(s, &d), session.find(s, "wide")
	if !testing.expect(t, corner != nil && wide != nil, "the control and the header") { return }
	inset := corner.rect.min.y - d.panel.min.y
	if detach := session.find(s, "view_detach"); testing.expect(t, detach != nil, "the Detach icon") {
		testing.expectf(t, detach.rect.max.x <= corner.rect.min.x - inset, "the Detach icon ends at %v, the cross begins at %v", detach.rect.max.x, corner.rect.min.x)
		testing.expectf(t, wide.rect.max.x <= detach.rect.min.x, "the tools before the Detach icon")
	}
	testing.expectf(t, wide.rect.max.x <= corner.rect.min.x - inset, "the header ends at %v, the control begins at %v", wide.rect.max.x, corner.rect.min.x)
	testing.expectf(t, abs(session.center(wide).y - session.center(corner).y) <= 1, "the header's control at %v, the corner's at %v", session.center(wide).y, session.center(corner).y)
	// the dialog's top right grip is out of the control's way: a press in its top right corner is the control's
	grip := session.find(s, "modal_grip5")
	if testing.expect(t, grip != nil, "the top right grip") {
		g, c := grip.rect, corner.rect
		testing.expectf(t, g.max.x <= c.min.x || g.min.x >= c.max.x || g.max.y <= c.min.y || g.min.y >= c.max.y, "the grip %v is on the control %v", g, c)
	}
	session.click_at(s, {corner.rect.max.x - 1, corner.rect.min.y + 1})
	session.frames(s, 2)
	testing.expect(t, !ui.view_is_open(&d.views, "corner"), "a press in the control's corner closes the dialog")
}
