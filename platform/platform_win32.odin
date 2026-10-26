#+build windows
package platform

import "base:runtime"
import "core:strings"
import "core:time"
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
	cursors:        Cursor_State,   // cursors_win32.odin
	keep_events:    bool,           // wait_handle took input: the next poll_events adds to it
	paint_requested: bool,          // WM_PAINT came during poll_events: take_paint_request
	modal:          int,            // inside a loop of the system (move / size, menu): it owns the messages, frames come from WM_PAINT
	display:        Display_Info,   // display_info's cache
	display_stale:  bool,
	integrated:     bool,           // set_integrated_title: the client area covers the title bar
	fullscreen:     bool,
	nc_tracking:    bool,           // TrackMouseEvent asked for WM_NCMOUSELEAVE
	saved_style:    i32,            // before full screen
	saved_place:    win.WINDOWPLACEMENT,
	injected:       [dynamic]Event, // inject_event: synthetic input, handed out by the next poll_events after the system's own
	border_color:   u32,            // set_border_color: the COLORREF given to the compositor
	border_color_set: bool,
	buttons_down:   Mouse_Buttons,   // pressed in this window and not yet released: the mouse stays captured until none is
	returned:       int,            // events the last poll_events handed out: dropped at the next one (those that came since are kept)
	stats:          Pump_Stats,
	in_def_proc:    int,            // depth of DefWindowProc calls of the window procedure: the system's loops run inside them (size_move.odin)
	sizemove:       int,            // move / size loops of the system open (size_move_step)
	want_maximized: bool,           // set_placement asked for it: show_window shows the window maximized
	dnd:            ^Dnd_State,     // drag and drop (dragdrop_win32.odin), made on first use
	pointers:       Pointer_State,  // fingers and pens (pointer_win32.odin)
	trays:          [dynamic]^Tray, // icons of the notification area this window receives (tray_win32.odin)
	clip_watch:     bool,           // clipboard_watch: the window hears WM_CLIPBOARDUPDATE
	clip_seen:      u32,            // clipboard_changed: the clipboard's sequence number last told
	a11y:           rawptr,         // the accessibility adapter (a11y_accesskit.odin), nil when not compiled in
}

// Windows of this thread inside poll_events / wait_handle: while a window pumps the thread's messages, a repaint of
// another window of the thread is left to the app's own loop (see WM_PAINT).
@(private, thread_local) pumping: int

@(private)
TIMER_MODAL_FRAME :: 2   // (id 1 is poll_events' wait timeout)
@(private)
MODAL_FRAME_MS :: 16

@(private) os_build: u32   // Windows build number (RtlGetVersion), 0 until asked

// Windows 11 (build 22000 or later): rounded corners, Snap Layouts, a frame drawn by the compositor around the window.
is_windows_11 :: proc() -> bool {
	if os_build == 0 {
		vi := win.OSVERSIONINFOEXW{dwOSVersionInfoSize = size_of(win.OSVERSIONINFOEXW)}
		win.RtlGetVersion(&vi)
		os_build = max(vi.dwBuildNumber, 1)
	}
	return os_build >= 22000
}

@(private) class_name: win.wstring
@(private) class_registered: bool

