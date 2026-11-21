#+build linux
package platform

// Pens of a tablet on Wayland (tablet-unstable-v2, version 1): the seat's tablet seat announces its tools, and a tool
// over one of our surfaces sends its motion, pressure, tip and buttons, then a frame. Each frame becomes Pointer_*
// events (pointer.odin) and the mouse events the compositor no longer sends: a client that takes the tablet gets the
// pen as a tablet tool only, never as wl_pointer. The facts of a frame are kept and ordered by tablet_tool.odin.
//
// The tablets and pads are announced too: their tables are here so libwayland can make their objects (a pad's group,
// ring, strip), but nothing of them is read. Without wp_cursor_shape_v1 the pen shows the compositor's default cursor.

import "base:runtime"
import turn "../turn"

@(private = "file") TABLET_MANAGER_GET_TABLET_SEAT :: 0
@(private = "file") TABLET_TOOL_SET_CURSOR :: 0
@(private = "file") TABLET_TOOL_DESTROY :: 1
@(private = "file") TABLET_DESTROY :: 0
@(private = "file") TABLET_PAD_DESTROY :: 1
@(private = "file") TABLET_CAPABILITY_PRESSURE :: 2
@(private = "file") BTN_STYLUS :: 0x14b   // the barrel's first button (linux/input-event-codes.h)

@(private) zwp_tablet_manager_iface: Wl_Interface
@(private) zwp_tablet_seat_iface: Wl_Interface
@(private) zwp_tablet_tool_iface: Wl_Interface
@(private) zwp_tablet_iface: Wl_Interface
@(private) zwp_tablet_pad_ring_iface: Wl_Interface
@(private) zwp_tablet_pad_strip_iface: Wl_Interface
@(private) zwp_tablet_pad_group_iface: Wl_Interface
@(private) zwp_tablet_pad_iface: Wl_Interface
@(private = "file") tm_methods: [2]Wl_Message
@(private = "file") ts_methods: [1]Wl_Message
@(private = "file") ts_events: [3]Wl_Message
@(private = "file") tt_methods: [2]Wl_Message
@(private = "file") tt_events: [19]Wl_Message
@(private = "file") tb_methods: [1]Wl_Message
@(private = "file") tb_events: [5]Wl_Message
@(private = "file") ring_methods: [2]Wl_Message
@(private = "file") ring_events: [4]Wl_Message
@(private = "file") strip_methods: [2]Wl_Message
@(private = "file") strip_events: [4]Wl_Message
@(private = "file") group_methods: [1]Wl_Message
@(private = "file") group_events: [6]Wl_Message
@(private = "file") pad_methods: [2]Wl_Message
@(private = "file") pad_events: [8]Wl_Message
@(private = "file") t_tm_get: [2]^Wl_Interface
@(private = "file") t_ts_tablet: [1]^Wl_Interface
@(private = "file") t_ts_tool: [1]^Wl_Interface
@(private = "file") t_ts_pad: [1]^Wl_Interface
@(private = "file") t_tt_cursor: [4]^Wl_Interface
@(private = "file") t_tt_proximity: [3]^Wl_Interface
@(private = "file") t_group_ring: [1]^Wl_Interface
@(private = "file") t_group_strip: [1]^Wl_Interface
@(private = "file") t_pad_group: [1]^Wl_Interface
@(private = "file") t_pad_enter: [3]^Wl_Interface
@(private = "file") t_pad_leave: [2]^Wl_Interface

