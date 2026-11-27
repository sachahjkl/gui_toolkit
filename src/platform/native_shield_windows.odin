#+build windows
package platform

// Windows implementation of the invisible input shield for interactive toolkit overlays drawn
// above native child HWNDs (src/md/features/popup-over-native.md).
//
// The shield is an owned WS_POPUP window with WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
// WS_EX_NOREDIRECTIONBITMAP and no swap chain: DWM allocates no surface for it, it draws zero
// pixels, and SetWindowRgn restricts hit-testing to the exact interactive rectangles over
// native child views. Outside the region, pointer messages fall straight through to cross-
// process child HWNDs (such as WebView2). Inside the region, mouse moves, buttons, wheel, and
// cursor updates forward directly into the owner Window.

import "base:runtime"
import "core:time"
import win "core:sys/windows"

foreign import shield_user32 "system:User32.lib"
foreign import shield_gdi32 "system:Gdi32.lib"

@(default_calling_convention = "system", private = "file")
foreign shield_user32 {
	SetWindowRgn :: proc(hwnd: win.HWND, rgn: win.HRGN, redraw: win.BOOL) -> i32 ---
	ValidateRect :: proc(hwnd: win.HWND, rect: ^win.RECT) -> win.BOOL ---
	MapWindowPoints :: proc(from, to: win.HWND, pts: ^win.POINT, count: u32) -> i32 ---
}

@(default_calling_convention = "system", private = "file")
foreign shield_gdi32 {
	CreateRectRgn :: proc(left, top, right, bottom: i32) -> win.HRGN ---
	CombineRgn :: proc(dest, src1, src2: win.HRGN, mode: i32) -> i32 ---
	DeleteObject :: proc(object: win.HGDIOBJ) -> win.BOOL ---
}

@(private) SHIELD_CLASS_NAME :: "gui_toolkit_input_shield"
@(private = "file") SHIELD_RGN_OR :: 2
@(private = "file") SHIELD_MA_NOACTIVATE :: 3
@(private = "file") SHIELD_XBUTTON1 :: 1
@(private = "file") SHIELD_WHEEL_NOTCH_UNITS :: 120

// Registers the invisible input shield window class once (called inside window_class_register).
@(private)
native_shield_class_register :: proc(instance: win.HINSTANCE) {
	wc := win.WNDCLASSEXW{
		cbSize        = size_of(win.WNDCLASSEXW),
		style         = win.CS_DBLCLKS,
		lpfnWndProc   = native_shield_proc,
		hInstance     = instance,
		hCursor       = nil,
		lpszClassName = win.L(SHIELD_CLASS_NAME),
	}
	win.RegisterClassExW(&wc)
}

// Updates the invisible input shield over `w`'s client area to cover `rects` (physical client
// pixels). Empty `rects` hides the shield so all pointer input goes straight to child windows.
set_native_input_shield :: proc(w: ^Window, rects: [][4]int) {
	if w == nil || w.offscreen || w.hwnd == nil { return }
	clamped := native_shield_clamp_rects(rects, w.size, context.temp_allocator)
	if len(clamped) == 0 {
		clear(&w.input_shield_rects)
		w.input_shield_shown = false
		if w.input_shield != nil && win.IsWindowVisible(w.input_shield) {
			win.ShowWindow(w.input_shield, win.SW_HIDE)
		}
		return
	}
	if w.input_shield == nil {
		instance := win.HINSTANCE(win.GetModuleHandleW(nil))
		ex := u32(win.WS_EX_TOOLWINDOW | win.WS_EX_NOACTIVATE | win.WS_EX_NOREDIRECTIONBITMAP)
		w.input_shield = win.CreateWindowExW(ex, win.L(SHIELD_CLASS_NAME), nil, win.WS_POPUP,
			0, 0, i32(max(w.size.x, 1)), i32(max(w.size.y, 1)), w.hwnd, nil, instance, w)
		if w.input_shield == nil { return }
	}
	was_shown := w.input_shield_shown
	if !was_shown || !native_shield_rects_equal(w.input_shield_rects[:], clamped) {
		region := CreateRectRgn(0, 0, 0, 0)
		if region == nil { return }
		for r in clamped {
			part := CreateRectRgn(i32(r[0]), i32(r[1]), i32(r[0] + r[2]), i32(r[1] + r[3]))
			if part == nil { continue }
			CombineRgn(region, region, part, SHIELD_RGN_OR)
			DeleteObject(win.HGDIOBJ(part))
		}
		// (the system owns the region once SetWindowRgn succeeds)
		if SetWindowRgn(w.input_shield, region, false) == 0 { DeleteObject(win.HGDIOBJ(region)) }
		clear(&w.input_shield_rects)
		append(&w.input_shield_rects, ..clamped)
	}
	w.input_shield_shown = true
	if !was_shown || !win.IsWindowVisible(w.input_shield) {
		native_shield_sync(w)
	}
}

// Aligns the invisible shield to `w`'s client rectangle on screen, hiding it if `w` is hidden or minimized.
@(private)
native_shield_sync :: proc(w: ^Window, visible_hint := true) {
	if w == nil || w.input_shield == nil { return }
	visible := visible_hint && w.input_shield_shown && w.hwnd != nil && win.IsWindowVisible(w.hwnd) && !win.IsIconic(w.hwnd) && w.size.x > 0 && w.size.y > 0
	if !visible {
		if win.IsWindowVisible(w.input_shield) { win.ShowWindow(w.input_shield, win.SW_HIDE) }
		return
	}
	pt := win.POINT{0, 0}
	win.ClientToScreen(w.hwnd, &pt)
	win.SetWindowPos(w.input_shield, nil, pt.x, pt.y, i32(w.size.x), i32(w.size.y),
		win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_SHOWWINDOW)
}