// Open a window. `size` is in logical pixels (96 dpi): it is scaled by the DPI of the monitor the window lands on
// and clamped to the monitor work area (CW_USEDEFAULT can pick a non-primary monitor with another DPI).
// `transparent`: no GDI redirection surface, for a renderer that presents with alpha (render.init `transparent`).
// `integrated_title`: the app draws the title bar (set_integrated_title); `size` is then the whole window's inside.
// Returns nil when the system could not make the window.
open_window :: proc(title: string, size: [2]int, user: rawptr = nil, on_frame: proc(user: rawptr) = nil, transparent := false, integrated_title := false) -> ^Window {
	win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	icon_res := rawptr(uintptr(1))   // resource id 1 = the app icon, when the exe embeds one
	if !class_registered {
		class_name = win.L("gui_toolkit_window")   // (a literal: it must outlive whatever allocator the first window was made under, for the windows made later)
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
	w.active = true
	w.display_stale = true
	w.integrated = integrated_title

	// made on the monitor the user is on, so that it gets that monitor's DPI and refresh rate from the start: CW_USEDEFAULT puts it on the
	// primary one whatever program launched it
	at_x, at_y := i32(win.CW_USEDEFAULT), i32(win.CW_USEDEFAULT)
	if start := start_monitor_work_area(); start.right > start.left { at_x, at_y = start.left + 48, start.top + 48 }
	wtitle := win.utf8_to_wstring(title, context.temp_allocator)
	w.hwnd = win.CreateWindowExW(transparent ? win.WS_EX_NOREDIRECTIONBITMAP : 0, class_name, wtitle, win.WS_OVERLAPPEDWINDOW,
		at_x, at_y, 640, 480, nil, nil, instance, w)
	if w.hwnd == nil {   // out of resources (USER handles, memory): no window
		free(w)
		return nil
	}

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
	ow, oh := outer_size(w, cw, ch, dpi)
	x := int(mi.rcWork.left) + (work_w - ow) / 2
	y := int(mi.rcWork.top) + (work_h - oh) / 2
	// (with an integrated title bar SWP_FRAMECHANGED makes the system ask WM_NCCALCSIZE again)
	win.SetWindowPos(w.hwnd, nil, i32(x), i32(y), i32(ow), i32(oh), win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED)
	update_client_size(w)
	a11y_attach(w)   // (before the window is shown: never while WM_GETOBJECT is handled)
	return w
}

// The work area of the monitor a new window should open on: the one of the window the user is working in (the program that launched
// this one is usually in front), else the one under the pointer. Empty when neither can be had (the system chooses then).
@(private)
start_monitor_work_area :: proc() -> win.RECT {
	mon: win.HMONITOR
	if fg := win.GetForegroundWindow(); fg != nil {
		mon = win.MonitorFromWindow(fg, .MONITOR_DEFAULTTONULL)
	}
	if mon == nil {
		pt: win.POINT
		if win.GetCursorPos(&pt) { mon = win.MonitorFromPoint(pt, .MONITOR_DEFAULTTONEAREST) }
	}
	if mon == nil { return {} }
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(mon, &mi) { return {} }
	return mi.rcWork
}

// Outer size of a window whose client area is cw x ch: the frame around it (no top frame nor caption with an
// integrated title bar: the client area starts at the window's top).
@(private)
outer_size :: proc(w: ^Window, cw, ch: int, dpi: u32) -> (int, int) {
	rect := win.RECT{0, 0, i32(cw), i32(ch)}
	win.AdjustWindowRectExForDpi(&rect, win.WS_OVERLAPPEDWINDOW, false, 0, dpi)
	if w.integrated { rect.top = 0 }
	return int(rect.right - rect.left), int(rect.bottom - rect.top)
}

// Resize the window so its client area is `size` logical pixels (scaled by the window's DPI).
set_size :: proc(w: ^Window, size: [2]int) {
	dpi := win.GetDpiForWindow(w.hwnd)
	ow, oh := outer_size(w, int(f32(size.x) * w.dpi_scale), int(f32(size.y) * w.dpi_scale), dpi)
	win.SetWindowPos(w.hwnd, nil, 0, 0, i32(ow), i32(oh), win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE)
	update_client_size(w)
}

////////////////////////////////
// Integrated title bar, window state

// Switches between the system's title bar and one drawn by the app, at any time: the window keeps its outer rect (the
// client area grows by the old title bar, or shrinks back). With `on`, the app reports its title bar every frame with
// set_chrome_regions (the toolkit's ui does it when Build_Params.window is set) and draws the caption buttons
// (ui.window_buttons).
set_integrated_title :: proc(w: ^Window, on: bool) {
	if w.integrated == on { return }
	w.integrated = on
	chrome_regions_clear(&w.chrome)
	win.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED)
	update_client_size(w)
}

is_integrated_title :: proc(w: ^Window) -> bool { return w.integrated }

// The title bar the app drew this frame (client pixels): copied, the caller keeps its regions.
set_chrome_regions :: proc(w: ^Window, c: ^Chrome_Regions) {
	chrome_regions_clear(&w.chrome)
	append(&w.chrome.caption, ..c.caption[:])
	append(&w.chrome.holes, ..c.holes[:])
	append(&w.chrome.slanted, ..c.slanted[:])
	w.chrome.buttons = c.buttons
}

is_maximized :: proc(w: ^Window) -> bool { return bool(win.IsZoomed(w.hwnd)) }
is_minimized :: proc(w: ^Window) -> bool { return bool(win.IsIconic(w.hwnd)) }
is_fullscreen :: proc(w: ^Window) -> bool { return w.fullscreen }

minimize :: proc(w: ^Window) { win.PostMessageW(w.hwnd, win.WM_SYSCOMMAND, win.SC_MINIMIZE, 0) }

// Maximizes, or restores a maximized window (the maximize / restore caption button, a double click on the title bar).
toggle_maximize :: proc(w: ^Window) {
	win.PostMessageW(w.hwnd, win.WM_SYSCOMMAND, is_maximized(w) ? win.SC_RESTORE : win.SC_MAXIMIZE, 0)
}

// Asks the window to close as the close button of the system does (the app sees a .Close event).
request_close :: proc(w: ^Window) { win.PostMessageW(w.hwnd, win.WM_SYSCOMMAND, win.SC_CLOSE, 0) }

