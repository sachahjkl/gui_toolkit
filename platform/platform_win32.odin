#+build windows
package platform

import "base:runtime"
import "core:strings"
import "core:unicode/utf16"
import win "core:sys/windows"

Native_Window :: struct {
	hwnd:           win.HWND,
	cursor:         Cursor,
	tracking_mouse: bool,
	high_surrogate: u16,
	in_poll:        bool,
	closed:         bool,
	dark_title:     bool,
	cursors:        [Cursor]win.HCURSOR,
}

@(private) class_name: win.wstring
@(private) class_registered: bool

// Open a window. `size` is in logical pixels (96 dpi): it is scaled by the DPI of the monitor the window lands on
// and clamped to the monitor work area (CW_USEDEFAULT can pick a non-primary monitor with another DPI).
// `transparent`: no GDI redirection surface, for a renderer that presents with alpha (render.init `transparent`).
open_window :: proc(title: string, size: [2]int, user: rawptr = nil, on_frame: proc(user: rawptr) = nil, transparent := false) -> ^Window {
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	icon_res := rawptr(uintptr(1))   // resource id 1 = the app icon, when the exe embeds one
	if !class_registered {
		class_name = win.utf8_to_wstring("gui_toolkit_window")
		wc := win.WNDCLASSEXW{
			cbSize        = size_of(win.WNDCLASSEXW),
			style         = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_DBLCLKS,
			lpfnWndProc   = window_proc,
			hInstance     = instance,
			hIcon         = win.LoadIconA(instance, cstring(icon_res)),   // resource id 1 = app icon when present
			hCursor       = nil,
			lpszClassName = class_name,
		}
		win.RegisterClassExW(&wc)
		class_registered = true
	}

	w := new(Window)
	w.user = user
	w.on_frame = on_frame
	w.dpi_scale = 1
	w.focused = true
	for c in Cursor { w.cursors[c] = win.LoadCursorA(nil, cursor_resource(c)) }

	wtitle := win.utf8_to_wstring(title, context.temp_allocator)
	w.hwnd = win.CreateWindowExW(transparent ? win.WS_EX_NOREDIRECTIONBITMAP : 0, class_name, wtitle, win.WS_OVERLAPPEDWINDOW,
		win.CW_USEDEFAULT, win.CW_USEDEFAULT, 640, 480, nil, nil, instance, w)

	dpi := win.GetDpiForWindow(w.hwnd)
	w.dpi_scale = f32(dpi) / 96
	if dpi == 0 { w.dpi_scale = 1 }

	// size the *outer* window from the desired client size, clamped to the work area
	mon := win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST)
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	win.GetMonitorInfoW(mon, &mi)
	work_w := int(mi.rcWork.right - mi.rcWork.left)
	work_h := int(mi.rcWork.bottom - mi.rcWork.top)
	cw := min(int(f32(size.x) * w.dpi_scale), int(f32(work_w) * 0.94))
	ch := min(int(f32(size.y) * w.dpi_scale), int(f32(work_h) * 0.92))
	rect := win.RECT{0, 0, i32(cw), i32(ch)}
	win.AdjustWindowRectExForDpi(&rect, win.WS_OVERLAPPEDWINDOW, false, 0, dpi)
	ow, oh := int(rect.right - rect.left), int(rect.bottom - rect.top)
	x := int(mi.rcWork.left) + (work_w - ow) / 2
	y := int(mi.rcWork.top) + (work_h - oh) / 2
	win.SetWindowPos(w.hwnd, nil, i32(x), i32(y), i32(ow), i32(oh), win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	update_client_size(w)
	return w
}

// Resize the window so its client area is `size` logical pixels (scaled by the window's DPI).
set_size :: proc(w: ^Window, size: [2]int) {
	dpi := win.GetDpiForWindow(w.hwnd)
	rect := win.RECT{0, 0, i32(f32(size.x) * w.dpi_scale), i32(f32(size.y) * w.dpi_scale)}
	win.AdjustWindowRectExForDpi(&rect, win.WS_OVERLAPPEDWINDOW, false, 0, dpi)
	win.SetWindowPos(w.hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top, win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	update_client_size(w)
}

show_window :: proc(w: ^Window) {
	win.ShowWindow(w.hwnd, win.SW_SHOW)
	win.SetForegroundWindow(w.hwnd)
}

set_title :: proc(w: ^Window, title: string) {
	win.SetWindowTextW(w.hwnd, win.utf8_to_wstring(title, context.temp_allocator))
}

// Matches the OS title bar to a dark or light theme.
// Path of a font in the Windows font folder (%WINDIR%\Fonts), e.g. system_font_path("segoeui.ttf").
system_font_path :: proc(file: string, allocator := context.temp_allocator) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetWindowsDirectoryW(&buf[0], win.MAX_PATH)
	dir := "C:\\Windows"
	if n > 0 && n < win.MAX_PATH {
		if s, err := win.wstring_to_utf8(win.wstring(&buf[0]), int(n), allocator); err == nil { dir = s }
	}
	return strings.concatenate({dir, "\\Fonts\\", file}, allocator)
}

