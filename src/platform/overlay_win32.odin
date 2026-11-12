#+build windows
package platform

// Overlay windows on Windows (overlay.odin): a WS_POPUP window over one monitor, topmost, a tool window (in no task bar,
// not in Alt+Tab), not activated when shown nor when clicked (WS_EX_NOACTIVATE: button_down takes the keyboard itself),
// with no redirection bitmap (the renderer's composition swap chain blends its alpha). The input region is a window
// region (SetWindowRgn): the pointer reaches the window only inside it, and the system draws only inside it too.

import win "core:sys/windows"

foreign import overlay_user32 "system:User32.lib"
foreign import overlay_gdi32 "system:Gdi32.lib"

@(default_calling_convention = "system", private = "file")
foreign overlay_user32 {
	SetWindowRgn :: proc(hwnd: win.HWND, rgn: win.HRGN, redraw: win.BOOL) -> i32 ---
}

@(default_calling_convention = "system", private = "file")
foreign overlay_gdi32 {
	CreateRectRgn :: proc(left, top, right, bottom: i32) -> win.HRGN ---
	CombineRgn :: proc(dest, src1, src2: win.HRGN, mode: i32) -> i32 ---
	DeleteObject :: proc(object: win.HGDIOBJ) -> win.BOOL ---
}

@(private = "file") RGN_OR :: 2
@(private = "file") MONITORS_MAX :: 32

@(private = "file")
Monitor_List :: struct {
	handles: [MONITORS_MAX]win.HMONITOR,
	count:   int,
}

// An overlay window over the monitor at `area` (overlay.odin), shown at once without taking the keyboard. nil when the
// system could not make the window.
open_overlay :: proc(title: string, area: [4]int, user: rawptr = nil, on_frame: proc(user: rawptr) = nil) -> ^Window {
	instance := window_class_register()
	place := overlay_monitor_place(area)

	w := new(Window)
	w.user = user
	w.on_frame = on_frame
	w.dpi_scale = 1
	w.display_stale = true
	w.overlay = true
	EX_STYLE :: win.WS_EX_TOPMOST | win.WS_EX_TOOLWINDOW | win.WS_EX_NOACTIVATE | win.WS_EX_NOREDIRECTIONBITMAP
	wtitle := win.utf8_to_wstring(title, context.temp_allocator)
	w.hwnd = win.CreateWindowExW(EX_STYLE, win.L(WINDOW_CLASS_NAME), wtitle, win.WS_POPUP,
		i32(place[0]), i32(place[1]), i32(max(place[2], 1)), i32(max(place[3], 1)), nil, nil, instance, w)
	if w.hwnd == nil {
		free(w)
		return nil
	}
	dpi := win.GetDpiForWindow(w.hwnd)
	w.dpi_scale = dpi > 0 ? f32(dpi) / DPI_BASE : 1
	update_client_size(w)
	a11y_attach(w)   // (before the window is shown, as open_window)
	win.ShowWindow(w.hwnd, win.SW_SHOWNOACTIVATE)
	return w
}

// Only `rects` (window-relative logical pixels) take the pointer: the window's region. Empty: no part of it does.
// The region also clips what is drawn.
set_input_region :: proc(w: ^Window, rects: [][4]int) {
	if w == nil || w.offscreen || w.hwnd == nil { return }
	region := CreateRectRgn(0, 0, 0, 0)
	if region == nil { return }
	for r in overlay_input_rects_px(rects, w.dpi_scale) {
		part := CreateRectRgn(i32(r[0]), i32(r[1]), i32(r[0] + r[2]), i32(r[1] + r[3]))
		if part == nil { continue }
		CombineRgn(region, region, part, RGN_OR)
		DeleteObject(win.HGDIOBJ(part))
	}
	// (the system owns the region once it is set: it is not deleted here)
	if SetWindowRgn(w.hwnd, region, true) == 0 { DeleteObject(win.HGDIOBJ(region)) }
}

// The whole window takes the pointer again.
clear_input_region :: proc(w: ^Window) {
	if w == nil || w.offscreen || w.hwnd == nil { return }
	SetWindowRgn(w.hwnd, nil, true)
}

// Whether the window is an overlay (open_overlay).
is_overlay :: proc(w: ^Window) -> bool { return w != nil && w.overlay }

// The physical rect of the monitor whose logical place (as gt:capture gives it) is `area`; the primary monitor's when
// none is (or `area` is all zero).
@(private = "file")
overlay_monitor_place :: proc(area: [4]int) -> [4]int {
	list: Monitor_List
	win.EnumDisplayMonitors(nil, nil, proc "system" (monitor: win.HMONITOR, _: win.HDC, _: win.LPRECT, data: win.LPARAM) -> win.BOOL {
		l := (^Monitor_List)(uintptr(data))
		if l.count < len(l.handles) {
			l.handles[l.count] = monitor
			l.count += 1
		}
		return true
	}, win.LPARAM(uintptr(&list)))
	physical := make([dynamic][4]int, 0, list.count, context.temp_allocator)
	scales := make([dynamic]f32, 0, list.count, context.temp_allocator)
	for handle in list.handles[:list.count] {
		mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
		if !win.GetMonitorInfoW(handle, &mi) { continue }
		r := mi.rcMonitor
		append(&physical, [4]int{int(r.left), int(r.top), int(r.right - r.left), int(r.bottom - r.top)})
		x, y: u32
		scale := f32(1)
		if win.GetDpiForMonitor(handle, .MDT_EFFECTIVE_DPI, &x, &y) >= 0 && x > 0 { scale = f32(x) / DPI_BASE }
		append(&scales, scale)
	}
	if i := overlay_output_index(desktop_logical_places(physical[:], scales[:]), area); i >= 0 { return physical[i] }
	primary := win.MonitorFromPoint({0, 0}, .MONITOR_DEFAULTTOPRIMARY)
	mi := win.MONITORINFO{cbSize = size_of(win.MONITORINFO)}
	if !win.GetMonitorInfoW(primary, &mi) { return {0, 0, 1, 1} }
	r := mi.rcMonitor
	return {int(r.left), int(r.top), int(r.right - r.left), int(r.bottom - r.top)}
}
