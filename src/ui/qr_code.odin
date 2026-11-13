package ui

import "core:fmt"
import "core:math"
import "core:strings"
import "../draw"
import i18n "../i18n"
import "../qr"

// What a qr_code box keeps between builds: its text's code, encoded again only when the text or the level changes.
@(private)
Qr_Cached :: struct {
	text: string,   // owned (the map's allocator)
	ecc:  qr.Ecc,
	code: qr.Code,  // empty when the text is too long (err)
	err:  qr.Error,
	seen: u64,      // the last build that built the box: the others are dropped at its end (qr_trim)
}

@(private = "file")
Qr_Draw :: struct { code: qr.Code }

// The corners of the white square, in ems (its quiet zone keeps the modules away from them).
QR_RADIUS_EM :: f32(0.6)
// The gap between the border and the white square, in ems.
QR_FRAME_GAP_EM :: f32(0.3)
// The border's opacity: the theme's text colour, faint (a frame, not a line that competes with the code).
QR_FRAME_ALPHA :: f32(0.35)

// A QR Code of `text` in a square of `size` pixels (like `px`), its quiet zone included. Dark modules on white, whatever
// the theme: scanners need dark on light. Each module is a whole number of device pixels, the code centred in the box; a
// box too small for one pixel a module is clipped. A text too long for version 40 shows the white square alone. To a
// screen reader it is an image named "QR code: <text>". See docs/qr.md.
qr_code :: proc(id: string, text: string, size: f32, ecc := qr.Ecc.Medium) -> Signal {
	s := gs()
	// (a rounded border of the theme, a gap inside it, then the white square: a frame around the code, which on a dark
	// dialog reads as drawn, not cut out)
	edge := color("text")
	edge.a *= QR_FRAME_ALPHA
	next_merge({width = px(size), height = px(size), radius = font_size() * QR_RADIUS_EM, border = edge})
	b := build_box({.Draw_Border}, id)
	c, kept := &s.qr_codes[b.key]
	if !kept || c.text != text || c.ecc != ecc {
		allocator := s.qr_codes.allocator
		if kept { qr_cached_free(c, allocator) } else { s.qr_codes[b.key] = {}; c = &s.qr_codes[b.key] }
		c.text, c.ecc = strings.clone(text, allocator), ecc
		c.code, c.err = qr.encode(text, ecc, allocator)
	}
	c.seen = s.build_index
	d := frame_new(Qr_Draw)
	d.code = c.code
	b.custom, b.custom_user = qr_draw, d
	a11y_default(b, {role = .Image, name = fmt.aprintf(i18n.tr("QR code: %s"), text, allocator = frame_allocator())})
	return signal(b)
}

// The module size: the most whole pixels that fit the box with the quiet zone (at least 1).
@(private)
qr_module_pixels :: proc(box_side: f32, code_size: int) -> f32 {
	return max(1, math.floor(box_side / f32(code_size + 2 * qr.QUIET_ZONE)))
}

@(private = "file")
qr_draw :: proc(b: ^Box, user: rawptr, dc: ^draw.Context) {
	code := (^Qr_Draw)(user).code
	draw.push_clip(dc, b.rect)
	defer draw.pop_clip(dc)
	gap := math.round(font_size() * QR_FRAME_GAP_EM)
	white := draw.rect_pad(b.rect, -gap)
	radii := box_drawn_radii(gs(), b)
	for &r in radii { r = max(0, r - gap) }
	draw.rect_corners(dc, white, colors4({1, 1, 1, 1}), radii)
	if code.size == 0 { return }
	box := draw.rect_size(white)
	unit := qr_module_pixels(min(box.x, box.y), code.size)
	side := unit * f32(code.size + 2 * qr.QUIET_ZONE)
	// whole pixels from the box's corner, centred: every module edge on a pixel edge
	origin := [2]f32{math.round(white.min.x + (box.x - side) / 2), math.round(white.min.y + (box.y - side) / 2)} + unit * qr.QUIET_ZONE
	// one rect per horizontal run of dark modules
	for y in 0 ..< code.size {
		x := 0
		for x < code.size {
			if !qr.module(code, x, y) { x += 1; continue }
			start := x
			for x < code.size && qr.module(code, x, y) { x += 1 }
			top := origin.y + f32(y) * unit
			draw.rect(dc, {{origin.x + f32(start) * unit, top}, {origin.x + f32(x) * unit, top + unit}}, {0, 0, 0, 1})
		}
	}
}

@(private)
qr_cached_free :: proc(c: ^Qr_Cached, allocator := context.allocator) {
	delete(c.text, allocator)
	qr.destroy(&c.code, allocator)
}

// The codes of boxes this build did not build.
@(private)
qr_trim :: proc(s: ^State) {
	dead := make([dynamic]Key, context.temp_allocator)
	for k, c in s.qr_codes { if c.seen != s.build_index { append(&dead, k) } }
	for k in dead {
		qr_cached_free(&s.qr_codes[k], s.qr_codes.allocator)
		delete_key(&s.qr_codes, k)
	}
}

@(private)
qr_destroy :: proc(s: ^State) {
	for _, &c in s.qr_codes { qr_cached_free(&c, s.qr_codes.allocator) }
	delete(s.qr_codes)
}
