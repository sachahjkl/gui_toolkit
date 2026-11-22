#+build linux
package platform

import "core:sys/posix"

// The X extensions the X11 backend asks of the server, by dlopen as the rest (each its own library, each optional):
// XFIXES tells when any program takes the clipboard (and cuts a window out of the pointer's way, for a drag image); RandR
// gives the refresh rate of the monitor a window is on; Present says when each picture reached the screen (Vblank_Timing).
// Without them: no change signal between two other programs, DISPLAY_FALLBACK_HZ, no vblank timing. XTEST turns the wheel as the user would (send_wheel), loaded on its first use only: most programs
// never send input.

@(private = "file") XFIXES_VERSION_MAJOR :: 5
@(private = "file") XFIXES_SELECTION_EVENT_MASK_SET_OWNER :: 1
@(private = "file") XFIXES_SHAPE_KIND_INPUT :: 2
@(private = "file") RANDR_VERSION_MINOR :: 3                  // get_screen_resources_current
@(private = "file") RANDR_NOTIFY_MASK_SCREEN_CHANGE :: 1
@(private = "file") RANDR_MODE_FLAG_INTERLACE :: 1 << 4
@(private = "file") RANDR_MODE_FLAG_DOUBLE_SCAN :: 1 << 5

@(private = "file") Xcb_Cookie :: Xcb_Intern_Atom_Cookie

// xcb_query_extension_reply_t, of which only these are read.
@(private = "file") Xcb_Extension_Reply :: struct { response_type, pad0: u8, sequence: u16, length: u32, present, major_opcode, first_event, first_error: u8 }

@(private = "file")
Xfixes_Lib :: struct {
	id:                  rawptr,   // xcb_xfixes_id
	query_version:       proc "c" (c: Xcb_Connection, major, minor: u32) -> Xcb_Cookie,
	query_version_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	select_selection:    proc "c" (c: Xcb_Connection, window: Xcb_Window, selection: Xcb_Atom, mask: u32) -> Xcb_Void_Cookie,
	create_region:       proc "c" (c: Xcb_Connection, region: u32, n: u32, rects: rawptr) -> Xcb_Void_Cookie,
	destroy_region:      proc "c" (c: Xcb_Connection, region: u32) -> Xcb_Void_Cookie,
	set_shape_region:    proc "c" (c: Xcb_Connection, dest: Xcb_Window, kind: u8, x, y: i16, region: u32) -> Xcb_Void_Cookie,
	cursor_image:        proc "c" (c: Xcb_Connection) -> Xcb_Cookie,
	cursor_image_reply:  proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
}
// (of this thread: with its connection, x11c)
@(private = "file", thread_local) xfixes: Xfixes_Lib

// xcb_randr_mode_info_t
@(private = "file")
Randr_Mode :: struct {
	id: u32, width, height: u16, dot_clock: u32,
	hsync_start, hsync_end, htotal, hskew, vsync_start, vsync_end, vtotal, name_len: u16,
	flags: u32,
}
#assert(size_of(Randr_Mode) == 32)

@(private = "file")
Randr_Lib :: struct {
	id:                  rawptr,   // xcb_randr_id
	query_version:       proc "c" (c: Xcb_Connection, major, minor: u32) -> Xcb_Cookie,
	query_version_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	select_input:        proc "c" (c: Xcb_Connection, window: Xcb_Window, mask: u16) -> Xcb_Void_Cookie,
	resources:           proc "c" (c: Xcb_Connection, window: Xcb_Window) -> Xcb_Cookie,
	resources_reply:     proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	res_crtcs:           proc "c" (r: rawptr) -> [^]u32,
	res_crtcs_len:       proc "c" (r: rawptr) -> i32,
	res_modes:           proc "c" (r: rawptr) -> [^]Randr_Mode,
	res_modes_len:       proc "c" (r: rawptr) -> i32,
	crtc_info:           proc "c" (c: Xcb_Connection, crtc: u32, config_ts: u32) -> Xcb_Cookie,
	crtc_info_reply:     proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	crtc_outputs:        proc "c" (r: rawptr) -> [^]u32,
	crtc_outputs_len:    proc "c" (r: rawptr) -> i32,
	output_info:         proc "c" (c: Xcb_Connection, output: u32, config_ts: u32) -> Xcb_Cookie,
	output_info_reply:   proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	output_modes:        proc "c" (r: rawptr) -> [^]u32,
	output_modes_len:    proc "c" (r: rawptr) -> i32,
}
// (of this thread: with its connection, x11c)
@(private = "file", thread_local) randr: Randr_Lib