// The tables of tablet-unstable-v2.xml, version 1 (built once, wayland_lib).
@(private)
tablet_build_tables :: proc() {
	t_tm_get[0], t_tm_get[1] = &zwp_tablet_seat_iface, wl.seat_interface
	tm_methods[0] = {"get_tablet_seat", "no", raw_types(t_tm_get[:])}
	tm_methods[1] = {"destroy", "", nil}
	zwp_tablet_manager_iface = {"zwp_tablet_manager_v2", 1, 2, &tm_methods[0], 0, nil}

	ts_methods[0] = {"destroy", "", nil}
	t_ts_tablet[0], t_ts_tool[0], t_ts_pad[0] = &zwp_tablet_iface, &zwp_tablet_tool_iface, &zwp_tablet_pad_iface
	ts_events[0] = {"tablet_added", "n", raw_types(t_ts_tablet[:])}
	ts_events[1] = {"tool_added", "n", raw_types(t_ts_tool[:])}
	ts_events[2] = {"pad_added", "n", raw_types(t_ts_pad[:])}
	zwp_tablet_seat_iface = {"zwp_tablet_seat_v2", 1, 1, &ts_methods[0], 3, &ts_events[0]}

	t_tt_cursor[1] = wl.surface_interface
	tt_methods[0] = {"set_cursor", "u?oii", raw_types(t_tt_cursor[:])}
	tt_methods[1] = {"destroy", "", nil}
	t_tt_proximity[1], t_tt_proximity[2] = &zwp_tablet_iface, wl.surface_interface
	tt_events[0] = {"type", "u", nil}
	tt_events[1] = {"hardware_serial", "uu", nil}
	tt_events[2] = {"hardware_id_wacom", "uu", nil}
	tt_events[3] = {"capability", "u", nil}
	tt_events[4] = {"done", "", nil}
	tt_events[5] = {"removed", "", nil}
	tt_events[6] = {"proximity_in", "uoo", raw_types(t_tt_proximity[:])}
	tt_events[7] = {"proximity_out", "", nil}
	tt_events[8] = {"down", "u", nil}
	tt_events[9] = {"up", "", nil}
	tt_events[10] = {"motion", "ff", nil}
	tt_events[11] = {"pressure", "u", nil}
	tt_events[12] = {"distance", "u", nil}
	tt_events[13] = {"tilt", "ff", nil}
	tt_events[14] = {"rotation", "f", nil}
	tt_events[15] = {"slider", "i", nil}
	tt_events[16] = {"wheel", "fi", nil}
	tt_events[17] = {"button", "uuu", nil}
	tt_events[18] = {"frame", "u", nil}
	zwp_tablet_tool_iface = {"zwp_tablet_tool_v2", 1, 2, &tt_methods[0], 19, &tt_events[0]}

	tb_methods[0] = {"destroy", "", nil}
	tb_events[0] = {"name", "s", nil}
	tb_events[1] = {"id", "uu", nil}
	tb_events[2] = {"path", "s", nil}
	tb_events[3] = {"done", "", nil}
	tb_events[4] = {"removed", "", nil}
	zwp_tablet_iface = {"zwp_tablet_v2", 1, 1, &tb_methods[0], 5, &tb_events[0]}

	ring_methods[0] = {"set_feedback", "su", nil}
	ring_methods[1] = {"destroy", "", nil}
	ring_events[0] = {"source", "u", nil}
	ring_events[1] = {"angle", "f", nil}
	ring_events[2] = {"stop", "", nil}
	ring_events[3] = {"frame", "u", nil}
	zwp_tablet_pad_ring_iface = {"zwp_tablet_pad_ring_v2", 1, 2, &ring_methods[0], 4, &ring_events[0]}

	strip_methods[0] = {"set_feedback", "su", nil}
	strip_methods[1] = {"destroy", "", nil}
	strip_events[0] = {"source", "u", nil}
	strip_events[1] = {"position", "u", nil}
	strip_events[2] = {"stop", "", nil}
	strip_events[3] = {"frame", "u", nil}
	zwp_tablet_pad_strip_iface = {"zwp_tablet_pad_strip_v2", 1, 2, &strip_methods[0], 4, &strip_events[0]}

	group_methods[0] = {"destroy", "", nil}
	t_group_ring[0], t_group_strip[0] = &zwp_tablet_pad_ring_iface, &zwp_tablet_pad_strip_iface
	group_events[0] = {"buttons", "a", nil}
	group_events[1] = {"ring", "n", raw_types(t_group_ring[:])}
	group_events[2] = {"strip", "n", raw_types(t_group_strip[:])}
	group_events[3] = {"modes", "u", nil}
	group_events[4] = {"done", "", nil}
	group_events[5] = {"mode_switch", "uuu", nil}
	zwp_tablet_pad_group_iface = {"zwp_tablet_pad_group_v2", 1, 1, &group_methods[0], 6, &group_events[0]}

	pad_methods[0] = {"set_feedback", "usu", nil}
	pad_methods[1] = {"destroy", "", nil}
	t_pad_group[0] = &zwp_tablet_pad_group_iface
	t_pad_enter[1], t_pad_enter[2] = &zwp_tablet_iface, wl.surface_interface
	t_pad_leave[1] = wl.surface_interface
	pad_events[0] = {"group", "n", raw_types(t_pad_group[:])}
	pad_events[1] = {"path", "s", nil}
	pad_events[2] = {"buttons", "u", nil}
	pad_events[3] = {"done", "", nil}
	pad_events[4] = {"button", "uuu", nil}
	pad_events[5] = {"enter", "uoo", raw_types(t_pad_enter[:])}
	pad_events[6] = {"leave", "uo", raw_types(t_pad_leave[:])}
	pad_events[7] = {"removed", "", nil}
	zwp_tablet_pad_iface = {"zwp_tablet_pad_v2", 1, 2, &pad_methods[0], 8, &pad_events[0]}
}