// Full screen: the window covers its monitor, without frame nor title bar (F11). Off: back to where it was, maximized or not.
set_fullscreen :: proc(w: ^Window, on: bool) {
	if w.fullscreen == on { return }
	if on {
		w.saved_place = {length = size_of(win.WINDOWPLACEMENT)}
		win.GetWindowPlacement(w.hwnd, &w.saved_place)
		w.saved_style = win.GetWindowLongW(w.hwnd, win.GWL_STYLE)
		mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
		win.GetMonitorInfoW(win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST), &mi)
		w.fullscreen = true
		win.SetWindowLongW(w.hwnd, win.GWL_STYLE, i32(u32(w.saved_style) & ~win.WS_OVERLAPPEDWINDOW))
		r := mi.rcMonitor
		win.SetWindowPos(w.hwnd, win.HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
	} else {
		w.fullscreen = false
		win.SetWindowLongW(w.hwnd, win.GWL_STYLE, w.saved_style)
		win.SetWindowPlacement(w.hwnd, &w.saved_place)
		win.SetWindowPos(w.hwnd, nil, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOZORDER | win.SWP_NOOWNERZORDER | win.SWP_FRAMECHANGED)
	}
	w.display_stale = true
	update_client_size(w)
}

// The system menu (Restore, Move, Size, Minimize, Maximize, Close) at `pos` (client pixels), as a right click on a
// title bar of the system opens it. The chosen command runs as if it came from the system's title bar.
// The menu's loop paints the window from WM_PAINT (on_frame) until it closes: call it outside the app's build and
// drawing (after the frame), or its frame is made inside the one being built (ui.building tells).
show_system_menu :: proc(w: ^Window, pos: [2]f32) {
	menu := win.GetSystemMenu(w.hwnd, false)
	if menu == nil { return }
	maxed := is_maximized(w)
	state :: proc(on: bool) -> u32 { return on ? win.MF_ENABLED : win.MF_GRAYED }
	win.EnableMenuItem(menu, win.SC_RESTORE, win.MF_BYCOMMAND | state(maxed))
	win.EnableMenuItem(menu, win.SC_MOVE, win.MF_BYCOMMAND | state(!maxed))
	win.EnableMenuItem(menu, win.SC_SIZE, win.MF_BYCOMMAND | state(!maxed))
	win.EnableMenuItem(menu, win.SC_MINIMIZE, win.MF_BYCOMMAND | win.MF_ENABLED)
	win.EnableMenuItem(menu, win.SC_MAXIMIZE, win.MF_BYCOMMAND | state(!maxed))
	win.EnableMenuItem(menu, win.SC_CLOSE, win.MF_BYCOMMAND | win.MF_ENABLED)
	win.SetMenuDefaultItem(menu, win.SC_CLOSE, 0)
	pt := win.POINT{i32(pos.x), i32(pos.y)}
	win.ClientToScreen(w.hwnd, &pt)
	cmd := win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_LEFTALIGN | win.TPM_TOPALIGN | win.TPM_RIGHTBUTTON, pt.x, pt.y, 0, w.hwnd, nil)
	if cmd != 0 { win.PostMessageW(w.hwnd, win.WM_SYSCOMMAND, win.WPARAM(cmd), 0) }
}

// Windows 10 draws no line along the top of a window whose client area covers its title bar: the app draws it there
// (1 px, the theme's border colour) while the window is neither maximized nor full screen.
needs_top_border :: proc(w: ^Window) -> bool {
	return w.integrated && !w.fullscreen && !is_windows_11() && !is_maximized(w)
}

foreign import user32_chrome "system:User32.lib"
@(default_calling_convention = "system", private)
foreign user32_chrome {
	GetIconInfo :: proc(icon: win.HICON, info: ^win.ICONINFO) -> win.BOOL ---
}

