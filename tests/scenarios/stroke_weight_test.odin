package scenarios_test

// A thin ring's corners, blended in linear light, weigh as in sRGB values when its backdrop is given (draw.rect's
// `backdrop`): darker than without it on a light surface; its straight sides, whole pixels, are the same.

import "core:testing"
import "../../src/draw"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") RING :: draw.Rect{{20, 20}, {120, 80}}
@(private = "file") SHIFT :: 140   // the second ring, beside the first
@(private = "file") SURFACE :: draw.Color{0.9, 0.9, 0.9, 1}
@(private = "file") STROKE :: draw.Color{0.05, 0.25, 0.05, 1}

@(test)
a_rings_corners_weigh_as_its_sides :: proc(t: ^testing.T) {
	s := session.start(t, {size = {320, 120}, build = proc(s: ^session.Session) {
		ui.next({fixed_x = 0, fixed_y = 0, width = ui.px(320), height = ui.px(120)})
		ui.custom("###rings", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			draw.rect(dc, b.rect, SURFACE)
			draw.rect(dc, RING, STROKE, 12, 1)
			draw.rect(dc, draw.rect_shift(RING, {SHIFT, 0}), STROKE, 12, 1, backdrop = SURFACE)
		}, nil)
	}})
	session.frames(s, 2)
	img := session.capture(s)
	// the ink of a corner: how much darker than the surface its pixels are
	ink :: proc(img: session.Image, x0, y0: int) -> (sum: int) {
		surface := int(session.pixel(img, 5, 5).g)
		for y in y0 ..< y0 + 12 {
			for x in x0 ..< x0 + 12 {
				sum += surface - int(session.pixel(img, x, y).g)
			}
		}
		return
	}
	plain, given := ink(img, 20, 20), ink(img, 20 + SHIFT, 20)
	testing.expectf(t, plain > 0, "a ring is drawn: %d", plain)
	testing.expectf(t, f32(given) > f32(plain) * 1.15, "the corner with its backdrop is heavier: %d against %d", given, plain)
	side, side_given := session.pixel(img, 70, 20), session.pixel(img, 70 + SHIFT, 20)
	testing.expectf(t, session.near(side, side_given, 1), "the straight side the same: %v against %v", side, side_given)
}
