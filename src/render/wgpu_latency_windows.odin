package render

import win "core:sys/windows"

// The frame latency object of the wgpu backend: a waitable timer (wgpu_present.odin says why), and the compositor's
// timing (DwmGetCompositionTimingInfo) that the frame statistics are built from.

@(private)
wgpu_latency_start :: proc(r: ^Renderer) {
	when !LOW_LATENCY { return }
	l := &r.wg.latency
	if r.wg.surface == nil || l.timer != nil { return }
	CREATE_WAITABLE_TIMER_HIGH_RESOLUTION :: 0x2
	l.timer = win.CreateWaitableTimerExW(nil, nil, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win.TIMER_ALL_ACCESS)
	if l.timer == nil { l.timer = win.CreateWaitableTimerExW(nil, nil, 0, win.TIMER_ALL_ACCESS) }
	wgpu_latency_arm(r, 0)   // nothing queued yet: the first frame is not held back
}

@(private)
wgpu_latency_stop :: proc(r: ^Renderer) {
	l := &r.wg.latency
	if l.timer != nil { win.CloseHandle(l.timer); l.timer = nil }
}

// Signals the frame latency object in `ns` nanoseconds (0: at once).
@(private)
wgpu_latency_arm :: proc(r: ^Renderer, ns: i64) {
	l := &r.wg.latency
	if l.timer == nil { return }
	due := win.LARGE_INTEGER(ns > 100 ? -(ns / 100) : -1)   // relative, in 100 ns units
	win.SetWaitableTimerEx(l.timer, &due, 0, nil, nil, nil, 0)
}

// Waits for the frame latency object, `timeout_ms` at most; false when it did not come.
@(private)
wgpu_latency_wait :: proc(r: ^Renderer, timeout_ms: int) -> bool {
	l := &r.wg.latency
	return l.timer == nil || win.WaitForSingleObject(l.timer, u32(max(timeout_ms, 0))) == win.WAIT_OBJECT_0
}

// The compositor's timing: the last vblank (QPC, refresh counter) and the period, into the present state; its refresh
// counter, and whether it was read. DWM does not say which frames of ours it showed (`counted` false): the present
// estimates it.
@(private)
wgpu_compositor_timing :: proc(r: ^Renderer) -> (refresh: u64, ok, counted: bool) {
	p := &r.present
	info := DWM_TIMING_INFO{cbSize = size_of(DWM_TIMING_INFO)}
	ok = hr_ok(DwmGetCompositionTimingInfo(nil, &info)) && info.qpcRefreshPeriod > 0
	p.stats_ok = ok
	if !ok { return }
	freq: win.LARGE_INTEGER
	win.QueryPerformanceFrequency(&freq)
	p.period_ns = f64(info.qpcRefreshPeriod) * 1e9 / f64(freq)
	p.sync_tick = qpc_to_tick(i64(info.qpcVBlank))
	p.sync_count = u32(info.cRefresh)
	return info.cRefresh, true, false
}

@(private)
DWM_TIMING_INFO :: struct #packed {   // the header packs it to 1 byte
	cbSize:                u32,
	rateRefresh:           [2]u32,   // numerator, denominator
	qpcRefreshPeriod:      u64,
	rateCompose:           [2]u32,
	qpcVBlank:             u64,
	cRefresh:              u64,
	cDXRefresh:            u32,
	qpcCompose:            u64,
	cFrame:                u64,
	cDXPresent:            u32,
	cRefreshFrame:         u64,
	cFrameSubmitted:       u64,
	cDXPresentSubmitted:   u32,
	cFrameConfirmed:       u64,
	cDXPresentConfirmed:   u32,
	cRefreshConfirmed:     u64,
	cDXRefreshConfirmed:   u32,
	cFramesLate:           u64,
	cFramesOutstanding:    u32,
	cFrameDisplayed:       u64,
	qpcFrameDisplayed:     u64,
	cRefreshFrameDisplayed: u64,
	cFrameComplete:        u64,
	qpcFrameComplete:      u64,
	cFramePending:         u64,
	qpcFramePending:       u64,
	cFramesDisplayed:      u64,
	cFramesComplete:       u64,
	cFramesPending:        u64,
	cFramesAvailable:      u64,
	cFramesDropped:        u64,
	cFramesMissed:         u64,
	cRefreshNextDisplayed: u64,
	cRefreshNextPresented: u64,
	cRefreshesDisplayed:   u64,
	cRefreshesPresented:   u64,
	cRefreshStarted:       u64,
	cPixelsReceived:       u64,
	cPixelsDrawn:          u64,
	cBuffersEmpty:         u64,
}

#assert(size_of(DWM_TIMING_INFO) == 292)

foreign import dwmapi_present "system:dwmapi.lib"
@(default_calling_convention = "system", private = "file")
foreign dwmapi_present {
	DwmGetCompositionTimingInfo :: proc(hwnd: win.HWND, info: ^DWM_TIMING_INFO) -> win.HRESULT ---
}