// True when the system cursor is currently over `w`'s input shield (suppresses spurious WM_MOUSELEAVE on owner).
@(private)
pointer_on_native_shield :: proc(w: ^Window) -> bool {
	if w == nil || w.input_shield == nil || !w.input_shield_shown { return false }
	pt: win.POINT
	return bool(win.GetCursorPos(&pt)) && win.WindowFromPoint(pt) == w.input_shield
}

@(private)
native_shield_destroy :: proc(w: ^Window) {
	if w == nil { return }
	if w.input_shield != nil {
		win.SetWindowLongPtrW(w.input_shield, win.GWLP_USERDATA, 0)
		win.DestroyWindow(w.input_shield)
		w.input_shield = nil
	}
	w.input_shield_shown = false
	w.input_shield_tracking = false
	delete(w.input_shield_rects)
	w.input_shield_rects = nil
}

@(private = "file")
native_shield_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	if msg == win.WM_NCCREATE {
		cs := cast(^win.CREATESTRUCTW)uintptr(lparam)
		win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(cs.lpCreateParams)))
	}
	w := cast(^Window)uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))
	if w == nil || w.hwnd == nil { return win.DefWindowProcW(hwnd, msg, wparam, lparam) }

	to_owner :: proc(shield, owner: win.HWND, lparam: win.LPARAM) -> [2]f32 {
		pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
		MapWindowPoints(shield, owner, &pt, 1)
		return {f32(pt.x), f32(pt.y)}
	}
	shield_press :: proc(w: ^Window, shield: win.HWND, b: Mouse_Button, lparam: win.LPARAM) {
		// (activate the owner if in the background and return keyboard focus from any cross-process child HWND such as WebView2)
		if win.GetForegroundWindow() != w.hwnd { win.SetForegroundWindow(w.hwnd) }
		if win.GetFocus() != w.hwnd { win.SetFocus(w.hwnd) }
		button_down(w, b, to_owner(shield, w.hwnd, lparam))
	}

	switch msg {
	case win.WM_ERASEBKGND:
		return 1
	case win.WM_PAINT:
		ValidateRect(hwnd, nil)
		return 0
	case win.WM_MOUSEACTIVATE:
		return SHIELD_MA_NOACTIVATE
	case win.WM_SETCURSOR:
		if win.LOWORD(u32(lparam)) == win.HTCLIENT {
			cursor_on_setcursor(w)
			return 1
		}
	case win.WM_MOUSEMOVE:
		if !w.input_shield_tracking {
			tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd}
			win.TrackMouseEvent(&tme)
			w.input_shield_tracking = true
		}
		append(&w.events, Event{
			kind     = .Mouse_Move,
			pos      = to_owner(hwnd, w.hwnd, lparam),
			mods     = current_mods(),
			stamp    = time.tick_now(),
			buttons  = w.buttons_down,
			emulated = mouse_emulated(),
			pointer  = mouse_emulated_by(),
		})
		return 0
	case win.WM_MOUSELEAVE:
		w.input_shield_tracking = false
		pt: win.POINT
		if !win.GetCursorPos(&pt) || win.WindowFromPoint(pt) != w.hwnd {
			append(&w.events, Event{kind = .Mouse_Leave, stamp = time.tick_now()})
		}
		return 0
	case win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK: shield_press(w, hwnd, .Left, lparam); return 0
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK: shield_press(w, hwnd, .Right, lparam); return 0
	case win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK: shield_press(w, hwnd, .Middle, lparam); return 0
	case win.WM_LBUTTONUP: button_up(w, .Left, to_owner(hwnd, w.hwnd, lparam)); return 0
	case win.WM_RBUTTONUP: button_up(w, .Right, to_owner(hwnd, w.hwnd, lparam)); return 0
	case win.WM_MBUTTONUP: button_up(w, .Middle, to_owner(hwnd, w.hwnd, lparam)); return 0
	case win.WM_XBUTTONDOWN, win.WM_XBUTTONDBLCLK:
		shield_press(w, hwnd, win.HIWORD(u32(wparam)) == SHIELD_XBUTTON1 ? .Back : .Forward, lparam)
		return 1
	case win.WM_XBUTTONUP:
		button_up(w, win.HIWORD(u32(wparam)) == SHIELD_XBUTTON1 ? .Back : .Forward, to_owner(hwnd, w.hwnd, lparam))
		return 1
	case win.WM_MOUSEWHEEL, win.WM_MOUSEHWHEEL:
		units := i16(win.HIWORD(u32(wparam)))
		notches := f32(units) / SHIELD_WHEEL_NOTCH_UNITS
		pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
		win.ScreenToClient(w.hwnd, &pt)
		mods: Modifiers
		if (wparam & MK_CONTROL) != 0 { mods += {.Ctrl} }
		if (wparam & MK_SHIFT) != 0 { mods += {.Shift} }
		if win.GetKeyState(win.VK_MENU) < 0 { mods += {.Alt} }
		e := Event{kind = .Scroll, pos = {f32(pt.x), f32(pt.y)}, mods = mods, stamp = time.tick_now()}
		if units % SHIELD_WHEEL_NOTCH_UNITS != 0 { e.scroll_source = .Finger }
		if msg == win.WM_MOUSEWHEEL { e.delta.y = -notches } else { e.delta.x = notches }
		append(&w.events, e)
		return 0
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