@(private = "file")
Xtest_Lib :: struct {
	tried:      bool,
	ok:         bool,      // the library loaded and the server has the extension
	fake_input: proc "c" (c: Xcb_Connection, type, detail: u8, time: u32, root: Xcb_Window, x, y: i16, device: u8) -> Xcb_Void_Cookie,
}
// (of this thread: with its connection, x11c)
@(private = "file", thread_local) xtest: Xtest_Lib

// Present: when each picture of a window reached the screen (PresentCompleteNotify), the X11 side of Vblank_Timing
// (src/md/infrastructure/vblank.md). Vulkan's WSI presents with it on our own connection and reads its answers under its
// own event id (xcb_register_for_special_xge): the server sends a CompleteNotify to every selection on the window,
// whoever presented (xserver's present_send_complete_notify), so a selection of ours, under an id of ours, gets the WSI's
// pictures too, in the connection's general queue. A software WSI (lavapipe) draws with PutImage, not Present: then
// nothing comes.
@(private = "file")
Present_Lib :: struct {
	id:                  rawptr,   // xcb_present_id
	query_version:       proc "c" (c: Xcb_Connection, major, minor: u32) -> Xcb_Cookie,
	query_version_reply: proc "c" (c: Xcb_Connection, cookie: Xcb_Cookie, e: rawptr) -> rawptr,
	select_input:        proc "c" (c: Xcb_Connection, eid: u32, window: Xcb_Window, mask: u32) -> Xcb_Void_Cookie,
}
// (of this thread: with its connection, x11c)
@(private = "file", thread_local) present: Present_Lib

@(private = "file") PRESENT_EVENT_MASK_COMPLETE_NOTIFY :: 2
@(private = "file") PRESENT_EVENT_COMPLETE_NOTIFY :: 1
@(private = "file") PRESENT_COMPLETE_KIND_PIXMAP :: 0   // (NotifyMSC: an answer to a wait for a refresh, no picture)
@(private = "file") PRESENT_COMPLETE_MODE_SKIP :: 2     // (Copy, Flip, SuboptimalCopy: shown)
// An X Generic Event (XGE): Present's events all are.
@(private) XCB_GE_GENERIC :: 35

// xcb_present_complete_notify_event_t (packed): xcb puts the full sequence at byte 32, after the 32 bytes of the wire's
// header, and the rest of the event after it.
@(private = "file")
Present_Complete_Notify :: struct #packed {
	response_type, extension: u8,
	sequence:      u16,
	length:        u32,
	event_type:    u16,
	kind, mode:    u8,
	event:         u32,
	window:        Xcb_Window,
	serial:        u32,
	ust:           u64,   // µs, CLOCK_MONOTONIC
	full_sequence: u32,
	msc:           u64,
}
#assert(size_of(Present_Complete_Notify) == 44)

// The major opcode of an extension (its generic events carry it), 0 when the server does not have it.
@(private)
x11_extension_opcode :: proc(id: rawptr) -> u8 {
	if xcb.get_extension_data == nil || id == nil { return 0 }
	r := (^Xcb_Extension_Reply)(xcb.get_extension_data(x11c.c, id))
	return r != nil && r.present != 0 ? r.major_opcode : 0
}

// Asks for the window's CompleteNotify, under an event id of ours. Nothing without the extension.
@(private)
x11_present_select :: proc(id: Xcb_Window) {
	if x11c.present_opcode == 0 { return }
	present.select_input(x11c.c, xcb.generate_id(x11c.c), id, PRESENT_EVENT_MASK_COMPLETE_NOTIFY)
}

