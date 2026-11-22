#+build linux
package platform

// XInput 2 pen pressure on X11 (src/md/features/pen-input.md): optional dlopen of libxcb-xinput.so.0.
// Watches XI_HierarchyChanged on the root window for hot-plug, and selects XI2 pointer events on windows only while at
// least one pen device is present so regular mice without a tablet stay on untouched core X11 events.

import "base:runtime"
import "core:encoding/endian"

@(private = "file")
Xinput_Lib :: struct {
	id:                  rawptr,
	query_version:       proc "c" (c: Xcb_Connection, major, minor: u16) -> Xcb_Intern_Atom_Cookie,
	query_version_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Intern_Atom_Cookie, e: rawptr) -> rawptr,
	query_device:        proc "c" (c: Xcb_Connection, deviceid: u16) -> Xcb_Intern_Atom_Cookie,
	query_device_reply:  proc "c" (c: Xcb_Connection, cookie: Xcb_Intern_Atom_Cookie, e: rawptr) -> rawptr,
	select_events:       proc "c" (c: Xcb_Connection, window: Xcb_Window, num_mask: u16, masks: rawptr) -> Xcb_Void_Cookie,
}
// (of this thread: with its connection, x11c)
@(private = "file", thread_local) xi: Xinput_Lib

@(private = "file")
Xi_Select_Mask :: struct #packed {
	deviceid: u16,
	mask_len: u16, // in 4-byte units (1)
	mask:     u32,
}
#assert(size_of(Xi_Select_Mask) == 8)

@(private)
x11_xi_init :: proc() {
	h := lib_open({"libxcb-xinput.so.0", "libxcb-xinput.so"})
	if h == nil { return }
	xi.id                  = lib_sym(h, "xcb_input_id")
	xi.query_version       = auto_cast lib_sym(h, "xcb_input_xi_query_version")
	xi.query_version_reply = auto_cast lib_sym(h, "xcb_input_xi_query_version_reply")
	xi.query_device        = auto_cast lib_sym(h, "xcb_input_xi_query_device")
	xi.query_device_reply  = auto_cast lib_sym(h, "xcb_input_xi_query_device_reply")
	xi.select_events       = auto_cast lib_sym(h, "xcb_input_xi_select_events")
	if xi.id == nil || xi.query_version == nil || xi.query_version_reply == nil || xi.query_device == nil || xi.query_device_reply == nil || xi.select_events == nil {
		return
	}
	op := x11_extension_opcode(xi.id)
	if op == 0 { return }
	reply := xi.query_version_reply(x11c.c, xi.query_version(x11c.c, 2, 0), nil)
	if reply == nil { return }
	free_c(reply)
	x11c.xi_opcode = op
	x11c.xi_atoms = {
		pressure = u32(x11_atom("Abs Pressure")),
		tilt_x   = u32(x11_atom("Abs Tilt X")),
		tilt_y   = u32(x11_atom("Abs Tilt Y")),
	}
	x11_xi_refresh_devices()
	// Watch device hot-plug on the root window even when no pen is attached at startup.
	if x11c.screen != nil {
		root_mask := Xi_Select_Mask{deviceid = XI_ALL_DEVICES, mask_len = 1, mask = XI_MASK_HIERARCHY}
		xi.select_events(x11c.c, x11c.screen.root, 1, &root_mask)
	}
}

@(private = "file")
x11_xi_refresh_devices :: proc() {
	if x11c.xi_opcode == 0 || xi.query_device == nil || xi.query_device_reply == nil { return }
	reply := xi.query_device_reply(x11c.c, xi.query_device(x11c.c, XI_ALL_DEVICES), nil)
	if reply == nil { return }
	defer free_c(reply)
	hdr := ([^]u8)(reply)
	len_words, _ := endian.get_u32(hdr[4:8], .Little)
	total := 32 + int(len_words) * 4
	fresh := xi_parse_devices(hdr[:total], x11c.xi_atoms, runtime.heap_allocator())
	delete(x11c.xi_pens, runtime.heap_allocator())
	x11c.xi_pens = fresh
}

// Selects XI2 pointer events on `id` when at least one pen device is attached; clears the mask otherwise so core X11
// pointer delivery runs untouched.
@(private)
x11_xi_select :: proc(id: Xcb_Window) {
	if x11c.xi_opcode == 0 || xi.select_events == nil { return }
	if len(x11c.xi_pens) == 0 && !x11c.xi_selected { return }
	mask_bits: u32 = len(x11c.xi_pens) > 0 ? (XI_MASK_BUTTON_PRESS | XI_MASK_BUTTON_RELEASE | XI_MASK_MOTION | XI_MASK_LEAVE) : 0
	m := Xi_Select_Mask{deviceid = XI_ALL_MASTER_DEVICES, mask_len = 1, mask = mask_bits}
	xi.select_events(x11c.c, id, 1, &m)
	x11c.xi_selected = len(x11c.xi_pens) > 0
}

@(private = "file")
x11_xi_find_pen :: proc(sourceid: u16) -> ^Xi_Pen_Device {
	for &p in x11c.xi_pens {
		if p.id == sourceid { return &p }
	}
	return nil
}

@(private = "file")
x11_xi_window :: proc(id: Xcb_Window) -> ^Window {
	for w in x11c.windows {
		if x11_state(w).id == id { return w }
	}
	return nil
}

