package resize_grip_test

// A resize grip in a dialog's corner: the corner stays square, a bevel toward the border colour is cut across it (darker on a light
// theme, lighter on a dark one), and the other corners are round.

import "core:math"
import "core:testing"
import "../../src/platform"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") GRIP_WINDOW :: [2]int{400, 300}

@(private = "file")
Grip_Dialog :: struct { size: ui.Vec2, open: bool, panel: ui.Rect, em: f32 }

@(private = "file")
grip_dialog :: proc(t: ^testing.T, light: bool) {
	d := Grip_Dialog{open = true}
	s := session.start(t, {size = GRIP_WINDOW, dpi_scale = 2, palette = ui.palette_of("Midnight", light = light), user = &d, build = proc(s: ^session.Session) {
		d := (^Grip_Dialog)(s.user)
		if ui.modal("grip", &d.open, {width_em = 200 / ui.font_size(), height_em = 150 / ui.font_size(), size = &d.size}) {
			d.panel = ui.parent_box().rect
			ui.label("Hello")
		}
	}})
	session.frames(s, 2)
	img := session.capture(s)
	session.save_png(s, light ? "grip_light.png" : "grip_dark.png")
	r := d.panel
	x1, y1 := int(r.max.x) - 1, int(r.max.y) - 1
	x0, y0 := int(r.min.x), int(r.min.y)
	inside := session.pixel(img, x0 + 40, y1 - 4)   // the panel's surface near its bottom edge
	testing.expect(t, session.near(session.pixel(img, x1, y1), session.pixel(img, x1 - 4, y1), 40), "the grip's corner is square (not the scrim)")
	testing.expect(t, !session.near(session.pixel(img, x0, y0), inside, 40), "the top left corner is round")
	// in the bevel, off its dots: toward the border (darker on a light theme, lighter on a dark one)
	shade := session.pixel(img, x1 - 3, y1 - 12)
	sum :: proc(c: session.Color) -> int { return int(c.r) + int(c.g) + int(c.b) }
	if light {
		testing.expectf(t, sum(shade) < sum(inside) - 10, "the bevel is darker: %v against %v", shade, inside)
	} else {
		testing.expectf(t, sum(shade) > sum(inside) + 10, "the bevel is lighter: %v against %v", shade, inside)
	}
}

@(test)
a_dialog_s_resize_grip_is_a_square_bevelled_corner :: proc(t: ^testing.T) {
	grip_dialog(t, true)
	grip_dialog(t, false)
}

// A dialog held at the top of the window (Modal_Options.top): its top stays where it is, its bottom edge follows the pointer, one
// to one, and it has no grips at its top.
@(private = "file")
Top_Dialog :: struct { size: ui.Vec2, open: bool, panel: ui.Rect }

@(test)
a_dialog_held_at_the_top_grows_downward :: proc(t: ^testing.T) {
	d := Top_Dialog{open = true}
	s := session.start(t, {size = {400, 300}, user = &d, build = proc(s: ^session.Session) {
		d := (^Top_Dialog)(s.user)
		if ui.modal("top", &d.open, {width_em = 200 / ui.font_size(), height_em = 120 / ui.font_size(), min_width_em = 100 / ui.font_size(), min_height_em = 60 / ui.font_size(), top = 0.1, size = &d.size}) {
			d.panel = ui.parent_box().rect
			ui.label("Hello")
		}
	}})
	session.frames(s, 2)
	before := d.panel
	testing.expect_value(t, before.min.y, f32(30))
	testing.expect(t, session.find(s, "modal_grip0") == nil && session.find(s, "modal_grip4") == nil && session.find(s, "modal_grip5") == nil, "no grips at its top")
	grip := session.find(s, "modal_grip1")   // (the bottom edge)
	if !testing.expect(t, grip != nil, "its bottom edge's grip") { return }
	at := session.center(grip)
	session.press(s, at)
	session.move(s, at + {0, 20})
	session.move(s, at + {0, 40})
	session.release(s, at + {0, 40})
	session.frames(s, 2)
	testing.expect_value(t, d.panel.min.y, before.min.y)
	testing.expect_value(t, d.panel.max.y - d.panel.min.y, before.max.y - before.min.y + 40)
	testing.expect_value(t, d.panel.max.x - d.panel.min.x, before.max.x - before.min.x)
}

// All of the grip's bevel is the corner: the pointer on its upper part, past the corner's size, has the corner's cursor, not
// the bottom edge's.
@(test)
the_whole_bevel_has_the_corner_cursor :: proc(t: ^testing.T) {
	d := Grip_Dialog{open = true}
	s := session.start(t, {size = GRIP_WINDOW, user = &d, build = proc(s: ^session.Session) {
		d := (^Grip_Dialog)(s.user)
		if ui.modal("grip", &d.open, {width_em = 200 / ui.font_size(), height_em = 150 / ui.font_size(), size = &d.size}) {
			d.panel = ui.parent_box().rect
			d.em = ui.font_size()
			ui.label("Hello")
		}
	}})
	session.frames(s, 2)
	// on the bevel near the bottom edge, past the corner's own size (0.9 em) by 3 of its 5 px
	session.move(s, {d.panel.max.x - math.round(d.em * 0.9) - 3, d.panel.max.y - 2})
	session.frames(s, 2)
	testing.expect_value(t, session.cursor(s), platform.Cursor.Resize_SE)
}
