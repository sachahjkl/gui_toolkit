package platform

// The pointing devices of the computer (input_devices; input_devices_win32 in pointer_win32.odin, a mouse only on the
// systems without an implementation), and what they mean for an interface: how precise the primary pointer is, whether
// it can hover (the CSS media features pointer / any-pointer / hover / any-hover follow the same rules).

Input_Devices :: struct {
	mouse:        bool,   // a mouse or a touchpad
	pen:          bool,   // a pen (integrated or external digitizer)
	touch_points: int,    // simultaneous touches the touch screen takes (0: no touch screen)
}

Pointer_Accuracy :: enum u8 { None, Coarse, Fine }

// The devices, read from the system (cheap: call it when needed, or once per settings change; it changes when a device
// is plugged in or out).
input_devices :: proc() -> Input_Devices { return input_devices_query() }

// How many touches the touch screen takes at once (0: none). Same as input_devices().touch_points.
touch_max_points :: proc() -> int { return input_devices_query().touch_points }

// The primary pointer: the mouse when there is one (a computer with a touch screen and a mouse is used with the mouse),
// else the pen, else a finger.
primary_pointer :: proc(d: Input_Devices) -> (accuracy: Pointer_Accuracy, hover: bool) {
	switch {
	case d.mouse: return .Fine, true
	case d.pen: return .Fine, true
	case d.touch_points > 0: return .Coarse, false
	}
	return .None, false
}

// Every pointer: the accuracies they have, whether any can hover.
any_pointer :: proc(d: Input_Devices) -> (fine, coarse, hover: bool) {
	fine = d.mouse || d.pen
	coarse = d.touch_points > 0
	hover = d.mouse || d.pen
	return
}