// Handles an XCB_GE_GENERIC event belonging to XInput 2. Returns true when consumed.
@(private)
x11_xi_event :: proc(raw: ^Xcb_Generic_Event) -> bool {
	if x11c.xi_opcode == 0 { return false }
	b := ([^]u8)(raw)
	if b[1] != x11c.xi_opcode { return false }
	ev_type, _ := endian.get_u16(b[8:10], .Little)
	if ev_type == XI_EVENT_HIERARCHY {
		had := len(x11c.xi_pens) > 0
		x11_xi_refresh_devices()
		has := len(x11c.xi_pens) > 0
		if had != has {
			for w in x11c.windows { x11_xi_select(x11_state(w).id) }
			xcb.flush(x11c.c)
		}
		return true
	}
	if ev_type == XI_EVENT_LEAVE {
		win_id, _ := endian.get_u32(b[24:28], .Little)
		w := x11_xi_window(Xcb_Window(win_id))
		if w == nil { return true }
		for &p in x11c.xi_pens {
			if p.contact {
				p.contact = false
				pi := Pointer_Info{id = 1 + u32(p.id), kind = .Pen, primary = true, measured = true, tilt = p.tilt, barrel = p.barrel, eraser = p.eraser}
				x11_push(w, {kind = .Pointer_Cancel, pointer = pi})
				if button_changes(w, .Left, false) {
					x11_push(w, {kind = .Mouse_Release, button = .Left, emulated = true, pointer = pi, buttons = w.buttons_down, lost = true})
				}
			}
		}
		if w.buttons_down == {} { x11_push(w, {kind = .Mouse_Leave}) }
		return true
	}
	len_words, _ := endian.get_u32(b[4:8], .Little)
	total := 32 + int(len_words) * 4
	if total < XI_DEVICE_EVENT_HEADER_BYTES { return true }
	sourceid, _ := endian.get_u16(b[56:58], .Little)
	pen := x11_xi_find_pen(sourceid)
	ev, ok := xi_decode_device_event(b[:total], pen)
	if !ok { return true }
	w := x11_xi_window(Xcb_Window(ev.event_window))
	if w == nil { return true }

	pos := [2]f32{ev.event_x, ev.event_y}
	mods := x11_mods(u16(ev.mods_effective))
	root := [2]i16{i16(ev.root_x), i16(ev.root_y)}

	if pen != nil {
		pi := xi_pen_apply(pen, ev)
		switch ev.event_type {
		case XI_EVENT_MOTION:
			frame_hover_at(w, pos)
			x11_push(w, {kind = .Pointer_Move, pos = pos, mods = mods, pointer = pi})
			x11_push(w, {kind = .Mouse_Move, pos = pos, mods = mods, buttons = w.buttons_down, emulated = true, pointer = pi})
		case XI_EVENT_BUTTON_PRESS, XI_EVENT_BUTTON_RELEASE:
			press := ev.event_type == XI_EVENT_BUTTON_PRESS
			if ev.detail == 1 {
				if press && w.overlay { x11_overlay_focus(w, ev.time) }
				x11_push(w, {kind = press ? .Pointer_Down : .Pointer_Up, pos = pos, mods = mods, pointer = pi})
				if press && x11_frame_press(w, .Left, pos, root, ev.time) {
					x11_push(w, {kind = .Frame_Press, button = .Left, pos = pos, mods = mods, buttons = w.buttons_down})
				} else if button_changes(w, .Left, press) {
					x11_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = .Left, pos = pos, mods = mods, buttons = w.buttons_down, emulated = true, pointer = pi})
				}
			} else {
				x11_push(w, {kind = .Pointer_Move, pos = pos, mods = mods, pointer = pi})
			}
		}
		return true
	}

	// Non-pen device (mouse / touchpad) while XI2 is active on the window: emit standard non-emulated Mouse_* / Scroll.
	switch ev.event_type {
	case XI_EVENT_MOTION:
		frame_hover_at(w, pos)
		x11_push(w, {kind = .Mouse_Move, pos = pos, mods = mods, buttons = w.buttons_down})
	case XI_EVENT_BUTTON_PRESS, XI_EVENT_BUTTON_RELEASE:
		press := ev.event_type == XI_EVENT_BUTTON_PRESS
		switch u8(ev.detail) {
		case 1, 2, 3, 8, 9:
			btn: Mouse_Button
			switch u8(ev.detail) {
			case 1: btn = .Left
			case 2: btn = .Middle
			case 3: btn = .Right
			case 8: btn = .Back
			case 9: btn = .Forward
			}
			if press && w.overlay { x11_overlay_focus(w, ev.time) }
			if press && x11_frame_press(w, btn, pos, root, ev.time) {
				x11_push(w, {kind = .Frame_Press, button = btn, pos = pos, mods = mods, buttons = w.buttons_down})
				break
			}
			if button_changes(w, btn, press) {
				x11_push(w, {kind = press ? .Mouse_Press : .Mouse_Release, button = btn, pos = pos, mods = mods, buttons = w.buttons_down})
			}
		case 4, 5, 6, 7:
			if press {
				e := Event{kind = .Scroll, pos = pos, mods = mods}
				switch u8(ev.detail) {
				case 4: e.delta.y = -1
				case 5: e.delta.y = 1
				case 6: e.delta.x = -1
				case 7: e.delta.x = 1
				}
				x11_push(w, e)
			}
		}
	}
	return true
}