// Whether `raw` is a Present answer, and then what it said of one of our windows (its Vblank_Timing). The answers end no
// wait (x11_wait): they change nothing on the screen.
@(private)
x11_present_event :: proc(raw: ^Xcb_Generic_Event) -> bool {
	if x11c.present_opcode == 0 || (raw.response_type & X11_RESPONSE_TYPE_MASK) != XCB_GE_GENERIC { return false }
	e := (^Present_Complete_Notify)(raw)
	if e.extension != x11c.present_opcode { return false }
	if e.event_type != PRESENT_EVENT_COMPLETE_NOTIFY || e.kind != PRESENT_COMPLETE_KIND_PIXMAP { return true }
	for w in x11c.windows {
		st := x11_state(w)
		if st == nil || st.id != e.window { continue }
		asked: i64
		if st.presents_n > 0 {
			asked = st.presents[0]
			copy(st.presents[:], st.presents[1:])
			st.presents_n -= 1
		}
		if e.mode == PRESENT_COMPLETE_MODE_SKIP {
			vblank_discarded(&st.vblank)
			return true
		}
		// (ust 0: a server with no clock for it, Xvfb's fake screen may say nothing)
		if e.ust == 0 { return true }
		at := clock_to_tick_ns(i64(e.ust) * 1000, CLOCK_ID_MONOTONIC)
		if at == 0 { return true }
		// (the rate read last, RandR's: the first guess when the counter says nothing. Not display_info, which may ask the
		// server and wait for its answer)
		hint := w.display.hz > 0 ? 1e9 / w.display.hz : 0
		vblank_presented(&st.vblank, at, e.msc, 0, hint, asked)
		return true
	}
	return true
}

// The time of a present of the window, for the answer that comes for it (x11_present_event). Nothing without Present.
@(private)
x11_present_note :: proc(st: ^X11_Window_State, at_ns: i64) {
	if x11c.present_opcode == 0 { return }
	if st.presents_n == len(st.presents) {
		copy(st.presents[:], st.presents[1:])
		st.presents_n -= 1
	}
	st.presents[st.presents_n] = at_ns
	st.presents_n += 1
}

// The X buttons of a wheel's notch (as window_x11_linux.odin reads them).
@(private = "file") XTEST_WHEEL_UP :: 4
@(private = "file") XTEST_WHEEL_DOWN :: 5

// A notch is a press and a release of button 4 or 5 on the server's pointer, which the server gives to the window under
// it. False without libxcb-xtest or the extension: a request of an extension the server lacks would close the connection.
@(private)
x11_send_wheel :: proc(notches: int) -> bool {
	if x11c.c == nil { return false }   // (not this thread's window: its connection is another thread's)
	if !xtest.tried {
		xtest.tried = true
		if h := lib_open({"libxcb-xtest.so.0", "libxcb-xtest.so"}); h != nil && xcb.get_extension_data != nil {
			id := lib_sym(h, "xcb_test_id")
			xtest.fake_input = auto_cast lib_sym(h, "xcb_test_fake_input")
			if id != nil && xtest.fake_input != nil {
				r := (^Xcb_Extension_Reply)(xcb.get_extension_data(x11c.c, id))
				xtest.ok = r != nil && r.present != 0
			}
		}
	}
	if !xtest.ok { return false }
	if notches == 0 { return true }
	button := u8(notches > 0 ? XTEST_WHEEL_DOWN : XTEST_WHEEL_UP)
	// (time 0: now; root and position 0: the pointer stays where it is; device 0: the core pointer)
	for _ in 0 ..< abs(notches) {
		xtest.fake_input(x11c.c, XCB_BUTTON_PRESS, button, 0, 0, 0, 0, 0)
		xtest.fake_input(x11c.c, XCB_BUTTON_RELEASE, button, 0, 0, 0, 0, 0)
	}
	xcb.flush(x11c.c)
	return true
}

// The event an extension's id starts at, 0 when the server does not have it.
@(private = "file")
x11_extension_first_event :: proc(id: rawptr) -> u8 {
	if xcb.get_extension_data == nil || id == nil { return 0 }
	r := (^Xcb_Extension_Reply)(xcb.get_extension_data(x11c.c, id))
	return r != nil && r.present != 0 ? r.first_event : 0
}