// Translucent window: the OS backdrop (acrylic: blurred desktop, Windows 11 22H2+) shows wherever the app draws with
// alpha < 1. The renderer must clear to transparent black. Returns false when the OS does not support it.
set_backdrop :: proc(w: ^Window, on: bool) -> bool {
	m := on ? win.MARGINS{-1, -1, -1, -1} : win.MARGINS{}
	win.DwmExtendFrameIntoClientArea(w.hwnd, &m)
	kind: i32 = on ? 3 : 1   // DWMSBT_TRANSIENTWINDOW (acrylic) : DWMSBT_NONE
	hr := win.DwmSetWindowAttribute(w.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_SYSTEMBACKDROP_TYPE), &kind, size_of(kind))
	return !on || win.SUCCEEDED(hr)
}

// Windows 11 rounds window corners; `square` turns that off (no effect on Windows 10, which never rounds them).
set_square_corners :: proc(w: ^Window, square: bool) {
	pref: i32 = square ? 1 : 0   // DWMWCP_DONOTROUND : DWMWCP_DEFAULT
	win.DwmSetWindowAttribute(w.hwnd, 33, &pref, size_of(pref))   // DWMWA_WINDOW_CORNER_PREFERENCE
}

set_dark_title :: proc(w: ^Window, dark: bool) {
	if w.dark_title == dark { return }
	w.dark_title = dark
	v := win.BOOL(dark)
	win.DwmSetWindowAttribute(w.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &v, size_of(v))
}

set_cursor :: proc(w: ^Window, c: Cursor) { w.cursor = c }

is_closed :: proc(w: ^Window) -> bool { return w.closed }

// Collects pending OS events. With `wait` the call blocks until at least one message arrives (idle = 0 % CPU),\n// or until `timeout_ms` elapsed when it is > 0.
// The returned slice is valid until the next call. Re-entrant calls return nil.
poll_events :: proc(w: ^Window, wait: bool, timeout_ms := 0) -> []Event {
	if w.in_poll { return nil }
	w.in_poll = true
	defer w.in_poll = false

	clear(&w.events)
	msg: win.MSG
	if wait && !win.PeekMessageW(&msg, nil, 0, 0, win.PM_NOREMOVE) {
		// with a timeout, a timer message wakes the wait (caret blink, tooltip delay)
		if timeout_ms > 0 { win.SetTimer(w.hwnd, 1, u32(timeout_ms), nil) }
		win.WaitMessage()
		if timeout_ms > 0 { win.KillTimer(w.hwnd, 1) }
	}
	for win.PeekMessageW(&msg, nil, 0, 0, win.PM_REMOVE) {
		if msg.message == win.WM_QUIT {
			w.closed = true
			append(&w.events, Event{kind = .Close})
			continue
		}
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
	return w.events[:]
}

// Blocks until a message is pending or `timeout_ms` elapsed (0 = no timeout). Does not consume anything: follow
// with render.wait_for_frame, then poll_events(w, false), so the frame is built from the freshest input.
wait_event :: proc(w: ^Window, timeout_ms := 0) {
	msg: win.MSG
	if win.PeekMessageW(&msg, nil, 0, 0, win.PM_NOREMOVE) { return }
	if timeout_ms > 0 { win.SetTimer(w.hwnd, 1, u32(timeout_ms), nil) }
	win.WaitMessage()
	if timeout_ms > 0 { win.KillTimer(w.hwnd, 1) }
}

// Request a repaint-free wake up (used by timers/animations when the loop is waiting).
wake :: proc(w: ^Window) { win.PostMessageW(w.hwnd, win.WM_NULL, 0, 0) }

get_clipboard :: proc(w: ^Window, allocator := context.allocator) -> string {
	if !win.OpenClipboard(w.hwnd) { return "" }
	defer win.CloseClipboard()
	h := win.GetClipboardData(win.CF_UNICODETEXT)
	if h == nil { return "" }
	p := cast([^]u16)win.GlobalLock(win.HGLOBAL(h))
	if p == nil { return "" }
	defer win.GlobalUnlock(win.HGLOBAL(h))
	n := 0
	for p[n] != 0 { n += 1 }
	s, _ := win.utf16_to_utf8(p[:n], allocator)
	return s
}

set_clipboard :: proc(w: ^Window, text: string) {
	if !win.OpenClipboard(w.hwnd) { return }
	defer win.CloseClipboard()
	win.EmptyClipboard()
	wide := win.utf8_to_utf16(text, context.temp_allocator)
	bytes := (len(wide) + 1) * size_of(u16)
	mem := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(bytes))
	if mem == nil { return }
	dst := cast([^]u16)win.GlobalLock(win.HGLOBAL(mem))
	copy(dst[:len(wide)], wide)
	dst[len(wide)] = 0
	win.GlobalUnlock(win.HGLOBAL(mem))
	win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(mem))
}

