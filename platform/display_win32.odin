#+build windows
package platform

import "core:time"
import win "core:sys/windows"

// Refresh rate of the monitor a window is on, and a wait on a handle that keeps taking the window's input.
//
// The rate comes from the display configuration (QueryDisplayConfig: the exact rational rate of the path that drives the
// window's monitor, 59.94 or 143.998 rather than 60 or 144), else from the monitor's current mode (EnumDisplaySettings,
// whole hertz), else from DWM's composition rate, else 60. It is read again only when it may have changed: the display
// settings changed (WM_DISPLAYCHANGE), the DPI changed or the window moved to another monitor.

foreign import user32_display "system:User32.lib"
foreign import dwmapi_display "system:Dwmapi.lib"

@(private = "file")
DISPLAYCONFIG_RATIONAL :: struct { numerator, denominator: u32 }

@(private = "file")
DISPLAYCONFIG_PATH_INFO :: struct {
	// source
	source_adapter: win.LUID,
	source_id:      u32,
	source_mode:    u32,
	source_flags:   u32,
	// target
	target_adapter: win.LUID,
	target_id:      u32,
	target_mode:    u32,
	technology:     u32,
	rotation:       u32,
	scaling:        u32,
	refresh:        DISPLAYCONFIG_RATIONAL,
	scan_line:      u32,
	available:      win.BOOL,
	target_flags:   u32,
	flags:          u32,
}
#assert(size_of(DISPLAYCONFIG_PATH_INFO) == 72)

@(private = "file")
DISPLAYCONFIG_MODE_INFO :: struct {
	info_type: u32,   // 1 source, 2 target, 3 desktop image
	id:        u32,
	adapter:   win.LUID,
	using _: struct #raw_union {
		raw: [48]u8,
		target: struct {   // DISPLAYCONFIG_VIDEO_SIGNAL_INFO
			pixel_rate: u64,
			hsync, vsync: DISPLAYCONFIG_RATIONAL,
		},
	},
}
#assert(size_of(DISPLAYCONFIG_MODE_INFO) == 64)

@(private = "file")
DISPLAYCONFIG_SOURCE_DEVICE_NAME :: struct {
	type, size: u32,
	adapter:    win.LUID,
	id:         u32,
	gdi_name:   [32]u16,
}

@(private = "file") QDC_ONLY_ACTIVE_PATHS :: 0x2
@(private = "file") DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME :: 1
@(private = "file") DISPLAYCONFIG_PATH_MODE_IDX_INVALID :: 0xffffffff

// DWM_TIMING_INFO (dwmapi.h, packed): only the rate is read here.
@(private)
DWM_TIMING_INFO :: struct #packed {
	cbSize: u32,
	rateRefresh: [2]u32, qpcRefreshPeriod: u64, rateCompose: [2]u32, qpcVBlank: u64, cRefresh: u64,
	cDXRefresh: u32, qpcCompose: u64, cFrame: u64, cDXPresent: u32, cRefreshFrame: u64, cFrameSubmitted: u64,
	cDXPresentSubmitted: u32, cFrameConfirmed: u64, cDXPresentConfirmed: u32, cRefreshConfirmed: u64,
	cDXRefreshConfirmed: u32, cFramesLate: u64, cFramesOutstanding: u32, cFrameDisplayed: u64, qpcFrameDisplayed: u64,
	cRefreshFrameDisplayed: u64, cFrameComplete: u64, qpcFrameComplete: u64, cFramePending: u64, qpcFramePending: u64,
	cFramesDisplayed: u64, cFramesComplete: u64, cFramesPending: u64, cFramesAvailable: u64, cFramesDropped: u64,
	cFramesMissed: u64, cRefreshNextDisplayed: u64, cRefreshNextPresented: u64, cRefreshesDisplayed: u64,
	cRefreshesPresented: u64, cRefreshStarted: u64, cPixelsReceived: u64, cPixelsDrawn: u64, cBuffersEmpty: u64,
}

@(default_calling_convention = "system", private = "file")
foreign user32_display {
	GetDisplayConfigBufferSizes :: proc(flags: u32, num_paths, num_modes: ^u32) -> i32 ---
	QueryDisplayConfig :: proc(flags: u32, num_paths: ^u32, paths: [^]DISPLAYCONFIG_PATH_INFO, num_modes: ^u32, modes: [^]DISPLAYCONFIG_MODE_INFO, topology: rawptr) -> i32 ---
	DisplayConfigGetDeviceInfo :: proc(packet: rawptr) -> i32 ---
	MsgWaitForMultipleObjectsEx :: proc(count: u32, handles: [^]win.HANDLE, ms: u32, wake_mask: u32, flags: u32) -> u32 ---
}

@(default_calling_convention = "system", private = "file")
foreign dwmapi_display {
	DwmGetCompositionTimingInfo :: proc(hwnd: win.HWND, info: ^DWM_TIMING_INFO) -> win.HRESULT ---
}