// Binds the extensions (x11_connect). x11c.xfixes_event / randr_event / present_opcode stay 0 without them.
@(private)
x11_extensions_init :: proc() {
	if h := lib_open({"libxcb-xfixes.so.0", "libxcb-xfixes.so"}); h != nil {
		xfixes.id                  = lib_sym(h, "xcb_xfixes_id")
		xfixes.query_version       = auto_cast lib_sym(h, "xcb_xfixes_query_version")
		xfixes.query_version_reply = auto_cast lib_sym(h, "xcb_xfixes_query_version_reply")
		xfixes.select_selection    = auto_cast lib_sym(h, "xcb_xfixes_select_selection_input")
		xfixes.create_region       = auto_cast lib_sym(h, "xcb_xfixes_create_region")
		xfixes.destroy_region      = auto_cast lib_sym(h, "xcb_xfixes_destroy_region")
		xfixes.set_shape_region    = auto_cast lib_sym(h, "xcb_xfixes_set_window_shape_region")
		xfixes.cursor_image        = auto_cast lib_sym(h, "xcb_xfixes_get_cursor_image")
		xfixes.cursor_image_reply  = auto_cast lib_sym(h, "xcb_xfixes_get_cursor_image_reply")
		if xfixes.query_version != nil && xfixes.query_version_reply != nil && xfixes.select_selection != nil {
			if ev := x11_extension_first_event(xfixes.id); ev != 0 {
				// (the server answers an extension's requests only after this exchange)
				if reply := xfixes.query_version_reply(x11c.c, xfixes.query_version(x11c.c, XFIXES_VERSION_MAJOR, 0), nil); reply != nil {
					free_c(reply)
					x11c.xfixes_event = ev   // XCB_XFIXES_SELECTION_NOTIFY is its first event
				}
			}
		}
	}
	if h := lib_open({"libxcb-randr.so.0", "libxcb-randr.so"}); h != nil {
		randr.id                  = lib_sym(h, "xcb_randr_id")
		randr.query_version       = auto_cast lib_sym(h, "xcb_randr_query_version")
		randr.query_version_reply = auto_cast lib_sym(h, "xcb_randr_query_version_reply")
		randr.select_input        = auto_cast lib_sym(h, "xcb_randr_select_input")
		randr.resources           = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current")
		randr.resources_reply     = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current_reply")
		randr.res_crtcs           = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current_crtcs")
		randr.res_crtcs_len       = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current_crtcs_length")
		randr.res_modes           = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current_modes")
		randr.res_modes_len       = auto_cast lib_sym(h, "xcb_randr_get_screen_resources_current_modes_length")
		randr.crtc_info           = auto_cast lib_sym(h, "xcb_randr_get_crtc_info")
		randr.crtc_info_reply     = auto_cast lib_sym(h, "xcb_randr_get_crtc_info_reply")
		randr.crtc_outputs        = auto_cast lib_sym(h, "xcb_randr_get_crtc_info_outputs")
		randr.crtc_outputs_len    = auto_cast lib_sym(h, "xcb_randr_get_crtc_info_outputs_length")
		randr.output_info         = auto_cast lib_sym(h, "xcb_randr_get_output_info")
		randr.output_info_reply   = auto_cast lib_sym(h, "xcb_randr_get_output_info_reply")
		randr.output_modes        = auto_cast lib_sym(h, "xcb_randr_get_output_info_modes")
		randr.output_modes_len    = auto_cast lib_sym(h, "xcb_randr_get_output_info_modes_length")
		if randr.query_version != nil && randr.query_version_reply != nil && randr.resources != nil && randr.crtc_info != nil && randr.output_info != nil {
			if ev := x11_extension_first_event(randr.id); ev != 0 {
				if reply := randr.query_version_reply(x11c.c, randr.query_version(x11c.c, 1, RANDR_VERSION_MINOR), nil); reply != nil {
					free_c(reply)
					x11c.randr_event = ev   // XCB_RANDR_SCREEN_CHANGE_NOTIFY is its first event
				}
			}
		}
	}
	if h := lib_open({"libxcb-present.so.0", "libxcb-present.so"}); h != nil {
		present.id                  = lib_sym(h, "xcb_present_id")
		present.query_version       = auto_cast lib_sym(h, "xcb_present_query_version")
		present.query_version_reply = auto_cast lib_sym(h, "xcb_present_query_version_reply")
		present.select_input        = auto_cast lib_sym(h, "xcb_present_select_input")
		if present.query_version != nil && present.query_version_reply != nil && present.select_input != nil {
			if op := x11_extension_opcode(present.id); op != 0 {
				// (the server answers an extension's requests only after this exchange)
				if reply := present.query_version_reply(x11c.c, present.query_version(x11c.c, 1, 0), nil); reply != nil {
					free_c(reply)
					x11c.present_opcode = op
				}
			}
		}
	}
	x11_xi_init()
}