// Windows "show animations" accessibility setting (Settings > Accessibility > Visual effects).
os_animations_enabled :: proc() -> bool {
	SPI_GETCLIENTAREAANIMATION :: 0x1042
	on: win.BOOL = true
	if !win.SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &on, 0) { return true }
	return bool(on)
}

// Per-user config directory (%APPDATA%).
config_dir :: proc(allocator := context.allocator) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetEnvironmentVariableW(win.utf8_to_wstring("APPDATA", context.temp_allocator), &buf[0], len(buf))
	if n == 0 { return "" }
	s, _ := win.utf16_to_utf8(buf[:n], allocator)
	return s
}

////////////////////////////////
// internals

@(private)
cursor_resource :: proc(c: Cursor) -> cstring {
	switch c {
	case .Arrow:       return win.IDC_ARROW
	case .Hand:        return win.IDC_HAND
	case .Text:        return win.IDC_IBEAM
	case .Resize_H:    return win.IDC_SIZEWE
	case .Resize_V:    return win.IDC_SIZENS
	case .Move:        return win.IDC_SIZEALL
	case .Not_Allowed: return win.IDC_NO
	}
	return win.IDC_ARROW
}

@(private)
update_client_size :: proc(w: ^Window) {
	r: win.RECT
	win.GetClientRect(w.hwnd, &r)
	w.size = {int(r.right - r.left), int(r.bottom - r.top)}
}

@(private)
current_mods :: proc() -> (m: Modifiers) {
	if win.GetKeyState(win.VK_CONTROL) < 0 { m += {.Ctrl} }
	if win.GetKeyState(win.VK_SHIFT) < 0   { m += {.Shift} }
	if win.GetKeyState(win.VK_MENU) < 0    { m += {.Alt} }
	return
}

@(private)
key_from_vk :: proc(vk: win.WPARAM) -> Key {
	switch vk {
	case 'A'..='Z': return Key(int(Key.A) + int(vk - 'A'))
	case '0'..='9': return Key(int(Key.N0) + int(vk - '0'))
	case win.VK_F1..=win.VK_F12: return Key(int(Key.F1) + int(vk - win.VK_F1))
	case win.VK_ESCAPE:  return .Escape
	case win.VK_RETURN:  return .Return
	case win.VK_TAB:     return .Tab
	case win.VK_SPACE:   return .Space
	case win.VK_BACK:    return .Backspace
	case win.VK_DELETE:  return .Delete
	case win.VK_INSERT:  return .Insert
	case win.VK_LEFT:    return .Left
	case win.VK_RIGHT:   return .Right
	case win.VK_UP:      return .Up
	case win.VK_DOWN:    return .Down
	case win.VK_HOME:    return .Home
	case win.VK_END:     return .End
	case win.VK_PRIOR:   return .Page_Up
	case win.VK_NEXT:    return .Page_Down
	case win.VK_OEM_COMMA:  return .Comma
	case win.VK_OEM_PERIOD: return .Period
	case win.VK_OEM_2:      return .Slash
	case win.VK_OEM_MINUS:  return .Minus
	case win.VK_OEM_PLUS:   return .Equal
	case win.VK_SHIFT:   return .Shift
	case win.VK_CONTROL: return .Ctrl
	case win.VK_MENU:    return .Alt
	}
	return .None
}

