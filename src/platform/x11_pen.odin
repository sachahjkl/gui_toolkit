package platform

// Pure XInput 2 device-info and event decoding for X11 pen pressure (src/md/features/pen-input.md).
// System-free so unit tests (x11_pen_test.odin) verify the binary wire parser, pen vs touchpad filtering, pressure
// normalization, tilt conversion to turns, and truncated-packet safety on every OS without an X server.

import "core:encoding/endian"
import "core:strings"
import "../ascii"
import turn "../turn"

@(private) XI_ALL_DEVICES          :: u16(0)
@(private) XI_ALL_MASTER_DEVICES   :: u16(1)

@(private) XI_DEVICE_SLAVE_POINTER  :: u16(3)
@(private) XI_DEVICE_FLOATING_SLAVE :: u16(5)

@(private) XI_CLASS_VALUATOR :: u16(2)
@(private) XI_CLASS_TOUCH    :: u16(8)

@(private) XI_EVENT_BUTTON_PRESS   :: u16(4)
@(private) XI_EVENT_BUTTON_RELEASE :: u16(5)
@(private) XI_EVENT_MOTION         :: u16(6)
@(private) XI_EVENT_LEAVE          :: u16(8)
@(private) XI_EVENT_HIERARCHY      :: u16(11)

@(private) XI_MASK_BUTTON_PRESS    :: u32(1 << 4)
@(private) XI_MASK_BUTTON_RELEASE  :: u32(1 << 5)
@(private) XI_MASK_MOTION          :: u32(1 << 6)
@(private) XI_MASK_LEAVE           :: u32(1 << 8)
@(private) XI_MASK_HIERARCHY       :: u32(1 << 11)

@(private) XI_DEVICE_EVENT_HEADER_BYTES :: 84

// XInput 2 FP3232 fixed-point value (integral + frac / 2^32).
@(private)
Xi_Fp3232 :: struct {
	integral: i32,
	frac:     u32,
}
#assert(size_of(Xi_Fp3232) == 8)

// Atoms identifying the valuators read on pen devices.
@(private)
Xi_Atoms :: struct {
	pressure: u32,
	tilt_x:   u32,
	tilt_y:   u32,
}

// One X11 pen / eraser slave device discovered via XIQueryDevice, with its valuator ranges and live contact state.
@(private)
Xi_Pen_Device :: struct {
	id:           u16,
	eraser:       bool,
	pressure_num: i16,
	pressure_min: f64,
	pressure_max: f64,
	tilt_x_num:   i16,
	tilt_y_num:   i16,
	// Live state across events on this device:
	contact:      bool,
	barrel:       bool,
	pressure:     f32,
	tilt:         [2]f32, // turns, as Pointer_Info.tilt
}

// Decoded fields of an XI2 ButtonPress, ButtonRelease, or Motion generic event.
@(private)
Xi_Event_Decoded :: struct {
	event_type:     u16,
	deviceid:       u16,
	sourceid:       u16,
	time:           u32,
	detail:         u32,
	event_window:   u32,
	mods_effective: u32,
	root_x, root_y: f32,
	event_x, event_y: f32,
	has_pressure:   bool,
	pressure_raw:   f64,
	has_tilt_x:     bool,
	tilt_x_raw:     f64,
	has_tilt_y:     bool,
	tilt_y_raw:     f64,
}

@(private)
xi_fp3232_to_f64 :: proc(v: Xi_Fp3232) -> f64 {
	return f64(v.integral) + f64(v.frac) / 4294967296.0
}

@(private)
xi_fp1616_to_f32 :: proc(v: i32) -> f32 {
	return f32(f64(v) / 65536.0)
}

@(private = "file")
xi_u16 :: proc(b: []u8, off: int) -> u16 {
	v, _ := endian.get_u16(b[off:off + 2], .Little)
	return v
}

@(private = "file")
xi_u32 :: proc(b: []u8, off: int) -> u32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return v
}

@(private = "file")
xi_i32 :: proc(b: []u8, off: int) -> i32 {
	v, _ := endian.get_i32(b[off:off + 4], .Little)
	return v
}

@(private = "file")
xi_fp3232 :: proc(b: []u8, off: int) -> f64 {
	return xi_fp3232_to_f64({integral = xi_i32(b, off), frac = xi_u32(b, off + 4)})
}

@(private = "file")
xi_name_has :: proc(name, sub: string) -> bool {
	lower := ascii.lower(name, context.temp_allocator)
	return strings.contains(lower, sub)
}