// The exe's icon (resource id 1, the one the window and the taskbar show) at `size` x `size` pixels, as RGBA8 with
// straight alpha (sRGB): for an app that draws it in its own title bar. ok = false when the exe has no icon.
app_icon_rgba :: proc(size: int, allocator := context.allocator) -> (pixels: []u8, ok: bool) {
	instance := win.HINSTANCE(win.GetModuleHandleW(nil))
	icon := win.HICON(win.LoadImageW(instance, transmute(win.LPCWSTR)uintptr(1), win.IMAGE_ICON, i32(size), i32(size), win.LR_DEFAULTCOLOR))
	if icon == nil { return nil, false }
	defer win.DestroyIcon(icon)
	info: win.ICONINFO
	if !GetIconInfo(icon, &info) { return nil, false }
	defer { if info.hbmColor != nil { win.DeleteObject(win.HGDIOBJ(info.hbmColor)) }; if info.hbmMask != nil { win.DeleteObject(win.HGDIOBJ(info.hbmMask)) } }
	if info.hbmColor == nil { return nil, false }
	bmi := win.BITMAPINFO{bmiHeader = {biSize = size_of(win.BITMAPINFOHEADER), biWidth = i32(size), biHeight = -i32(size), biPlanes = 1, biBitCount = 32, biCompression = win.BI_RGB}}
	dc := win.CreateCompatibleDC(nil)
	defer win.DeleteDC(dc)
	pixels = make([]u8, size * size * 4, allocator)
	if win.GetDIBits(dc, info.hbmColor, 0, u32(size), raw_data(pixels), &bmi, win.DIB_RGB_COLORS) == 0 {
		delete(pixels, allocator)
		return nil, false
	}
	// icons keep straight alpha: BGRA to RGBA
	any_alpha := false
	for i := 0; i < len(pixels); i += 4 {
		pixels[i], pixels[i + 2] = pixels[i + 2], pixels[i]
		if pixels[i + 3] != 0 { any_alpha = true }
	}
	if !any_alpha { for i := 3; i < len(pixels); i += 4 { pixels[i] = 255 } }   // an icon without alpha: opaque
	return pixels, true
}

// Thickness of the resize band along the top of an integrated title bar, and of the system's frame (physical pixels).
resize_border :: proc(w: ^Window) -> int {
	dpi := win.GetDpiForWindow(w.hwnd)
	return int(win.GetSystemMetricsForDpi(win.SM_CYFRAME, dpi) + win.GetSystemMetricsForDpi(win.SM_CXPADDEDBORDER, dpi))
}