// What a new window asks of the extensions: a notice when CLIPBOARD changes hands, when the screen's modes change.
@(private)
x11_extensions_select :: proc(id: Xcb_Window) {
	if x11c.xfixes_event != 0 { xfixes.select_selection(x11c.c, id, x11c.clipboard, XFIXES_SELECTION_EVENT_MASK_SET_OWNER) }
	if x11c.randr_event != 0 && randr.select_input != nil { randr.select_input(x11c.c, id, RANDR_NOTIFY_MASK_SCREEN_CHANGE) }
	x11_present_select(id)
	x11_xi_select(id)
}

// Lets the pointer through a window (a drag's image: the window under it is the target). False without XFIXES.
@(private)
x11_window_input_through :: proc(id: Xcb_Window) -> bool {
	if x11c.xfixes_event == 0 || xfixes.create_region == nil || xfixes.set_shape_region == nil || xfixes.destroy_region == nil { return false }
	region := xcb.generate_id(x11c.c)
	xfixes.create_region(x11c.c, region, 0, nil)
	xfixes.set_shape_region(x11c.c, id, XFIXES_SHAPE_KIND_INPUT, 0, 0, region)
	xfixes.destroy_region(x11c.c, region)
	return true
}

// The refresh rate of a mode's timing, as an exact fraction: pixels per second over pixels per refresh. ok = false when
// the timing says nothing (a virtual screen has no dot clock). Pure. `flags`: RandR's mode flags.
randr_mode_rate :: proc(dot_clock: u32, htotal, vtotal: u16, flags: u32) -> (num, den: u32, ok: bool) {
	if dot_clock == 0 || htotal == 0 || vtotal == 0 { return 0, 1, false }
	n, d := u64(dot_clock), u64(htotal) * u64(vtotal)
	if flags & RANDR_MODE_FLAG_INTERLACE != 0 { n *= 2 }
	if flags & RANDR_MODE_FLAG_DOUBLE_SCAN != 0 { d *= 2 }
	for n > u64(max(u32)) || d > u64(max(u32)) { n /= 2; d /= 2 }
	return u32(n), u32(d), true
}

// A rectangle of a monitor among others: the one holding `p`, -1 when none does. Pure.
randr_monitor_at :: proc(rects: [][4]int, p: [2]int) -> int {
	for r, i in rects {
		if p.x >= r[0] && p.y >= r[1] && p.x < r[0] + r[2] && p.y < r[1] + r[3] { return i }
	}
	return -1
}

// The rate of the monitor under the window's middle (the first monitor lit when it is off every one), and the top rate
// of that monitor's modes at the current size.
@(private)
x11_randr_rate :: proc(w: ^Window) -> (num, den: u32, top_hz: f64, ok: bool) {
	if x11c.randr_event == 0 { return }
	st := x11_state(w)
	if st == nil { return }
	r := randr.resources_reply(x11c.c, randr.resources(x11c.c, st.id), nil)
	if r == nil { return }
	defer free_c(r)
	config_ts := ([^]u32)(r)[3]   // xcb_randr_get_screen_resources_current_reply_t: config_timestamp at [12]
	crtcs := randr.res_crtcs(r)[:randr.res_crtcs_len(r)]
	modes := randr.res_modes(r)[:randr.res_modes_len(r)]

	Lit :: struct { rect: [4]int, mode: u32, output: u32 }
	lit := make([dynamic]Lit, context.temp_allocator)
	rects := make([dynamic][4]int, context.temp_allocator)
	for crtc in crtcs {
		c := randr.crtc_info_reply(x11c.c, randr.crtc_info(x11c.c, crtc, config_ts), nil)
		if c == nil { continue }
		defer free_c(c)
		// xcb_randr_get_crtc_info_reply_t: x at [12], y at [14], width at [16], height at [18], mode at [20]
		b := ([^]u8)(c)
		mode := get_u32(b[20:])
		if mode == 0 { continue }
		rect := [4]int{int(i16(u16(b[12]) | u16(b[13]) << 8)), int(i16(u16(b[14]) | u16(b[15]) << 8)), int(u16(b[16]) | u16(b[17]) << 8), int(u16(b[18]) | u16(b[19]) << 8)}
		output: u32
		if randr.crtc_outputs_len(c) > 0 { output = randr.crtc_outputs(c)[0] }
		append(&lit, Lit{rect, mode, output})
		append(&rects, rect)
	}
	if len(lit) == 0 { return }
	at := 0
	if p, _, got := x11_translate(st.id, x11c.screen.root, w.size.x / 2, w.size.y / 2); got {
		at = max(randr_monitor_at(rects[:], p), 0)
	}
	cur: ^Randr_Mode
	for &m in modes { if m.id == lit[at].mode { cur = &m } }
	if cur == nil { return }
	num, den, ok = randr_mode_rate(cur.dot_clock, cur.htotal, cur.vtotal, cur.flags)
	if !ok { return }
	top_hz = f64(num) / f64(den)
	if lit[at].output == 0 { return }
	o := randr.output_info_reply(x11c.c, randr.output_info(x11c.c, lit[at].output, config_ts), nil)
	if o == nil { return }
	defer free_c(o)
	for id in randr.output_modes(o)[:randr.output_modes_len(o)] {
		for m in modes {
			if m.id != id || m.width != cur.width || m.height != cur.height { continue }
			if n, d, good := randr_mode_rate(m.dot_clock, m.htotal, m.vtotal, m.flags); good { top_hz = max(top_hz, f64(n) / f64(d)) }
		}
	}
	return
}

