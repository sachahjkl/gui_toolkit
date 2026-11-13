package resize_grip_test

// A control in a dialog's corner (dialog_header's close button, modal_corner): the same margin from the dialog's top and
// right edges, its corners concentric with the dialog's, the header's controls clear of it and centered with it, the grips
// out of its way.

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
	outer:         f32,      // the dialog's radius as drawn
	panel, corner: ui.Rect,
	own_header:    bool,     // the header through a program's own `if` form
	own_control:   bool,     // the corner's control of the program's own look (modal_corner), not the toolkit's button
}

@(private = "file")
wide :: proc() {
	ui.next({width = ui.fill(), height = ui.px(ui.font_size())})
	ui.build_box({.Draw_Background}, "###wide")   // (a header control as wide as it may be)
}

// A program's own header: its options given once.
@(private = "file", deferred_none = ui.dialog_header_end)
own_header :: proc() -> bool { return ui.dialog_header_begin("head", "Files", {close = true}) }

@(private = "file")
corner_dialog :: proc(t: ^testing.T, d: ^Corner_Dialog) -> ^session.Session {
	return session.start(t, {size = {500, 360}, user = d, build = proc(s: ^session.Session) {
		d := (^Corner_Dialog)(s.user)
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
	d.panel = ui.parent_box().rect   // (of the last layout: the test reads it after a few frames)
	if d.own_header {
		if own_header() { wide() }
	} else {
		if ui.dialog_header("head", "Files", {close = true}) {
			wide()
			if d.own_control {
				b := ui.modal_corner({.Clickable}, "###own_close")
				if ui.signal(b).clicked { d.open = false }
			}
		}
	}
	ui.next({width = ui.fill(), height = ui.px(120)})
	ui.build_box({}, "###body")
}

// The corner's control: the toolkit's close button, or the program's own.
@(private = "file")
corner_box :: proc(s: ^session.Session, d: ^Corner_Dialog) -> ^ui.Box {
	return session.find(s, d.own_control ? "own_close" : "dialog_close")
}

@(private = "file")
inset_alike :: proc(t: ^testing.T, square: bool) {
	d := Corner_Dialog{open = true, square = square}
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
	head := session.find(s, "head")
	if testing.expect(t, head != nil, "the header") {
		testing.expectf(t, abs(session.center(head).y - session.center(b).y) <= 1, "the strip's middle %v, the button's %v", session.center(head).y, session.center(b).y)
	}
}

@(test)
the_corner_control_is_inset_alike_from_the_top_and_the_right :: proc(t: ^testing.T) { inset_alike(t, false) }

@(test)
the_corner_control_of_a_square_dialog_is_square :: proc(t: ^testing.T) { inset_alike(t, true) }

@(test)
the_header_leaves_the_corner_to_its_control :: proc(t: ^testing.T) { header_clear(t, false, false) }

// A program's own `if` form of the header ends it once: wrapping dialog_header ended it twice, and the build's parents with it.
@(test)
a_program_s_own_header_is_the_same :: proc(t: ^testing.T) { header_clear(t, true, false) }

// A control of the program's own look in the corner takes the place of the toolkit's button: one control there, placed alike.
@(test)
a_program_s_own_corner_control_replaces_the_close_button :: proc(t: ^testing.T) {
	header_clear(t, false, true)
}

@(private = "file")
header_clear :: proc(t: ^testing.T, own, own_control: bool) {
	d := Corner_Dialog{open = true, sized = true, own_header = own, own_control = own_control}
	s := corner_dialog(t, &d)
	session.frames(s, 3)
	corner, wide := corner_box(s, &d), session.find(s, "wide")
	if !testing.expect(t, corner != nil && wide != nil, "the control and the header") { return }
	if own_control { testing.expect(t, session.find(s, "dialog_close") == nil, "the toolkit's button is not built besides the program's") }
	inset := corner.rect.min.y - d.panel.min.y
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
	testing.expect(t, !d.open, "a press in the control's corner closes the dialog")
}