show_window :: proc(w: ^Window) {
	win.ShowWindow(w.hwnd, w.want_maximized ? win.SW_SHOWMAXIMIZED : win.SW_SHOW)
	w.want_maximized = false
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

// The 1-pixel border Windows 11 draws around the window (DWMWA_BORDER_COLOR): an opaque color (0xRRGGBB), or nil for
// the system's. With an integrated title bar, the system's border is drawn half transparent along the top edge, over
// the app's tab strip: a line of whatever lies behind the window shows there (a console's text). An app that draws its
// title bar gives the color of its edge. No effect on Windows 10 (no such border). Cheap to call every frame.
set_border_color :: proc(w: ^Window, rgb: Maybe(u32)) {
	if !is_windows_11() { return }
	DWMWA_BORDER_COLOR :: 34
	DWMWA_COLOR_DEFAULT :: 0xFFFFFFFF
	v: u32 = DWMWA_COLOR_DEFAULT
	if c, ok := rgb.?; ok { v = (c >> 16 & 0xFF) | (c & 0xFF00) | (c & 0xFF) << 16 }   // COLORREF is 0x00BBGGRR
	if w.border_color_set && w.border_color == v { return }
	w.border_color, w.border_color_set = v, true
	win.DwmSetWindowAttribute(w.hwnd, DWMWA_BORDER_COLOR, &v, size_of(v))
}

set_dark_title :: proc(w: ^Window, dark: bool) {
	if w.dark_title == dark { return }
	w.dark_title = dark
	v := win.BOOL(dark)
	win.DwmSetWindowAttribute(w.hwnd, u32(win.DWMWINDOWATTRIBUTE.DWMWA_USE_IMMERSIVE_DARK_MODE), &v, size_of(v))
}

is_closed :: proc(w: ^Window) -> bool { return w.closed }

// Destroys the window and what it holds (its cursors, drawn and custom; its event list; its title bar's regions),
// then frees `w`. A process that ends with its window open needs not call it.
destroy_window :: proc(w: ^Window) {
	if w == nil { return }
	dnd_destroy(w)   // (revoked while the window exists)
	tray_destroy_all(w)
	if w.clip_watch { clipboard_watch(w, false) }
	pointer_state_destroy(&w.pointers)
	a11y_detach(w)
	if w.hwnd != nil {
		win.SetWindowLongPtrW(w.hwnd, win.GWLP_USERDATA, 0)   // the window procedure no longer reaches w
		win.DestroyWindow(w.hwnd)
		w.hwnd = nil
	}
	cursors_destroy(w)
	delete(w.events)
	delete(w.injected)
	chrome_regions_destroy(&w.chrome)
	free(w)
}

// Collects pending OS events. With `wait` the call blocks until at least one message arrives (idle = 0 % CPU),\n// or until `timeout_ms` elapsed when it is > 0.
// The returned slice is valid until the next call. Re-entrant calls return nil.
// The messages of every window of the thread are taken (each window procedure queues the events of its own window): with
// several windows, each one's events wait in `events` for its own poll_events, which drops only what it returned before.
poll_events :: proc(w: ^Window, wait: bool, timeout_ms := 0) -> []Event {
	if w.in_poll { return nil }
	w.in_poll = true
	pumping += 1
	defer {
		w.in_poll = false
		pumping -= 1
	}

	if !w.keep_events { drop_returned(w) }   // what wait_handle took is the start of this batch
	w.keep_events = false
	msg: win.MSG
	if wait && len(w.events) == 0 && len(w.injected) == 0 && !win.PeekMessageW(&msg, nil, 0, 0, win.PM_NOREMOVE) {
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
	take_injected(w)
	w.returned = len(w.events)
	return w.events[:]
}

// Removes the events the last poll_events handed out (they have been read); the ones queued since stay.
@(private)
drop_returned :: proc(w: ^Window) {
	n := min(w.returned, len(w.events))
	w.returned = 0
	if n == 0 { return }
	copy(w.events[:], w.events[n:])
	resize(&w.events, len(w.events) - n)
}

// Queues an event as if the system had delivered it: the next poll_events returns it (after the real events of that
// batch), through the same path as any other, so hover, focus, shortcuts and text input behave as for a real device.
// For tests, remote control and macros; call it from the thread that polls. `stamp` is set when the event is taken.
// The caller wakes the loop (wake) when it may be waiting.
inject_event :: proc(w: ^Window, e: Event) {
	append(&w.injected, e)
}

@(private)
take_injected :: proc(w: ^Window) {
	if len(w.injected) == 0 { return }
	now := time.tick_now()
	for &e in w.injected {
		e.stamp = now
		if e.kind == .Close { w.closed = true }   // as WM_CLOSE: a loop that tests is_closed ends
		append(&w.events, e)
	}
	clear(&w.injected)
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

// True once after the system asked for a repaint (uncovered, resized) while the app polled: draw a frame. (Inside a
// loop of the system the window calls on_frame itself.)
take_paint_request :: proc(w: ^Window) -> bool {
	r := w.paint_requested
	w.paint_requested = false
	return r
}

pump_stats :: proc(w: ^Window) -> Pump_Stats { return w.stats }

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
	limit := int(win.GlobalSize(win.HGLOBAL(h))) / size_of(u16)   // another program's text may lack its terminating zero
	n := 0
	for n < limit && p[n] != 0 { n += 1 }
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
	if dst == nil {
		win.GlobalFree(win.HGLOBAL(mem))
		return
	}
	copy(dst[:len(wide)], wide)
	dst[len(wide)] = 0
	win.GlobalUnlock(win.HGLOBAL(mem))
	// the system owns the block once SetClipboardData succeeds; if it fails the block is still ours
	if win.SetClipboardData(win.CF_UNICODETEXT, win.HANDLE(mem)) == nil { win.GlobalFree(win.HGLOBAL(mem)) }
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
	name := win.utf8_to_wstring("APPDATA", context.temp_allocator)
	buf: [win.MAX_PATH]u16
	n := win.GetEnvironmentVariableW(name, &buf[0], len(buf))
	if n == 0 { return "" }
	wide := buf[:]
	if int(n) >= len(buf) {
		// longer than MAX_PATH: n is the size needed, with the terminating zero
		wide = make([]u16, n, context.temp_allocator)
		n = win.GetEnvironmentVariableW(name, &wide[0], u32(len(wide)))
		if n == 0 || int(n) >= len(wide) { return "" }
	}
	s, _ := win.utf16_to_utf8(wide[:n], allocator)
	return s
}

////////////////////////////////
// internals

@(private)
hit_code :: proc(h: Hit) -> win.LRESULT {
	switch h {
	case .Client:       return win.HTCLIENT
	case .Caption:      return win.HTCAPTION
	case .Minimize:     return win.HTMINBUTTON
	case .Maximize:     return win.HTMAXBUTTON
	case .Close:        return win.HTCLOSE
	case .Left:         return win.HTLEFT
	case .Right:        return win.HTRIGHT
	case .Top:          return win.HTTOP
	case .Bottom:       return win.HTBOTTOM
	case .Top_Left:     return win.HTTOPLEFT
	case .Top_Right:    return win.HTTOPRIGHT
	case .Bottom_Left:  return win.HTBOTTOMLEFT
	case .Bottom_Right: return win.HTBOTTOMRIGHT
	}
	return win.HTCLIENT
}

@(private)
is_caption_button :: proc(ht: win.WPARAM) -> bool { return ht == win.HTMINBUTTON || ht == win.HTMAXBUTTON || ht == win.HTCLOSE }

// A maximized window covering a monitor whose taskbar hides itself would hide it for good (the system takes such a
// window for a full screen one): leave 2 px along the taskbar's edge so that it comes up when the pointer reaches it.
@(private)
autohide_taskbar_insets :: proc(hwnd: win.HWND, r: ^win.RECT) {
	ABM_GETAUTOHIDEBAREX :: 0x0000000b
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(win.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST), &mi) { return }
	if mi.rcWork != mi.rcMonitor { return }   // a taskbar that stays up already reserves its space
	for edge in u32(0) ..= 3 {   // ABE_LEFT, ABE_TOP, ABE_RIGHT, ABE_BOTTOM
		abd := win.APPBARDATA{cbSize = size_of(win.APPBARDATA), uEdge = edge, rc = mi.rcMonitor}
		if win.SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &abd) == 0 { continue }
		switch edge {
		case 0: r.left += 2
		case 1: r.top += 2
		case 2: r.right -= 2
		case 3: r.bottom -= 2
		}
	}
}

