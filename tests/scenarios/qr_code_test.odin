package scenarios_test

// ui.qr_code by its pixels: every module and the quiet zone where the code says, in whole pixels, dark on light on a dark
// theme; a new text drawn again through partial redraw; what a screen reader is told.

import "core:fmt"
import "core:math"
import "core:testing"
import "../../src/qr"
import "../../src/render"
import "../../src/testkit/session"
import "../../src/testkit/unwatched"
import "../../src/ui"

@(private = "file") QR_WINDOW :: [2]int{320, 320}
@(private = "file") QR_AT :: [2]f32{10.4, 20.6}   // (between pixels: what the layout makes of it, the code is drawn from)
@(private = "file") QR_SIZE :: 150
@(private = "file") BLACK :: session.Color{0, 0, 0, 255}
@(private = "file") WHITE :: session.Color{255, 255, 255, 255}
@(private = "file") QR_URL :: "https://abcdef0123456789.cfmfdgcrti5w.opentunnel.xyz/auth/connect/0123456789abcdef0123456789abcdef"

// Every pixel of the symbol, quiet zone included, is exactly black or white as its module says, from the white square
// inside the box's frame (its gap in from the border); the square's rounded corners, in the quiet zone, are not looked at.
@(private = "file")
expect_code :: proc(t: ^testing.T, s: ^session.Session, text: string, loc := #caller_location) {
	img := session.capture(s)
	b := session.get(s, "qr")
	gap := math.round(b.font_size * ui.QR_FRAME_GAP_EM)
	corner := int(math.ceil(max(0, b.font_size * ui.QR_RADIUS_EM - gap)))
	testing.expect(t, b.rect.max.x - b.rect.min.x == QR_SIZE && b.rect.max.y - b.rect.min.y == QR_SIZE, "the size asked", loc = loc)
	box := ui.Rect{b.rect.min + gap, b.rect.max - gap}
	code, err := qr.encode(text)
	defer qr.destroy(&code)
	testing.expect(t, err == .None, "encodes", loc = loc)
	n := code.size + 2 * qr.QUIET_ZONE
	w, h := box.max.x - box.min.x, box.max.y - box.min.y
	unit := int(math.floor(min(w, h) / f32(n)))
	side := unit * n
	ox := int(math.round(box.min.x + (w - f32(side)) / 2))
	oy := int(math.round(box.min.y + (h - f32(side)) / 2))
	wrong := 0
	for py in 0 ..< side {
		for px in 0 ..< side {
			// (the white square's corner: rounded, its pixels blend with the frame)
			if (px < corner || px >= side - corner) && (py < corner || py >= side - corner) { continue }
			dark := qr.module(code, px / unit - qr.QUIET_ZONE, py / unit - qr.QUIET_ZONE)
			if !session.near(session.pixel(img, ox + px, oy + py), dark ? BLACK : WHITE, 0) { wrong += 1 }
		}
	}
	testing.expectf(t, wrong == 0, "%d of %d pixels are not their module's black or white (modules of %d px at %d,%d)", wrong, side * side, unit, ox, oy, loc = loc)
	// the three finders' corners dark, the quiet zone light
	for c in ([3][2]int{{0, 0}, {code.size - 1, 0}, {0, code.size - 1}}) {
		x, y := ox + (c.x + qr.QUIET_ZONE) * unit, oy + (c.y + qr.QUIET_ZONE) * unit
		testing.expect(t, session.near(session.pixel(img, x, y), BLACK, 0), "a finder's corner is dark", loc = loc)
	}
	testing.expect(t, session.near(session.pixel(img, ox + corner, oy + corner), WHITE, 0), "the quiet zone is light", loc = loc)
	testing.expect(t, session.near(session.pixel(img, ox + side - 1 - corner, oy + side - 1 - corner), WHITE, 0), "to its last pixel", loc = loc)
}

@(test)
a_qr_code_is_drawn_in_whole_pixels :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	Run :: struct { text: string }
	r := Run{"HELLO WORLD"}
	s := session.start(t, {size = QR_WINDOW, user = &r, build = proc(s: ^session.Session) {
		r := (^Run)(s.user)
		ui.next({fixed_x = QR_AT.x, fixed_y = QR_AT.y})
		ui.qr_code("###qr", r.text, QR_SIZE)
	}})
	expect_code(t, s, r.text)
	b := session.get(s, "qr")
	testing.expect_value(t, b.a11y.role, ui.A11y_Role.Image)
	testing.expect_value(t, b.a11y.name, "QR code: HELLO WORLD")

	// another text, through partial redraw: the region it works out gives the same bytes as a whole frame
	ui.set_partial_redraw(s.state, true)
	session.frames(s, 2)
	render.set_damage_verify(s.renderer, true)
	r.text = QR_URL
	session.frame(s)
	testing.expect_value(t, render.damage_verify_differences(s.renderer), 0)
	expect_code(t, s, QR_URL)
	testing.expect_value(t, session.get(s, "qr").a11y.name, fmt.tprintf("QR code: %s", QR_URL))
}) }
