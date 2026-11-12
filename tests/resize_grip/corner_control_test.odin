package resize_grip_test

// A control in a dialog's corner (modal_header, modal_corner): the same margin from the dialog's top and right edges, its
// corners concentric with the dialog's, the header's controls clear of it and centered with it, the grips out of its way.

import "core:math"
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
	open:          bool,
	sized:         bool,     // modal_sized, else modal
	square:        bool,     // the dialog's corners square
	size:          ui.Vec2,
	side, inset:   f32,
	outer:         f32,      // the dialog's radius as drawn
	panel, corner: ui.Rect,
	radius:        f32,      // the control's
	own_header:    bool,     // the header through a program's own `if` form
}

@(private = "file")
wide :: proc(d: ^Corner_Dialog) {
	ui.next({width = ui.fill(), height = ui.px(d.side - 6)})
	ui.build_box({.Draw_Background}, "###wide")   // (a header control as wide as it may be)
}

// A program's own header: its side and margin given once.
@(private = "file", deferred_none = ui.modal_header_end)
own_header :: proc(d: ^Corner_Dialog) -> bool { return ui.modal_header_begin("###head", d.side, d.inset) }

@(private = "file")
corner_dialog :: proc(t: ^testing.T, d: ^Corner_Dialog) -> ^session.Session {
	return session.start(t, {size = {500, 360}, user = d, build = proc(s: ^session.Session) {
		d := (^Corner_Dialog)(s.user)
		em := ui.font_size()
		d.side, d.inset = math.round(em * 2), math.round(em * 0.5)
		if d.sized {
			if ui.modal_sized("corner", {320, 200}, &d.size, &d.open) { corner_content(s, d) }
		} else {
			if ui.modal("corner", 320, &d.open) { corner_content(s, d) }
		}
	}})
}

@(private = "file")
corner_content :: proc(s: ^session.Session, d: ^Corner_Dialog) {
	if d.square { ui.parent_box().radius = 0 }
	d.outer = ui.box_drawn_radius(s.state, ui.parent_box())
	if d.own_header {
		if own_header(d) { wide(d) }
	} else {
		if ui.modal_header("###head", d.side, d.inset) { wide(d) }
	}
	ui.next({width = ui.fill(), height = ui.px(120)})
	ui.build_box({}, "###body")
	b := ui.modal_corner({.Clickable}, "###close")
	d.radius = b.radius
	if ui.signal(b).clicked { d.open = false }
	d.panel = b.parent.rect   // (of the last layout: the test reads it after a few frames)
}

@(private = "file")
inset_alike :: proc(t: ^testing.T, square: bool) {
	d := Corner_Dialog{open = true, square = square}
	s := corner_dialog(t, &d)
	session.frames(s, 2)
	b := session.find(s, "close")
	if !testing.expect(t, b != nil, "the corner control") { return }
	r := b.rect
	testing.expect_value(t, r.min.y - d.panel.min.y, d.inset)
	testing.expect_value(t, d.panel.max.x - r.max.x, d.inset)
	testing.expect_value(t, r.max.x - r.min.x, d.side)
	testing.expect_value(t, r.max.y - r.min.y, d.side)
	testing.expect(t, .Fixed_Radius in b.flags, "its radius is as drawn")
	if square {
		testing.expect_value(t, d.radius, f32(0))
	} else {
		testing.expect(t, d.outer > d.inset, "the dialog's corner is rounder than the margin")
		testing.expect_value(t, d.radius, ui.concentric_radius(d.outer, d.inset))
	}
}

@(test)
the_corner_control_is_inset_alike_from_the_top_and_the_right :: proc(t: ^testing.T) { inset_alike(t, false) }

@(test)
the_corner_control_of_a_square_dialog_is_square :: proc(t: ^testing.T) { inset_alike(t, true) }

@(test)
the_header_leaves_the_corner_to_its_control :: proc(t: ^testing.T) { header_clear(t, false) }

// A program's own `if` form of the header ends it once: wrapping modal_header ended it twice, and the build's parents with it.
@(test)
a_program_s_own_header_is_the_same :: proc(t: ^testing.T) { header_clear(t, true) }

@(private = "file")
header_clear :: proc(t: ^testing.T, own: bool) {
	d := Corner_Dialog{open = true, sized = true, own_header = own}
	s := corner_dialog(t, &d)
	session.frames(s, 2)
	corner, wide := session.find(s, "close"), session.find(s, "wide")
	if !testing.expect(t, corner != nil && wide != nil, "the control and the header") { return }
	testing.expectf(t, wide.rect.max.x <= corner.rect.min.x - d.inset, "the header ends at %v, the control begins at %v", wide.rect.max.x, corner.rect.min.x)
	testing.expect_value(t, session.center(wide).y, session.center(corner).y)
	// the dialog's top right grip is out of the control's way: a press in its top right corner is the control's
	grip := session.find(s, "modal_grip5")
	if testing.expect(t, grip != nil, "the top right grip") {
		g, c := grip.rect, corner.rect
		testing.expectf(t, g.max.x <= c.min.x || g.min.x >= c.max.x || g.max.y <= c.min.y || g.min.y >= c.max.y, "the grip %v is on the control %v", g, c)
	}
	session.click_at(s, {corner.rect.max.x - 1, corner.rect.min.y + 1})
	session.frames(s, 2)
	testing.expect(t, !d.open, "a press in the control's corner closes the dialog")
}
