package scenarios_test

// A resize grip in a dialog's corner: the corner stays square, a bevel toward the border colour is cut across it (darker on a light
// theme, lighter on a dark one), and the other corners are round.

import "core:testing"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") GRIP_WINDOW :: [2]int{400, 300}

@(private = "file")
Grip_Dialog :: struct { size: ui.Vec2, open: bool, panel: ui.Rect }

@(private = "file")
grip_dialog :: proc(t: ^testing.T, light: bool) {
	d := Grip_Dialog{open = true}
	s := session.start(t, {size = GRIP_WINDOW, dpi_scale = 2, palette = ui.palette_of("Midnight", light = light), user = &d, build = proc(s: ^session.Session) {
		d := (^Grip_Dialog)(s.user)
		if ui.modal_sized("grip", {200, 150}, &d.size, &d.open) {
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