// A tool of the seat: its proxy, the window it is over and the state tablet_tool.odin keeps.
@(private)
Wl_Tablet_Tool :: struct {
	proxy:        Wl_Proxy,
	cursor:       Wl_Proxy,   // its wp_cursor_shape_device_v1 (made at its first proximity)
	window:       ^Window,    // the window it is near (nil: none of ours)
	surface:      Wl_Proxy,   // the surface of its proximity_in: the window's, or the ring of its bands
	serial:       u32,        // its proximity_in's (set_cursor)
	down_serial:  u32,        // its last down's (a move or a resize of the window)
	tool:         Tablet_Tool,
}

// The seat's tablet seat, once the registry gave the manager and the seat (wl_connect_now). A seat with no tablet
// announces nothing: no tool, no event.
@(private)
wl_tablet_seat_make :: proc() {
	if wlc.tablet_manager == nil || wlc.seat == nil { return }
	wlc.tablet_tools.allocator = runtime.heap_allocator()   // (outlives the allocator of whatever made the first window)
	wlc.tablet_seat = wl.proxy_marshal_flags(wlc.tablet_manager, TABLET_MANAGER_GET_TABLET_SEAT, &zwp_tablet_seat_iface,
		wl.proxy_get_version(wlc.tablet_manager), 0, nil, wlc.seat)
	if wlc.tablet_seat != nil { wl.proxy_add_listener(wlc.tablet_seat, &tablet_seat_listener, nil) }
}

// The tools' memory, with the connection (its proxies go with the display).
@(private)
wl_tablet_tools_free :: proc() {
	for t in wlc.tablet_tools { free(t, wlc.tablet_tools.allocator) }
	delete(wlc.tablet_tools)
}

// A window hidden or destroyed: a tool near it is near nothing of ours until its next proximity_in.
@(private)
wl_tablet_forget_window :: proc(w: ^Window) {
	for t in wlc.tablet_tools {
		if t.window != w { continue }
		t.window, t.surface = nil, nil
		t.tool.near, t.tool.contact = false, false
	}
}

// The window's cursor on each tool near it (the pointer's own goes on in wl_apply_cursor).
@(private)
wl_tablet_apply_cursor :: proc(w: ^Window) {
	for t in wlc.tablet_tools {
		if t.window == w && t.tool.near { wl_tablet_cursor(t) }
	}
}

@(private = "file")
wl_tablet_cursor :: proc(t: ^Wl_Tablet_Tool) {
	w := t.window
	if w == nil { return }
	c, band := cursor_shown(w)
	if w.custom_cursor != 0 && !band { c = w.custom_fallback }   // (the custom picture is the pointer's surface's)
	if c == .None {
		wl.proxy_marshal_flags(t.proxy, TABLET_TOOL_SET_CURSOR, nil, wl.proxy_get_version(t.proxy), 0, t.serial, nil, i32(0), i32(0))
		wl.display_flush(wlc.display)
		return
	}
	if wlc.cursor_shape_manager == nil { return }
	if t.cursor == nil {
		t.cursor = wl.proxy_marshal_flags(wlc.cursor_shape_manager, WP_CURSOR_SHAPE_MANAGER_GET_TABLET_TOOL,
			&wp_cursor_shape_device_iface, wl.proxy_get_version(wlc.cursor_shape_manager), 0, nil, t.proxy)
		if t.cursor == nil { return }
	}
	wl.proxy_marshal_flags(t.cursor, WP_CURSOR_SHAPE_DEVICE_SET_SHAPE, nil, wl.proxy_get_version(t.cursor), 0, t.serial, u32(wl_shape_for_cursor(c)))
	wl.display_flush(wlc.display)
}

