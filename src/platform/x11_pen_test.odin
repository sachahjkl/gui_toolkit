package platform

import "core:encoding/endian"
import "core:math"
import "core:testing"
import turn "../turn"

@(private = "file")
append_u16 :: proc(buf: ^[dynamic]u8, v: u16) {
	a: [2]u8
	endian.put_u16(a[:], .Little, v)
	append(buf, ..a[:])
}

@(private = "file")
append_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	a: [4]u8
	endian.put_u32(a[:], .Little, v)
	append(buf, ..a[:])
}

@(private = "file")
append_i32 :: proc(buf: ^[dynamic]u8, v: i32) {
	a: [4]u8
	endian.put_i32(a[:], .Little, v)
	append(buf, ..a[:])
}

@(private = "file")
append_fp3232 :: proc(buf: ^[dynamic]u8, integral: i32, frac: u32 = 0) {
	append_i32(buf, integral)
	append_u32(buf, frac)
}

@(private = "file")
append_valuator_class :: proc(buf: ^[dynamic]u8, src_id, num: u16, label: u32, min_v, max_v: i32) {
	append_u16(buf, XI_CLASS_VALUATOR)
	append_u16(buf, 11) // 44 bytes = 11 words
	append_u16(buf, src_id)
	append_u16(buf, num)
	append_u32(buf, label)
	append_fp3232(buf, min_v)
	append_fp3232(buf, max_v)
	append_fp3232(buf, 0)
	append_u32(buf, 0) // resolution
	append(buf, u8(1), u8(0), u8(0), u8(0)) // mode + pad0[3]
}

@(private = "file")
append_device_hdr :: proc(buf: ^[dynamic]u8, id, dtype, nclasses: u16, name: string, enabled := true) {
	append_u16(buf, id)
	append_u16(buf, dtype)
	append_u16(buf, 2) // attachment
	append_u16(buf, nclasses)
	append_u16(buf, u16(len(name)))
	append(buf, enabled ? u8(1) : u8(0), u8(0))
	append(buf, ..transmute([]u8)name)
	for len(buf) % 4 != 0 { append(buf, u8(0)) }
}

@(test)
xi_parse_devices_finds_pens_and_ignores_touchpads_and_mice :: proc(t: ^testing.T) {
	atoms := Xi_Atoms{pressure = 100, tilt_x = 101, tilt_y = 102}
	buf := make([dynamic]u8, context.temp_allocator)
	// 32-byte XIQueryDevice reply header (4 devices)
	for _ in 0 ..< 32 { append(&buf, u8(0)) }
	endian.put_u16(buf[8:10], .Little, 4)

	// 1. Wacom stylus with pressure 0..8191 and tilt X/Y -60..60
	append_device_hdr(&buf, 12, XI_DEVICE_SLAVE_POINTER, 3, "Wacom Intuos Pen stylus")
	append_valuator_class(&buf, 12, 2, atoms.pressure, 0, 8191)
	append_valuator_class(&buf, 12, 3, atoms.tilt_x, -60, 60)
	append_valuator_class(&buf, 12, 4, atoms.tilt_y, -60, 60)

	// 2. Wacom eraser with pressure 0..8191
	append_device_hdr(&buf, 13, XI_DEVICE_SLAVE_POINTER, 1, "Wacom Intuos Pen eraser")
	append_valuator_class(&buf, 13, 2, atoms.pressure, 0, 8191)

	// 3. Touchpad with Abs Pressure AND XITouchClass (must be excluded)
	append_device_hdr(&buf, 14, XI_DEVICE_SLAVE_POINTER, 2, "SynPS/2 Synaptics TouchPad")
	append_valuator_class(&buf, 14, 2, atoms.pressure, 0, 255)
	append_u16(&buf, XI_CLASS_TOUCH); append_u16(&buf, 2); append_u32(&buf, 0)

	// 4. Plain USB mouse (no pressure valuator)
	append_device_hdr(&buf, 15, XI_DEVICE_SLAVE_POINTER, 0, "Logitech USB Mouse")

	pens := xi_parse_devices(buf[:], atoms, context.allocator)
	defer delete(pens)

	testing.expect_value(t, len(pens), 2)
	if len(pens) == 2 {
		testing.expect_value(t, pens[0].id, u16(12))
		testing.expect(t, !pens[0].eraser, "stylus is not eraser")
		testing.expect_value(t, pens[0].pressure_num, i16(2))
		testing.expect_value(t, pens[0].tilt_x_num, i16(3))
		testing.expect_value(t, pens[0].tilt_y_num, i16(4))
		testing.expect_value(t, pens[1].id, u16(13))
		testing.expect(t, pens[1].eraser, "eraser detected from name")
	}
}