@(private)
window_proc :: proc "system" (hwnd: win.HWND, msg: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT {
	context = runtime.default_context()
	w: ^Window
	if msg == win.WM_NCCREATE {
		cs := cast(^win.CREATESTRUCTW)uintptr(lparam)
		win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, win.LONG_PTR(uintptr(cs.lpCreateParams)))
	}
	w = cast(^Window)uintptr(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))
	if w == nil { return win.DefWindowProcW(hwnd, msg, wparam, lparam) }

	push :: proc(w: ^Window, e: Event) { append(&w.events, e) }
	mouse_pos :: proc(lparam: win.LPARAM) -> [2]f32 {
		return {f32(win.GET_X_LPARAM(lparam)), f32(win.GET_Y_LPARAM(lparam))}
	}

	switch msg {
	case win.WM_CLOSE:
		w.closed = true
		push(w, {kind = .Close})
		return 0

	case win.WM_DESTROY:
		return 0

	case win.WM_SETFOCUS:  w.focused = true
	case win.WM_KILLFOCUS: w.focused = false

	case win.WM_SETCURSOR:
		if win.LOWORD(u32(lparam)) == win.HTCLIENT {
			win.SetCursor(w.cursors[w.cursor])
			return 1
		}

	case win.WM_GETMINMAXINFO:
		mmi := cast(^win.MINMAXINFO)uintptr(lparam)
		mmi.ptMinTrackSize = {i32(320 * w.dpi_scale), i32(240 * w.dpi_scale)}
		return 0

	case win.WM_DPICHANGED:
		w.dpi_scale = f32(win.HIWORD(u32(wparam))) / 96
		r := cast(^win.RECT)uintptr(lparam)
		win.SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		return 0

	case win.WM_ERASEBKGND:
		return 1

	case win.WM_SIZE:
		// only record the size: CS_HREDRAW|CS_VREDRAW invalidate the window, and WM_PAINT (which follows at once,
		// also inside the live-resize loop) renders. Rendering here too meant two presents per resize step.
		update_client_size(w)
		return 0

	case win.WM_PAINT:
		ps: win.PAINTSTRUCT
		win.BeginPaint(hwnd, &ps)
		win.EndPaint(hwnd, &ps)
		if w.on_frame != nil && w.size.x > 0 && w.size.y > 0 { w.on_frame(w.user) }
		return 0

	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		key := key_from_vk(wparam)
		if key != .None { push(w, {kind = .Key_Press, key = key, mods = current_mods(), repeat = (lparam & (1 << 30)) != 0}) }
		if msg == win.WM_SYSKEYDOWN && key != .None && wparam != win.VK_F4 { return 0 }   // no menu-bar beep on Alt+key
	case win.WM_KEYUP, win.WM_SYSKEYUP:
		key := key_from_vk(wparam)
		if key != .None { push(w, {kind = .Key_Release, key = key, mods = current_mods()}) }

	case win.WM_CHAR:
		c := u16(wparam)
		if c >= 0xD800 && c < 0xDC00 { w.high_surrogate = c; return 0 }
		r: rune = rune(c)
		if c >= 0xDC00 && c < 0xE000 {
			pair := [2]u16{w.high_surrogate, c}
			out: [2]rune
			if utf16.decode(out[:], pair[:]) > 0 { r = out[0] }
			w.high_surrogate = 0
		}
		if r >= 32 && r != 127 { push(w, {kind = .Text, text = r, mods = current_mods()}) }
		return 0

	case win.WM_MOUSEMOVE:
		if !w.tracking_mouse {
			tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE, hwndTrack = hwnd}
			win.TrackMouseEvent(&tme)
			w.tracking_mouse = true
		}
		push(w, {kind = .Mouse_Move, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_MOUSELEAVE:
		w.tracking_mouse = false
		push(w, {kind = .Mouse_Leave})

	case win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK: win.SetCapture(hwnd); push(w, {kind = .Mouse_Press, button = .Left, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK: win.SetCapture(hwnd); push(w, {kind = .Mouse_Press, button = .Right, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK: win.SetCapture(hwnd); push(w, {kind = .Mouse_Press, button = .Middle, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_LBUTTONUP: win.ReleaseCapture(); push(w, {kind = .Mouse_Release, button = .Left, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_RBUTTONUP: win.ReleaseCapture(); push(w, {kind = .Mouse_Release, button = .Right, pos = mouse_pos(lparam), mods = current_mods()})
	case win.WM_MBUTTONUP: win.ReleaseCapture(); push(w, {kind = .Mouse_Release, button = .Middle, pos = mouse_pos(lparam), mods = current_mods()})

	case win.WM_MOUSEWHEEL, win.WM_MOUSEHWHEEL:
		notches := f32(i16(win.HIWORD(u32(wparam)))) / 120
		pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
		win.ScreenToClient(hwnd, &pt)
		// modifiers as they were when the wheel moved (the MK_* flags travel with the message)
		mods: Modifiers
		if (wparam & 0x0008) != 0 { mods += {.Ctrl} }
		if (wparam & 0x0004) != 0 { mods += {.Shift} }
		if win.GetKeyState(win.VK_MENU) < 0 { mods += {.Alt} }
		e := Event{kind = .Scroll, pos = {f32(pt.x), f32(pt.y)}, mods = mods}
		if msg == win.WM_MOUSEWHEEL { e.delta.y = -notches } else { e.delta.x = notches }
		push(w, e)
	}
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