@(private)
Tablet_Seat_Listener :: struct {
	tablet_added: proc "c" (data: rawptr, seat: Wl_Proxy, tablet: Wl_Proxy),
	tool_added:   proc "c" (data: rawptr, seat: Wl_Proxy, tool: Wl_Proxy),
	pad_added:    proc "c" (data: rawptr, seat: Wl_Proxy, pad: Wl_Proxy),
}
@(private) tablet_seat_listener := Tablet_Seat_Listener{tablet_added, tool_added, pad_added}

@(private = "file")
tablet_added :: proc "c" (data: rawptr, seat: Wl_Proxy, tablet: Wl_Proxy) {
	wl.proxy_add_listener(tablet, &tablet_listener, nil)
}

@(private = "file")
pad_added :: proc "c" (data: rawptr, seat: Wl_Proxy, pad: Wl_Proxy) {
	wl.proxy_add_listener(pad, &pad_listener, nil)
}

@(private = "file")
tool_added :: proc "c" (data: rawptr, seat: Wl_Proxy, proxy: Wl_Proxy) {
	context = wl_ctx_real()
	t := new(Wl_Tablet_Tool, wlc.tablet_tools.allocator)
	wlc.tablet_tool_ids += 1
	// (the mouse is 1 in Pointer_Info.id: the tools come after it)
	t.proxy, t.tool.id = proxy, 1 + wlc.tablet_tool_ids
	append(&wlc.tablet_tools, t)
	wl.proxy_add_listener(proxy, &tablet_tool_listener, t)
}

// A tablet, a pad: only their removal is read (each says it once it is gone, and the client destroys it). A pad's
// groups, rings and strips have no listener: libwayland drops their events.
@(private)
Tablet_Listener :: struct {
	name:    proc "c" (data: rawptr, p: Wl_Proxy, name: cstring),
	id:      proc "c" (data: rawptr, p: Wl_Proxy, vid, pid: u32),
	path:    proc "c" (data: rawptr, p: Wl_Proxy, path: cstring),
	done:    proc "c" (data: rawptr, p: Wl_Proxy),
	removed: proc "c" (data: rawptr, p: Wl_Proxy),
}
@(private) tablet_listener := Tablet_Listener{
	proc "c" (data: rawptr, p: Wl_Proxy, name: cstring) {},
	proc "c" (data: rawptr, p: Wl_Proxy, vid, pid: u32) {},
	proc "c" (data: rawptr, p: Wl_Proxy, path: cstring) {},
	proc "c" (data: rawptr, p: Wl_Proxy) {},
	proc "c" (data: rawptr, p: Wl_Proxy) { wl.proxy_marshal_flags(p, TABLET_DESTROY, nil, wl.proxy_get_version(p), WL_MARSHAL_FLAG_DESTROY) },
}

@(private)
Pad_Listener :: struct {
	group:   proc "c" (data: rawptr, p: Wl_Proxy, group: Wl_Proxy),
	path:    proc "c" (data: rawptr, p: Wl_Proxy, path: cstring),
	buttons: proc "c" (data: rawptr, p: Wl_Proxy, buttons: u32),
	done:    proc "c" (data: rawptr, p: Wl_Proxy),
	button:  proc "c" (data: rawptr, p: Wl_Proxy, time, button, state: u32),
	enter:   proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, tablet, surface: Wl_Proxy),
	leave:   proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy),
	removed: proc "c" (data: rawptr, p: Wl_Proxy),
}
@(private) pad_listener := Pad_Listener{
	proc "c" (data: rawptr, p: Wl_Proxy, group: Wl_Proxy) {},
	proc "c" (data: rawptr, p: Wl_Proxy, path: cstring) {},
	proc "c" (data: rawptr, p: Wl_Proxy, buttons: u32) {},
	proc "c" (data: rawptr, p: Wl_Proxy) {},
	proc "c" (data: rawptr, p: Wl_Proxy, time, button, state: u32) {},
	proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, tablet, surface: Wl_Proxy) {},
	proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, surface: Wl_Proxy) {},
	proc "c" (data: rawptr, p: Wl_Proxy) { wl.proxy_marshal_flags(p, TABLET_PAD_DESTROY, nil, wl.proxy_get_version(p), WL_MARSHAL_FLAG_DESTROY) },
}