// What the pointer is over: -1 when it is not over this window (another window, or outside), else the hit test code.
@(private)
pointer_hit :: proc(w: ^Window) -> win.LRESULT {
	pt: win.POINT
	if !win.GetCursorPos(&pt) || win.WindowFromPoint(pt) != w.hwnd { return -1 }
	return win.SendMessageW(w.hwnd, win.WM_NCHITTEST, 0, win.LPARAM(uintptr(u32(u16(i16(pt.x))) | u32(u16(i16(pt.y))) << 16)))
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
	case win.VK_APPS:    return .Menu
	case win.VK_ADD:     return .Num_Add
	case win.VK_SUBTRACT: return .Num_Subtract
	case win.VK_NUMPAD0..=win.VK_NUMPAD9: return Key(int(Key.N0) + int(vk - win.VK_NUMPAD0))
	}
	return .None
}

@(private)
button_down :: proc(w: ^Window, b: Mouse_Button, pos: [2]f32) {
	if win.GetCapture() != w.hwnd { win.SetCapture(w.hwnd) }
	w.buttons_down += {b}
	append(&w.events, Event{kind = .Mouse_Press, button = b, pos = pos, mods = current_mods(), stamp = time.tick_now(), buttons = w.buttons_down, emulated = mouse_emulated(), pointer = mouse_emulated_by()})
}