// Parses a raw xcb_input_xi_query_device_reply_t buffer and returns all enabled pen/eraser devices.
@(private)
xi_parse_devices :: proc(reply: []u8, atoms: Xi_Atoms, allocator := context.allocator) -> []Xi_Pen_Device {
	if len(reply) < 32 || atoms.pressure == 0 { return nil }
	num_infos := int(xi_u16(reply, 8))
	if num_infos == 0 { return nil }
	out := make([dynamic]Xi_Pen_Device, 0, 4, allocator)
	pos := 32
	for _ in 0 ..< num_infos {
		if pos + 12 > len(reply) { break }
		dev_id := xi_u16(reply, pos)
		dev_type := xi_u16(reply, pos + 2)
		num_classes := int(xi_u16(reply, pos + 6))
		name_len := int(xi_u16(reply, pos + 8))
		enabled := reply[pos + 10] != 0
		pos += 12
		name_padded := ((name_len + 3) / 4) * 4
		if pos + name_padded > len(reply) { break }
		name := string(reply[pos:pos + name_len])
		pos += name_padded

		has_touch := false
		pen := Xi_Pen_Device{
			id           = dev_id,
			eraser       = xi_name_has(name, "eraser"),
			pressure_num = -1,
			tilt_x_num   = -1,
			tilt_y_num   = -1,
		}
		valid := true
		for _ in 0 ..< num_classes {
			if pos + 4 > len(reply) { valid = false; break }
			ctype := xi_u16(reply, pos)
			clen_words := int(xi_u16(reply, pos + 2))
			if clen_words < 1 { valid = false; break }
			clen := clen_words * 4
			if pos + clen > len(reply) { valid = false; break }
			if ctype == XI_CLASS_TOUCH {
				has_touch = true
			} else if ctype == XI_CLASS_VALUATOR && clen >= 44 {
				num := i16(xi_u16(reply, pos + 6))
				label := xi_u32(reply, pos + 8)
				min_v := xi_fp3232(reply, pos + 12)
				max_v := xi_fp3232(reply, pos + 20)
				if label == atoms.pressure && max_v > min_v {
					pen.pressure_num = num
					pen.pressure_min = min_v
					pen.pressure_max = max_v
				} else if atoms.tilt_x != 0 && label == atoms.tilt_x {
					pen.tilt_x_num = num
				} else if atoms.tilt_y != 0 && label == atoms.tilt_y {
					pen.tilt_y_num = num
				}
			}
			pos += clen
		}
		if !valid { break }
		is_slave := dev_type == XI_DEVICE_SLAVE_POINTER || dev_type == XI_DEVICE_FLOATING_SLAVE
		is_pad := xi_name_has(name, "touchpad") || xi_name_has(name, "trackpad")
		if enabled && is_slave && !has_touch && !is_pad && pen.pressure_num >= 0 {
			append(&out, pen)
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// Decodes an XI2 ButtonPress, ButtonRelease, or Motion generic event (84-byte header + masks + FP3232 valuators).
// When `pen` is non-nil, extracts pressure and tilt valuators matching `pen`'s valuator numbers.
@(private)
xi_decode_device_event :: proc(buf: []u8, pen: ^Xi_Pen_Device) -> (ev: Xi_Event_Decoded, ok: bool) {
	if len(buf) < XI_DEVICE_EVENT_HEADER_BYTES { return {}, false }
	ev_type := xi_u16(buf, 8)
	if ev_type != XI_EVENT_BUTTON_PRESS && ev_type != XI_EVENT_BUTTON_RELEASE && ev_type != XI_EVENT_MOTION {
		return {}, false
	}
	buttons_len := int(xi_u16(buf, 52))
	valuators_len := int(xi_u16(buf, 54))
	mask_off := XI_DEVICE_EVENT_HEADER_BYTES + buttons_len * 4
	vals_off := mask_off + valuators_len * 4
	if vals_off > len(buf) { return {}, false }

	ev = {
		event_type     = ev_type,
		deviceid       = xi_u16(buf, 10),
		time           = xi_u32(buf, 12),
		detail         = xi_u32(buf, 16),
		event_window   = xi_u32(buf, 24),
		root_x         = xi_fp1616_to_f32(xi_i32(buf, 36)),
		root_y         = xi_fp1616_to_f32(xi_i32(buf, 40)),
		event_x        = xi_fp1616_to_f32(xi_i32(buf, 44)),
		event_y        = xi_fp1616_to_f32(xi_i32(buf, 48)),
		sourceid       = xi_u16(buf, 56),
		mods_effective = xi_u32(buf, 76),
	}
	if pen == nil || valuators_len == 0 { return ev, true }

	mask := buf[mask_off:vals_off]
	val_pos := vals_off
	for bit := 0; bit < len(mask) * 8; bit += 1 {
		if (mask[bit >> 3] & (u8(1) << u8(bit & 7))) == 0 { continue }
		if val_pos + 8 > len(buf) { break }
		v := xi_fp3232(buf, val_pos)
		val_pos += 8
		if i16(bit) == pen.pressure_num {
			ev.has_pressure = true
			ev.pressure_raw = v
		} else if i16(bit) == pen.tilt_x_num {
			ev.has_tilt_x = true
			ev.tilt_x_raw = v
		} else if i16(bit) == pen.tilt_y_num {
			ev.has_tilt_y = true
			ev.tilt_y_raw = v
		}
	}
	return ev, true
}

// Updates `pen`'s live contact, barrel, pressure, and tilt from `ev` and builds the Pointer_Info for the event.
@(private)
xi_pen_apply :: proc(pen: ^Xi_Pen_Device, ev: Xi_Event_Decoded) -> Pointer_Info {
	if ev.has_pressure && pen.pressure_max > pen.pressure_min {
		norm := (ev.pressure_raw - pen.pressure_min) / (pen.pressure_max - pen.pressure_min)
		pen.pressure = f32(clamp(norm, 0, 1))
	}
	if ev.has_tilt_x { pen.tilt.x = f32(turn.from_degrees(ev.tilt_x_raw)) }
	if ev.has_tilt_y { pen.tilt.y = f32(turn.from_degrees(ev.tilt_y_raw)) }
	if ev.event_type == XI_EVENT_BUTTON_PRESS {
		if ev.detail == 1 { pen.contact = true }
		if ev.detail == 2 || ev.detail == 3 { pen.barrel = true }
	} else if ev.event_type == XI_EVENT_BUTTON_RELEASE {
		if ev.detail == 1 { pen.contact = false }
		if ev.detail == 2 || ev.detail == 3 { pen.barrel = false }
	}
	// (the mouse is 1 in Pointer_Info.id: X11 pen ids are offset past 1)
	return Pointer_Info{
		id       = 1 + u32(pen.id),
		kind     = .Pen,
		primary  = true,
		pressure = pointer_pressure(pen.pressure, pen.contact),
		measured = true,
		tilt     = pen.tilt,
		barrel   = pen.barrel,
		eraser   = pen.eraser,
	}
}