@(private)
Tablet_Tool_Listener :: struct {
	type:              proc "c" (data: rawptr, p: Wl_Proxy, kind: u32),
	hardware_serial:   proc "c" (data: rawptr, p: Wl_Proxy, hi, lo: u32),
	hardware_id_wacom: proc "c" (data: rawptr, p: Wl_Proxy, hi, lo: u32),
	capability:        proc "c" (data: rawptr, p: Wl_Proxy, capability: u32),
	done:              proc "c" (data: rawptr, p: Wl_Proxy),
	removed:           proc "c" (data: rawptr, p: Wl_Proxy),
	proximity_in:      proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, tablet, surface: Wl_Proxy),
	proximity_out:     proc "c" (data: rawptr, p: Wl_Proxy),
	down:              proc "c" (data: rawptr, p: Wl_Proxy, serial: u32),
	up:                proc "c" (data: rawptr, p: Wl_Proxy),
	motion:            proc "c" (data: rawptr, p: Wl_Proxy, x, y: Wl_Fixed),
	pressure:          proc "c" (data: rawptr, p: Wl_Proxy, pressure: u32),
	distance:          proc "c" (data: rawptr, p: Wl_Proxy, distance: u32),
	tilt:              proc "c" (data: rawptr, p: Wl_Proxy, x, y: Wl_Fixed),
	rotation:          proc "c" (data: rawptr, p: Wl_Proxy, degrees: Wl_Fixed),
	slider:            proc "c" (data: rawptr, p: Wl_Proxy, position: i32),
	wheel:             proc "c" (data: rawptr, p: Wl_Proxy, degrees: Wl_Fixed, clicks: i32),
	button:            proc "c" (data: rawptr, p: Wl_Proxy, serial, button, state: u32),
	frame:             proc "c" (data: rawptr, p: Wl_Proxy, time: u32),
}
@(private) tablet_tool_listener := Tablet_Tool_Listener{
	type = proc "c" (data: rawptr, p: Wl_Proxy, kind: u32) { (^Wl_Tablet_Tool)(data).tool.tool_type = kind },
	hardware_serial = proc "c" (data: rawptr, p: Wl_Proxy, hi, lo: u32) {},
	hardware_id_wacom = proc "c" (data: rawptr, p: Wl_Proxy, hi, lo: u32) {},
	capability = proc "c" (data: rawptr, p: Wl_Proxy, capability: u32) {
		if capability == TABLET_CAPABILITY_PRESSURE { (^Wl_Tablet_Tool)(data).tool.measures = true }
	},
	done = proc "c" (data: rawptr, p: Wl_Proxy) {},
	removed = tool_removed,
	proximity_in = tool_proximity_in,
	proximity_out = proc "c" (data: rawptr, p: Wl_Proxy) { (^Wl_Tablet_Tool)(data).tool.went_out = true },
	down = proc "c" (data: rawptr, p: Wl_Proxy, serial: u32) {
		t := (^Wl_Tablet_Tool)(data)
		t.tool.went_down, t.down_serial = true, serial
	},
	up = proc "c" (data: rawptr, p: Wl_Proxy) { (^Wl_Tablet_Tool)(data).tool.went_up = true },
	motion = tool_motion,
	pressure = proc "c" (data: rawptr, p: Wl_Proxy, pressure: u32) { (^Wl_Tablet_Tool)(data).tool.pressure = pressure },
	distance = proc "c" (data: rawptr, p: Wl_Proxy, distance: u32) {},
	tilt = proc "c" (data: rawptr, p: Wl_Proxy, x, y: Wl_Fixed) {
		// (the protocol's angles are degrees: turns from here on)
		(^Wl_Tablet_Tool)(data).tool.tilt = {f32(turn.from_degrees(wl_fixed_to_f64(x))), f32(turn.from_degrees(wl_fixed_to_f64(y)))}
	},
	rotation = proc "c" (data: rawptr, p: Wl_Proxy, degrees: Wl_Fixed) {
		(^Wl_Tablet_Tool)(data).tool.twist = f32(turn.from_degrees(wl_fixed_to_f64(degrees)))
	},
	slider = proc "c" (data: rawptr, p: Wl_Proxy, position: i32) {},
	wheel = proc "c" (data: rawptr, p: Wl_Proxy, degrees: Wl_Fixed, clicks: i32) {},
	button = proc "c" (data: rawptr, p: Wl_Proxy, serial, button, state: u32) {
		if button == BTN_STYLUS { (^Wl_Tablet_Tool)(data).tool.barrel = state == 1 }
	},
	frame = tool_frame,
}