@(test)
xi_decode_event_and_pen_pressure_tilt_barrel :: proc(t: ^testing.T) {
	pen := Xi_Pen_Device{
		id           = 12,
		pressure_num = 2,
		pressure_min = 0,
		pressure_max = 8192,
		tilt_x_num   = 3,
		tilt_y_num   = 4,
	}

	make_ev :: proc(ev_type: u16, detail: u32, x, y: i32, has_vals: bool, p_raw, tx_raw, ty_raw: i32) -> []u8 {
		buf := make([dynamic]u8, context.temp_allocator)
		for _ in 0 ..< XI_DEVICE_EVENT_HEADER_BYTES { append(&buf, u8(0)) }
		endian.put_u16(buf[8:10], .Little, ev_type)
		endian.put_u32(buf[16:20], .Little, detail)
		endian.put_u32(buf[24:28], .Little, 0x1234)
		endian.put_i32(buf[44:48], .Little, x << 16)
		endian.put_i32(buf[48:52], .Little, y << 16)
		endian.put_u16(buf[52:54], .Little, 1) // buttons_len = 1 word
		endian.put_u16(buf[54:56], .Little, has_vals ? 1 : 0) // valuators_len = 1 word
		endian.put_u16(buf[56:58], .Little, 12) // sourceid
		append_u32(&buf, 0) // buttons mask
		if has_vals {
			// Set bits 2 (pressure), 3 (tilt_x), 4 (tilt_y)
			append_u32(&buf, (1 << 2) | (1 << 3) | (1 << 4))
			append_fp3232(&buf, p_raw)
			append_fp3232(&buf, tx_raw)
			append_fp3232(&buf, ty_raw)
		}
		return buf[:]
	}

	// Truncated buffer rejected cleanly.
	_, ok_short := xi_decode_device_event(make([]u8, 40, context.temp_allocator), &pen)
	testing.expect(t, !ok_short, "truncated packet rejected")

	// Tip down at (120, 80) with half pressure (4096 / 8192 = 0.5) and tilt (30 deg, -15 deg).
	down_ev, ok1 := xi_decode_device_event(make_ev(XI_EVENT_BUTTON_PRESS, 1, 120, 80, true, 4096, 30, -15), &pen)
	testing.expect(t, ok1, "down decoded")
	testing.expect_value(t, down_ev.event_x, f32(120))
	testing.expect_value(t, down_ev.event_y, f32(80))
	pi := xi_pen_apply(&pen, down_ev)
	testing.expect_value(t, pi.kind, Pointer_Kind.Pen)
	testing.expect(t, pi.measured, "pressure is measured")
	testing.expect(t, math.abs(pi.pressure - 0.5) < 0.001, "pressure normalized to 0.5")
	testing.expect(t, math.abs(pi.tilt.x - f32(turn.from_degrees(f64(30)))) < 0.0001, "tilt X in turns")
	testing.expect(t, math.abs(pi.tilt.y - f32(turn.from_degrees(f64(-15)))) < 0.0001, "tilt Y in turns")

	// Barrel button press sets barrel = true without dropping contact.
	barrel_ev, _ := xi_decode_device_event(make_ev(XI_EVENT_BUTTON_PRESS, 2, 125, 82, false, 0, 0, 0), &pen)
	pi_b := xi_pen_apply(&pen, barrel_ev)
	testing.expect(t, pi_b.barrel && pen.contact, "barrel pressed while in contact")

	// Tip up resets contact and pressure returns 0 out of contact.
	up_ev, _ := xi_decode_device_event(make_ev(XI_EVENT_BUTTON_RELEASE, 1, 130, 85, true, 0, 0, 0), &pen)
	pi_u := xi_pen_apply(&pen, up_ev)
	testing.expect_value(t, pi_u.pressure, f32(0))
	testing.expect(t, !pen.contact, "contact released")
}