// The refresh rate of the window's monitor (cached: cheap to call every frame). `serial` changes when it does.
display_info :: proc(w: ^Window) -> Display_Info {
	if w.offscreen {
		// an emulated display: 60 Hz, no monitor. The headless browser paces its own frames; this only feeds the rate
		// a page reads (screen.refresh).
		if w.display.serial == 0 { w.display = {hz = 60, max_hz = 60, source = .Default, serial = 1} }
		return w.display
	}
	mon := win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST)
	if w.display_stale || rawptr(mon) != w.display.monitor {
		w.display_stale = false
		d := query_display(mon)
		if d.hz != w.display.hz || d.max_hz != w.display.max_hz || d.source != w.display.source || d.monitor != w.display.monitor {
			d.serial = w.display.serial + 1
			w.display = d
		}
	}
	return w.display
}

// Reads the rate again at the next display_info (e.g. after the user changed it in the display settings).
display_invalidate :: proc(w: ^Window) { w.display_stale = true }

@(private = "file")
query_display :: proc(mon: win.HMONITOR) -> (d: Display_Info) {
	d.monitor = rawptr(mon)
	mi: win.MONITORINFOEXW
	mi.cbSize = size_of(win.MONITORINFOEXW)
	if !win.GetMonitorInfoW(mon, (^win.MONITORINFO)(&mi)) {
		d = fallback_rate(d, nil)
		d.max_hz = d.hz
		return
	}
	if num, den, ok := display_config_rate(mi.szDevice[:]); ok {
		d.numerator, d.denominator, d.hz, d.source = num, den, f64(num) / f64(den), .Display_Config
	} else {
		d = fallback_rate(d, &mi.szDevice[0])
	}
	d.max_hz = max(d.hz, mode_max_rate(&mi.szDevice[0]))
	return
}

// The highest rate of the monitor's modes at its current size and orientation (EnumDisplaySettings: whole hertz). 0: unknown.
@(private = "file")
mode_max_rate :: proc(device: ^u16) -> (hz: f64) {
	cur := win.DEVMODEW{dmSize = size_of(win.DEVMODEW)}
	if !win.EnumDisplaySettingsW(win.wstring(device), win.ENUM_CURRENT_SETTINGS, &cur) { return 0 }
	for i in 0 ..< u32(4096) {
		dm := win.DEVMODEW{dmSize = size_of(win.DEVMODEW)}
		if !win.EnumDisplaySettingsW(win.wstring(device), i, &dm) { break }
		if dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmBitsPerPel == cur.dmBitsPerPel && dm.dmDisplayFrequency > 1 {
			hz = max(hz, f64(dm.dmDisplayFrequency))
		}
	}
	return
}

// The refresh rate the compositor says it runs at right now (DWM's `rateRefresh`): with a dynamic refresh rate it is the one
// sensor that moves with the screen (the mode and the display path say 60 Hz for good); read it repeatedly while the app moves
// and keep the highest. DWM answers for the PRIMARY monitor only, and only to a NULL window handle (with one the call fails
// with E_INVALIDARG): for a window on another monitor there is no answer (ok false; `render.measured_refresh_hz`, the swap
// chain's own statistics, is the window's). Its count of refreshes is no help: it counts the calls of the process.
display_live_hz :: proc(w: ^Window) -> (hz: f64, ok: bool) {
	if w.offscreen { return 0, false }
	if win.MonitorFromWindow(w.hwnd, .MONITOR_DEFAULTTONEAREST) != win.MonitorFromPoint({0, 0}, .MONITOR_DEFAULTTOPRIMARY) { return 0, false }
	ti := DWM_TIMING_INFO{cbSize = size_of(DWM_TIMING_INFO)}
	if win.FAILED(DwmGetCompositionTimingInfo(nil, &ti)) || ti.rateRefresh[0] == 0 || ti.rateRefresh[1] == 0 { return 0, false }
	return f64(ti.rateRefresh[0]) / f64(ti.rateRefresh[1]), true
}

@(private = "file")
fallback_rate :: proc(d: Display_Info, device: ^u16) -> Display_Info {
	d := d
	if device != nil {
		dm := win.DEVMODEW{dmSize = size_of(win.DEVMODEW)}
		if win.EnumDisplaySettingsW(win.wstring(device), win.ENUM_CURRENT_SETTINGS, &dm) && dm.dmDisplayFrequency > 1 {
			d.numerator, d.denominator, d.hz, d.source = u32(dm.dmDisplayFrequency), 1, f64(dm.dmDisplayFrequency), .Mode
			return d
		}
	}
	ti := DWM_TIMING_INFO{cbSize = size_of(DWM_TIMING_INFO)}
	if win.SUCCEEDED(DwmGetCompositionTimingInfo(nil, &ti)) && ti.rateRefresh[0] > 0 && ti.rateRefresh[1] > 0 {
		d.numerator, d.denominator, d.source = ti.rateRefresh[0], ti.rateRefresh[1], .Dwm
		d.hz = f64(d.numerator) / f64(d.denominator)
		return d
	}
	d.numerator, d.denominator, d.hz, d.source = 60, 1, 60, .Default
	return d
}