@(private = "file")
tool_proximity_in :: proc "c" (data: rawptr, p: Wl_Proxy, serial: u32, tablet, surface: Wl_Proxy) {
	t := (^Wl_Tablet_Tool)(data)
	t.window, t.surface, t.serial = window_of_surface(surface), surface, serial
	if t.window != nil { t.tool.came = true }
}

@(private = "file")
tool_motion :: proc "c" (data: rawptr, p: Wl_Proxy, x, y: Wl_Fixed) {
	context = wl_ctx_real()
	t := (^Wl_Tablet_Tool)(data)
	if t.window == nil { return }
	t.tool.pos = wl_pointer_point(t.window, t.surface, x, y)
	t.tool.moved = true
}

@(private = "file")
tool_removed :: proc "c" (data: rawptr, p: Wl_Proxy) {
	context = wl_ctx_real()
	t := (^Wl_Tablet_Tool)(data)
	// (a tool unplugged in proximity: what it held ends as if it left)
	t.tool.went_out = true
	tool_frame(data, p, 0)
	if t.cursor != nil { wl.proxy_marshal_flags(t.cursor, WP_CURSOR_SHAPE_DEVICE_DESTROY, nil, wl.proxy_get_version(t.cursor), WL_MARSHAL_FLAG_DESTROY) }
	wl.proxy_marshal_flags(t.proxy, TABLET_TOOL_DESTROY, nil, wl.proxy_get_version(t.proxy), WL_MARSHAL_FLAG_DESTROY)
	for x, i in wlc.tablet_tools { if x == t { ordered_remove(&wlc.tablet_tools, i); break } }
	free(t, wlc.tablet_tools.allocator)
}

// The frame: the steps of tablet_tool.odin as events, the pen's own and the mouse's emulation of it.
@(private = "file")
tool_frame :: proc "c" (data: rawptr, p: Wl_Proxy, time_ms: u32) {
	context = wl_ctx_real()
	t := (^Wl_Tablet_Tool)(data)
	came := t.tool.came
	steps, n := tablet_tool_frame(&t.tool)
	w := t.window
	if w == nil { return }
	if came { w.frame_hover = frame_hit(w, t.tool.pos); wl_tablet_cursor(t) }
	pos, mods := t.tool.pos, wl_mods()
	for s in steps[:n] {
		pi := tablet_tool_info(t.tool)
		pointer := Event{pos = pos, mods = mods, pointer = pi}
		mouse := Event{pos = pos, mods = mods, emulated = true, pointer = pi, button = .Left}
		switch s {
		case .Move:
			frame_hover_at(w, pos)
			pointer.kind = .Pointer_Move
			wl_push(w, pointer)
			mouse.kind, mouse.buttons = .Mouse_Move, w.buttons_down
			wl_push(w, mouse)
		case .Down:
			pointer.kind = .Pointer_Down
			wl_push(w, pointer)
			if wl_frame_press(w, .Left, pos, t.down_serial, time_ms) {
				wl_push(w, {kind = .Frame_Press, button = .Left, pos = pos, mods = mods, buttons = w.buttons_down})
			} else if button_changes(w, .Left, true) {
				mouse.kind, mouse.buttons = .Mouse_Press, w.buttons_down
				wl_push(w, mouse)
			}
		case .Up:
			pointer.kind = .Pointer_Up
			wl_push(w, pointer)
			if button_changes(w, .Left, false) {
				mouse.kind, mouse.buttons = .Mouse_Release, w.buttons_down
				wl_push(w, mouse)
			}
		case .Cancel:
			pointer.kind = .Pointer_Cancel
			wl_push(w, pointer)
			if button_changes(w, .Left, false) {
				mouse.kind, mouse.buttons, mouse.lost = .Mouse_Release, w.buttons_down, true
				wl_push(w, mouse)
			}
		case .Leave:
			// (the mouse may still be over the window: it keeps its hover)
			if wlc.pointer_focus != w { wl_push(w, {kind = .Mouse_Leave, emulated = true, pointer = pi}) }
			t.window, t.surface = nil, nil
		}
	}
}