@(private)
button_up :: proc(w: ^Window, b: Mouse_Button, pos: [2]f32) {
	w.buttons_down -= {b}
	if w.buttons_down == {} { win.ReleaseCapture() }
	append(&w.events, Event{kind = .Mouse_Release, button = b, pos = pos, mods = current_mods(), stamp = time.tick_now(), buttons = w.buttons_down, emulated = mouse_emulated(), pointer = mouse_emulated_by()})
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
	if msg == A11Y_MESSAGE {   // an assistive technology asked for the tree or for an action: the loop makes a frame
		append(&w.events, Event{kind = .Accessibility, stamp = time.tick_now()})
		return 0
	}
	if msg >= win.WM_APP && tray_window_message(w, msg, wparam, lparam) { return 0 }   // (TaskbarCreated is >= 0xC000)

	push :: proc(w: ^Window, e: Event) {
		e := e
		e.stamp = time.tick_now()
		append(&w.events, e)
	}
	mouse_pos :: proc(lparam: win.LPARAM) -> [2]f32 {
		return {f32(win.GET_X_LPARAM(lparam)), f32(win.GET_Y_LPARAM(lparam))}
	}
	screen_to_client :: proc(hwnd: win.HWND, lparam: win.LPARAM) -> [2]f32 {
		pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
		win.ScreenToClient(hwnd, &pt)
		return {f32(pt.x), f32(pt.y)}
	}

	switch msg {
	case win.WM_CLOSE:
		w.closed = true
		push(w, {kind = .Close})
		return 0

	case win.WM_DESTROY:
		return 0

	case win.WM_CLIPBOARDUPDATE:
		return 0   // (the message woke the loop; clipboard_changed reads the sequence number)

	case win.WM_SETFOCUS:  w.focused = true; a11y_window_focus(w, true)
	case win.WM_KILLFOCUS: w.focused = false; a11y_window_focus(w, false)

	case win.WM_GETOBJECT:
		if r, ok := a11y_wm_getobject(w, wparam, lparam); ok { return r }

	case win.WM_ACTIVATE:
		active := win.LOWORD(u32(wparam)) != win.WA_INACTIVE
		if active != w.active { w.active = active; push(w, {kind = .Activate}) }

	case win.WM_NCACTIVATE:
		// lParam -1: no repaint of a frame the client area covers (it would flash the system's title bar)
		if w.integrated && !w.fullscreen { return win.DefWindowProcW(hwnd, msg, wparam, -1) }

	case win.WM_NCCALCSIZE:
		// the client area takes the whole window but the system's frame on the left, right and bottom (invisible
		// resize borders and the shadow, as with the system's title bar); the top resize band is inside it (WM_NCHITTEST)
		if w.integrated && !w.fullscreen && wparam != 0 {
			params := cast(^win.NCCALCSIZE_PARAMS)uintptr(lparam)
			top := params.rgrc[0].top
			if r := win.DefWindowProcW(hwnd, msg, wparam, lparam); r != 0 { return r }
			params.rgrc[0].top = top
			if win.IsZoomed(hwnd) {
				// a maximized window hangs over its monitor by its frame: the client area starts at the monitor's top
				params.rgrc[0].top += i32(resize_border(w))
				autohide_taskbar_insets(hwnd, &params.rgrc[0])
			}
			return 0
		}

	case win.WM_NCHITTEST:
		if w.integrated && !w.fullscreen {
			// the system's answer for its own frame (left, right, bottom borders and corners); the rest is the app's
			if r := win.DefWindowProcW(hwnd, msg, wparam, lparam); r != win.HTCLIENT { return r }
			pt := win.POINT{win.GET_X_LPARAM(lparam), win.GET_Y_LPARAM(lparam)}
			win.ScreenToClient(hwnd, &pt)
			border := f32(resize_border(w))
			sides: Sides = win.IsZoomed(hwnd) ? {} : {.Top}
			return hit_code(hit_test_chrome(&w.chrome, {f32(pt.x), f32(pt.y)}, {f32(w.size.x), f32(w.size.y)}, border, border * 2, sides))
		}

	// Over the title bar the pointer is in the non-client area: its moves become the app's (hover of the caption
	// buttons, hover cleared over the caption); a press on a caption button is the app's widget's (captured: the release
	// comes as WM_LBUTTONUP), never the system's (it would draw its own buttons over the app's).
	case win.WM_NCMOUSEMOVE:
		if w.integrated && !w.fullscreen {
			if !w.nc_tracking {
				tme := win.TRACKMOUSEEVENT{cbSize = size_of(win.TRACKMOUSEEVENT), dwFlags = win.TME_LEAVE | win.TME_NONCLIENT, hwndTrack = hwnd}
				win.TrackMouseEvent(&tme)
				w.nc_tracking = true
			}
			push(w, {kind = .Mouse_Move, pos = screen_to_client(hwnd, lparam), mods = current_mods()})
			if is_caption_button(wparam) { return 0 }
		}
	case win.WM_NCMOUSELEAVE:
		w.nc_tracking = false
		if w.integrated && pointer_hit(w) != win.HTCLIENT { push(w, {kind = .Mouse_Leave}) }
	case win.WM_NCLBUTTONDOWN, win.WM_NCLBUTTONDBLCLK:
		if w.integrated && is_caption_button(wparam) {
			button_down(w, .Left, screen_to_client(hwnd, lparam))
			return 0
		}
	case win.WM_NCLBUTTONUP, win.WM_NCRBUTTONDOWN, win.WM_NCRBUTTONUP, win.WM_NCRBUTTONDBLCLK:
		if w.integrated && is_caption_button(wparam) { return 0 }

	case win.WM_SETCURSOR:
		// over the client area the app's cursor (cursors_win32.odin); elsewhere (resize bands, the caption of an
		// integrated title bar, the system's frame) the system's
		if win.HWND(wparam) == hwnd && win.LOWORD(u32(lparam)) == win.HTCLIENT {
			cursor_on_setcursor(w)
			return 1
		}

	case win.WM_SETTINGCHANGE:
		if wparam == win.SPI_SETCURSORS {   // another pointer size or scheme: drawn cursors are made again
			cursor_settings_changed()
			cursor_on_dpi_change(w)
		}

	case win.WM_GETMINMAXINFO:
		mmi := cast(^win.MINMAXINFO)uintptr(lparam)
		mmi.ptMinTrackSize = {i32(320 * w.dpi_scale), i32(240 * w.dpi_scale)}
		return 0

	case win.WM_DISPLAYCHANGE:
		w.display_stale = true   // a mode (resolution, refresh rate) or the monitor layout changed

	case win.WM_ENTERSIZEMOVE, win.WM_ENTERMENULOOP:
		// (size_move.odin: another program's drag tool sends WM_ENTERSIZEMOVE with no loop of the system behind it)
		counted := true
		if msg == win.WM_ENTERSIZEMOVE {
			w.sizemove, counted = size_move_step(w.sizemove, .Enter, w.in_def_proc > 0)
			if !counted { w.stats.ignored_size_moves += 1 }
		}
		if counted {
			w.modal += 1
			w.stats.modal_loops += 1
			// a move without a resize, or a menu, makes no WM_PAINT of its own (the compositor moves the window): a timer
			// asks for a repaint, which the loop of the system delivers, so that animations, video and the caret go on
			if w.modal == 1 { win.SetTimer(hwnd, TIMER_MODAL_FRAME, MODAL_FRAME_MS, nil) }
		}
	case win.WM_EXITSIZEMOVE, win.WM_EXITMENULOOP:
		counted := true
		if msg == win.WM_EXITSIZEMOVE {
			w.sizemove, counted = size_move_step(w.sizemove, .Exit, w.in_def_proc > 0)
			if !counted { w.stats.ignored_size_moves += 1 }
		}
		if counted {
			w.modal = max(w.modal - 1, 0)
			if w.modal == 0 { win.KillTimer(hwnd, TIMER_MODAL_FRAME) }
		}
		w.display_stale = true   // a move may have landed on another monitor (also one made by another program)

	case win.WM_TIMER:
		if wparam == TIMER_MODAL_FRAME {
			if w.modal > 0 { win.InvalidateRect(hwnd, nil, false) } else { win.KillTimer(hwnd, TIMER_MODAL_FRAME) }
			return 0
		}

	case win.WM_CAPTURECHANGED:
		// the capture went elsewhere (Alt+Tab, a dialog, another window grabbed it) with a button down: the release
		// will not come to this window, so it is made here, or the widget under the press stays pressed for good
		// (lParam: the window that took it; this window taking it again for a second button is no loss)
		if w.buttons_down != {} && win.HWND(uintptr(lparam)) != hwnd {
			pt: win.POINT
			win.GetCursorPos(&pt)
			win.ScreenToClient(hwnd, &pt)
			down := w.buttons_down
			w.buttons_down = {}
			for b in down { push(w, {kind = .Mouse_Release, button = b, pos = {f32(pt.x), f32(pt.y)}, mods = current_mods()}) }
		}

	case win.WM_DPICHANGED:
		w.display_stale = true
		w.dpi_scale = f32(win.HIWORD(u32(wparam))) / 96
		r := cast(^win.RECT)uintptr(lparam)
		win.SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, win.SWP_NOZORDER | win.SWP_NOACTIVATE)
		cursor_on_dpi_change(w)   // drawn cursors at the new monitor's size
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
		// from the app's own poll the frame being built repaints anyway: a nested one would present twice in one turn
		// and wait twice for the swap chain. Only a loop of the system (live resize, menu) needs the frame from here.
		// That goes for every window of the thread: the poll of one pumps the messages of the others (a window that is
		// not polled, such as a detached panel, takes its repaint from take_paint_request).
		if (w.in_poll || pumping > 0) && w.modal == 0 { w.paint_requested = true; return 0 }
		if w.on_frame != nil && w.size.x > 0 && w.size.y > 0 { w.stats.paint_frames += 1; w.on_frame(w.user) }
		return 0

	case win.WM_KEYDOWN, win.WM_SYSKEYDOWN:
		key := key_from_vk(wparam)
		if key != .None { push(w, {kind = .Key_Press, key = key, mods = current_mods(), repeat = (lparam & (1 << 30)) != 0}) }
		// no menu-bar beep on Alt+key; Alt+F4 closes, Alt+Space opens the system menu
		if msg == win.WM_SYSKEYDOWN && key != .None && wparam != win.VK_F4 && wparam != win.VK_SPACE { return 0 }
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
		push(w, {kind = .Mouse_Move, pos = mouse_pos(lparam), mods = current_mods(), buttons = w.buttons_down, emulated = mouse_emulated(), pointer = mouse_emulated_by()})
	case win.WM_MOUSELEAVE:
		w.tracking_mouse = false
		// into the app's own title bar or frame: WM_NCMOUSEMOVE goes on with the moves
		if !(w.integrated && pointer_hit(w) >= 0) { push(w, {kind = .Mouse_Leave}) }

	// the mouse is captured from the first button down to the last one up: releasing it at the first release would
	// lose the release of the others when it happens outside the window
	case win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK: button_down(w, .Left, mouse_pos(lparam))
	case win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK: button_down(w, .Right, mouse_pos(lparam))
	case win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK: button_down(w, .Middle, mouse_pos(lparam))
	case win.WM_LBUTTONUP: button_up(w, .Left, mouse_pos(lparam))
	case win.WM_RBUTTONUP: button_up(w, .Right, mouse_pos(lparam))
	case win.WM_MBUTTONUP: button_up(w, .Middle, mouse_pos(lparam))

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

	// fingers and pens: their own events, then the system's mouse emulation (DefWindowProc) as before
	case win.WM_POINTERDOWN, win.WM_POINTERUPDATE, win.WM_POINTERUP, win.WM_POINTERCAPTURECHANGED:
		pointer_message(w, msg, wparam)
	}
	// the system's move / size loop (and its WM_ENTERSIZEMOVE) runs inside this call: size_move.odin
	w.in_def_proc += 1
	defer w.in_def_proc -= 1
	return win.DefWindowProcW(hwnd, msg, wparam, lparam)
}
