package platform

// A pen of a tablet as a backend sees it in pieces (Wayland's zwp_tablet_tool_v2: tablet_wl_linux.odin), turned into
// what the pointer did at each of its frames. The protocol sends the facts of one moment (motion, pressure, tip down,
// tip up, proximity out) and then `frame`: this file keeps them and says, at the frame, which events they make and in
// which order. It touches no system, so a test drives it.

// What a tool frame did, in the order its events go out.
Tablet_Step :: enum u8 {
	Move,     // the pen moved (or came in): Pointer_Move, an emulated Mouse_Move
	Down,     // the tip touched: Pointer_Down, an emulated left Mouse_Press
	Up,       // the tip lifted: Pointer_Up, an emulated left Mouse_Release
	Cancel,   // the pen left while its tip was down (no up came): Pointer_Cancel, the press released as lost
	Leave,    // the pen left the window: an emulated Mouse_Leave
}

// The tool's kinds (zwp_tablet_tool_v2.type: BTN_TOOL_* of linux/input-event-codes.h).
TABLET_TOOL_ERASER :: 0x141
TABLET_TOOL_MOUSE :: 0x146
TABLET_TOOL_LENS :: 0x147
// The full scale of the protocol's pressure.
TABLET_PRESSURE_FULL :: 65535

Tablet_Tool :: struct {
	id:        u32,          // Pointer_Info.id
	tool_type: u32,          // zwp_tablet_tool_v2.type
	measures:  bool,         // it said the pressure capability
	near:      bool,         // in proximity of one of our surfaces
	contact:   bool,         // the tip is down
	pos:       [2]f32,       // the window's pixels
	pressure:  u32,          // 0..TABLET_PRESSURE_FULL
	tilt:      [2]f32,
	twist:     f32,
	barrel:    bool,
	// what came since the last frame
	came, moved, went_down, went_up, went_out: bool,
}

// The tool as Event.pointer.
tablet_tool_info :: proc(t: Tablet_Tool) -> Pointer_Info {
	pi := Pointer_Info{
		id = t.id, primary = true, tilt = t.tilt, twist = t.twist, barrel = t.barrel,
		eraser = t.tool_type == TABLET_TOOL_ERASER, measured = t.measures,
	}
	pi.kind = t.tool_type == TABLET_TOOL_MOUSE || t.tool_type == TABLET_TOOL_LENS ? .Mouse : .Pen
	measured: Maybe(f32)
	if t.measures { measured = pressure_of(t.pressure, TABLET_PRESSURE_FULL) }
	pi.pressure = pointer_pressure(measured, t.contact)
	return pi
}

// The frame came: what it did, in order, and the tool's state after it. A tip down and up in one frame is a tap: both.
tablet_tool_frame :: proc(t: ^Tablet_Tool) -> (steps: [len(Tablet_Step)]Tablet_Step, n: int) {
	add :: proc(steps: ^[len(Tablet_Step)]Tablet_Step, n: ^int, s: Tablet_Step) { steps[n^] = s; n^ += 1 }
	if t.came { t.near = true }
	if t.near && (t.moved || t.came) { add(&steps, &n, .Move) }
	if t.near && t.went_down && !t.contact { t.contact = true; add(&steps, &n, .Down) }
	if t.went_up && t.contact { t.contact = false; add(&steps, &n, .Up) }
	if t.went_out && t.near {
		if t.contact { t.contact = false; add(&steps, &n, .Cancel) }
		t.near = false
		add(&steps, &n, .Leave)
	}
	t.came, t.moved, t.went_down, t.went_up, t.went_out = false, false, false, false, false
	return
}