// The rate of the active path whose source is the GDI device `device` (\\.\DISPLAYn).
@(private = "file")
display_config_rate :: proc(device: []u16) -> (num, den: u32, ok: bool) {
	for attempt in 0 ..< 3 {
		np, nm: u32
		if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != 0 || np == 0 { return }
		paths := make([]DISPLAYCONFIG_PATH_INFO, np, context.temp_allocator)
		modes := make([]DISPLAYCONFIG_MODE_INFO, nm, context.temp_allocator)
		res := QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, raw_data(paths), &nm, raw_data(modes), nil)
		if res == 122 { continue }   // ERROR_INSUFFICIENT_BUFFER: the topology changed in between
		if res != 0 { return }
		_ = attempt
		for p in paths[:np] {
			name := DISPLAYCONFIG_SOURCE_DEVICE_NAME{type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, size = size_of(DISPLAYCONFIG_SOURCE_DEVICE_NAME), adapter = p.source_adapter, id = p.source_id}
			if DisplayConfigGetDeviceInfo(&name) != 0 || !wide_equal(name.gdi_name[:], device) { continue }
			r := p.refresh
			// the target mode's signal timing, when the path's rate is not filled in
			if (r.numerator == 0 || r.denominator == 0) && p.target_mode != DISPLAYCONFIG_PATH_MODE_IDX_INVALID && p.target_mode < nm && modes[p.target_mode].info_type == 2 {
				r = modes[p.target_mode].target.vsync
			}
			if r.numerator > 0 && r.denominator > 0 { return r.numerator, r.denominator, true }
		}
		return
	}
	return
}

@(private = "file")
wide_equal :: proc(a, b: []u16) -> bool {
	for i in 0 ..< max(len(a), len(b)) {
		x := i < len(a) ? a[i] : 0
		y := i < len(b) ? b[i] : 0
		if x != y { return false }
		if x == 0 { return true }
	}
	return true
}

// Waits until `handle` is signaled or `timeout_ms` passed (0: no limit), taking the window's keyboard and mouse
// messages as they arrive: they are time-stamped when they come (Event.stamp) and kept for the next poll_events. Other
// messages (paint, size, timers...) stay queued for poll_events. Returns true when the handle was signaled.
// For the swap chain's frame latency object (render.frame_waitable): the frame then starts on the fresh input.
wait_handle :: proc(w: ^Window, handle: rawptr, timeout_ms := 0) -> bool {
	if handle == nil { return true }
	if w.in_poll { return win.WaitForSingleObject(win.HANDLE(handle), timeout_ms > 0 ? u32(timeout_ms) : win.INFINITE) == win.WAIT_OBJECT_0 }
	w.in_poll = true   // a nested poll (a frame callback) takes nothing
	pumping += 1
	defer {
		w.in_poll = false
		pumping -= 1
	}
	if !w.keep_events { drop_returned(w) }
	w.keep_events = true
	start := time.tick_now()
	h := win.HANDLE(handle)
	QS_WAKE :: win.QS_KEY | win.QS_MOUSEMOVE | win.QS_MOUSEBUTTON
	MWMO_INPUTAVAILABLE :: 0x4
	flags := u32(MWMO_INPUTAVAILABLE)
	for {
		took := take_input(w)
		ms := u32(win.INFINITE)
		if timeout_ms > 0 {
			left := f64(timeout_ms) - time.duration_milliseconds(time.tick_since(start))
			if left <= 0 { return win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 }
			ms = u32(left + 0.999)
		}
		r := MsgWaitForMultipleObjectsEx(1, &h, ms, QS_WAKE, flags)
		switch r {
		case win.WAIT_OBJECT_0: return true
		case win.WAIT_OBJECT_0 + 1:
			// woken for input that is not ours to take (another window's filter): wait for new input only from now on
			if !took { flags = 0 }
		case:
			if r == win.WAIT_TIMEOUT { return false }
			return win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0   // WAIT_FAILED: give up waiting
		}
	}
}

// Keyboard and mouse messages of the thread: dispatched now (the window procedure stamps and queues them).
@(private = "file")
take_input :: proc(w: ^Window) -> (took: bool) {
	msg: win.MSG
	WM_MOUSE_LAST :: 0x020E   // WM_MOUSEHWHEEL
	for win.PeekMessageW(&msg, nil, win.WM_KEYFIRST, win.WM_KEYLAST, win.PM_REMOVE) || win.PeekMessageW(&msg, nil, win.WM_MOUSEFIRST, WM_MOUSE_LAST, win.PM_REMOVE) {
		took = true
		win.TranslateMessage(&msg)
		win.DispatchMessageW(&msg)
	}
	return
}