// The rects of the monitors lit (RandR's CRTCs), in root pixels; empty without RandR. (An overlay's choice of monitor.)
@(private)
x11_monitor_rects :: proc(allocator := context.temp_allocator) -> [][4]int {
	rects := make([dynamic][4]int, allocator)
	if x11c.randr_event == 0 { return rects[:] }
	r := randr.resources_reply(x11c.c, randr.resources(x11c.c, x11c.screen.root), nil)
	if r == nil { return rects[:] }
	defer free_c(r)
	config_ts := ([^]u32)(r)[3]   // (as in x11_randr_rate)
	for crtc in randr.res_crtcs(r)[:randr.res_crtcs_len(r)] {
		c := randr.crtc_info_reply(x11c.c, randr.crtc_info(x11c.c, crtc, config_ts), nil)
		if c == nil { continue }
		defer free_c(c)
		b := ([^]u8)(c)
		if get_u32(b[20:]) == 0 { continue }   // (no mode: off)
		append(&rects, [4]int{int(i16(u16(b[12]) | u16(b[13]) << 8)), int(i16(u16(b[14]) | u16(b[15]) << 8)), int(u16(b[16]) | u16(b[17]) << 8), int(u16(b[18]) | u16(b[19]) << 8)})
	}
	return rects[:]
}

// The pointer reaches the window only through `rects` (window pixels), with XFIXES' region as the SHAPE extension's
// input shape; `limited` false gives it the whole window again. False without XFIXES.
@(private)
x11_window_input_rects :: proc(id: Xcb_Window, rects: [][4]int, limited: bool) -> bool {
	if x11c.xfixes_event == 0 || xfixes.create_region == nil || xfixes.set_shape_region == nil || xfixes.destroy_region == nil { return false }
	if !limited {
		xfixes.set_shape_region(x11c.c, id, XFIXES_SHAPE_KIND_INPUT, 0, 0, 0)   // (region None: the default shape)
		return true
	}
	Xcb_Rectangle :: struct { x, y: i16, width, height: u16 }
	boxes := make([dynamic]Xcb_Rectangle, 0, len(rects), context.temp_allocator)
	for r in rects {
		if r[2] <= 0 || r[3] <= 0 { continue }
		append(&boxes, Xcb_Rectangle{i16(r[0]), i16(r[1]), u16(r[2]), u16(r[3])})
	}
	region := xcb.generate_id(x11c.c)
	xfixes.create_region(x11c.c, region, u32(len(boxes)), raw_data(boxes))
	xfixes.set_shape_region(x11c.c, id, XFIXES_SHAPE_KIND_INPUT, 0, 0, region)
	xfixes.destroy_region(x11c.c, region)
	return true
}

// The server's serial of the pointer image shown now, to tell two cursors apart (cursor_on_screen).
@(private)
x11_pointer_image_serial :: proc() -> (serial: u64, ok: bool) {
	if xfixes.cursor_image == nil || xfixes.cursor_image_reply == nil || x11c.xfixes_event == 0 { return }
	reply := xfixes.cursor_image_reply(x11c.c, xfixes.cursor_image(x11c.c), nil)
	if reply == nil { return }
	defer posix.free(reply)
	// xcb_xfixes_get_cursor_image_reply_t: cursor_serial at [20]
	return u64((^u32)(uintptr(reply) + 20)^), true
}
