#+build windows
package platform

// Fingers and pens on Windows (pointer.odin has the API): WM_POINTERDOWN / UPDATE / UP / CAPTURECHANGED of touch and
// pen pointers become Pointer_* events with their details (GetPointerInfo, GetPointerPenInfo, GetPointerTouchInfo). The
// mouse's own pointer messages only exist with EnableMouseInPointer, which the toolkit does not call.

import "core:time"
import win "core:sys/windows"

@(private) POINTER_TOUCH_INFO :: struct {
	pointerInfo:  win.POINTER_INFO,
	touchFlags:   u32,
	touchMask:    u32,   // 1 contact, 2 orientation, 4 pressure
	rcContact:    win.RECT,
	rcContactRaw: win.RECT,
	orientation:  u32,
	pressure:     u32,   // 0..1024
}

foreign import user32_pointer "system:User32.lib"
@(default_calling_convention = "system", private)
foreign user32_pointer {
	GetPointerType      :: proc(id: u32, kind: ^win.POINTER_INPUT_TYPE) -> win.BOOL ---
	GetPointerTouchInfo :: proc(id: u32, info: ^POINTER_TOUCH_INFO) -> win.BOOL ---
}

// The mouse message being handled was made by the system from a finger or a pen (MI_WP_SIGNATURE in its extra info).
@(private)
mouse_emulated :: proc() -> bool {
	return u64(uint(win.GetMessageExtraInfo())) & 0xFFFF_FF00 == 0xFF51_5700
}

// GetSystemMetrics: SM_MAXIMUMTOUCHES (touches the digitizers take), SM_MOUSEPRESENT, SM_DIGITIZER (NID_INTEGRATED_PEN,
// NID_EXTERNAL_PEN).
@(private)
input_devices_query :: proc() -> Input_Devices {
	SM_MOUSEPRESENT :: 19
	SM_DIGITIZER :: 94
	SM_MAXIMUMTOUCHES :: 95
	dig := u32(win.GetSystemMetrics(SM_DIGITIZER))
	return Input_Devices{
		mouse = win.GetSystemMetrics(SM_MOUSEPRESENT) != 0,
		pen = dig & (0x04 | 0x08) != 0,
		touch_points = max(int(win.GetSystemMetrics(SM_MAXIMUMTOUCHES)), 0),
	}
}

// The device the system emulates the mouse for (bit 0x80 of the signature: a touch, else a pen); Mouse when it is the
// mouse itself.
@(private)
mouse_emulated_by :: proc() -> Pointer_Info {
	x := u64(uint(win.GetMessageExtraInfo()))
	if x & 0xFFFF_FF00 != 0xFF51_5700 { return {} }
	return Pointer_Info{kind = x & 0x80 != 0 ? .Touch : .Pen}
}

@(private)
pointer_message :: proc(w: ^Window, msg: win.UINT, wparam: win.WPARAM) {
	id := u32(win.LOWORD(u32(wparam)))
	kind: win.POINTER_INPUT_TYPE
	if !GetPointerType(id, &kind) || (kind != .PT_TOUCH && kind != .PT_PEN) { return }
	info: win.POINTER_INFO
	pi := Pointer_Info{id = id, kind = kind == .PT_PEN ? .Pen : .Touch}
	measured: Maybe(f32)
	if kind == .PT_PEN {
		pen: win.POINTER_PEN_INFO
		if !win.GetPointerPenInfo(id, &pen) { return }
		info = pen.pointerInfo
		if .pressure in pen.penMask { measured = f32(pen.pressure) / 1024 }
		if .tiltX in pen.penMask { pi.tilt.x = f32(pen.tiltX) }
		if .tiltY in pen.penMask { pi.tilt.y = f32(pen.tiltY) }
		if .rotation in pen.penMask { pi.twist = f32(pen.rotation) }
		pi.barrel = .barrel in pen.penFlags
		pi.eraser = .eraser in pen.penFlags || .inverted in pen.penFlags
	} else {
		touch: POINTER_TOUCH_INFO
		if !GetPointerTouchInfo(id, &touch) { return }
		info = touch.pointerInfo
		if touch.touchMask & 4 != 0 { measured = f32(touch.pressure) / 1024 }
		if touch.touchMask & 1 != 0 { pi.contact = {f32(touch.rcContact.right - touch.rcContact.left), f32(touch.rcContact.bottom - touch.rcContact.top)} }
	}
	pi.primary = .primary in info.pointerFlags
	contact := .in_contact in info.pointerFlags
	pi.pressure = pointer_pressure(measured, contact)
	pt := info.ptPixelLocation
	win.ScreenToClient(w.hwnd, &pt)
	e := Event{pos = {f32(pt.x), f32(pt.y)}, mods = current_mods(), pointer = pi, stamp = time.tick_now()}
	switch msg {
	case win.WM_POINTERDOWN:
		pointer_state_down(&w.pointers, id)
		e.kind = .Pointer_Down
	case win.WM_POINTERUPDATE:
		e.kind = .Pointer_Move
	case win.WM_POINTERUP:
		if !pointer_state_up(&w.pointers, id) { return }
		e.kind = .canceled in info.pointerFlags ? .Pointer_Cancel : .Pointer_Up
	case win.WM_POINTERCAPTURECHANGED:
		if !pointer_state_up(&w.pointers, id) { return }
		e.kind = .Pointer_Cancel
	case:
		return
	}
	append(&w.events, e)
}
