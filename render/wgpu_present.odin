package render

import "core:fmt"
import "core:time"
import win "core:sys/windows"
import "vendor:wgpu"

// WebGPU backend: presentation. wgpu-native exposes neither the swap chain's frame latency object nor its frame
// statistics, so what Direct3D 11 got from DXGI is rebuilt from the compositor's timing (DwmGetCompositionTimingInfo).
//
// The frame latency object: DXGI's is released when the frame presented before has reached the screen (at most one frame
// is queued). wgpu waits on it inside SurfaceGetCurrentTexture, but the app has to wait for that moment *before* it reads
// input (platform.wait_handle takes the window's input meanwhile), so `frame_waitable` is a waitable timer set after each
// present to the vblank that shows it (at once when presenting with tearing). It only wakes the app: if it is early,
// SurfaceGetCurrentTexture still waits for the real object. (An acquire made ahead of time by a helper thread was
// the first design: a texture acquired and never presented loses its slot for good, and the next acquire after a
// reconfigure then waited out wgpu's 1 s timeout.)
//
// The frame statistics: a frame is "shown" at the first vblank after its present returned; vblanks come from the
// compositor's timing (the refresh counter and the time of the last one). The frames the screen did not take (missed refreshes)
// are the ones the app presented late; a frame the GPU finished late is not seen.

Wgpu_Latency :: struct {
	timer:      win.HANDLE,   // the frame latency object (frame_waitable)
	have_dwm:   bool,
	last_index: u64,          // the vblank the previous frame was shown at (compositor's refresh counter)
	have_index: bool,
	lag_ns:     f64,          // how much later than the next vblank the swap chain really takes a new frame (learned from the acquires that had to wait)
	armed_at:   time.Tick,    // when the latency object was last set (the acquire that follows measures its lag against it)
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

@(private)
wgpu_frame_latency :: proc(r: ^Renderer) -> u32 {
	when LOW_LATENCY { return 1 } else { return 3 }
}

@(private)
wgpu_latency_start :: proc(r: ^Renderer) {
	l := &r.wg.latency
	when !LOW_LATENCY { return }
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

// The frame latency object (nil without LOW_LATENCY or offscreen).
@(private)
wgpu_waitable :: proc(r: ^Renderer) -> rawptr { return rawptr(r.wg.latency.timer) }

@(private)
wgpu_acquire :: proc(r: ^Renderer) -> wgpu.SurfaceTexture {
	t0 := time.tick_now()
	st := wgpu.SurfaceGetCurrentTexture(r.wg.surface)
	r.wg.cpu.acquire += time.duration_milliseconds(time.tick_since(t0))
	// the texture came waited after the call: if that is long, the latency object was set too early (the app read its input
	// and then waited for the swap chain): set it later next time; if it came at once, try a little earlier
	l := &r.wg.latency
	if l.timer != nil && (st.status == .SuccessOptimal || st.status == .SuccessSuboptimal) {
		waited := f64(time.tick_since(t0))
		// (bounded: a long wait is a first frame or a hiccup, not a miscalibration; fades quickly)
		if waited > 300_000 { l.lag_ns = min(l.lag_ns + 0.5 * waited, 3e6) } else { l.lag_ns *= 0.9 }
	}
	return st
}

// wait_for_frame: the frame latency object, then the texture of the frame (which waits for the real object).
@(private)
wgpu_wait_frame :: proc(r: ^Renderer, timeout_ms: int) -> bool {
	l := &r.wg.latency
	if l.timer != nil && win.WaitForSingleObject(l.timer, u32(max(timeout_ms, 0))) != win.WAIT_OBJECT_0 { return false }
	return wgpu_ensure_frame(r)
}

// Whether the surface can present with tearing (asked once per configure), then the mode the present mode setting asks for.
@(private)
wgpu_query_tearing :: proc(r: ^Renderer) {
	g := &r.wg
	caps, st := wgpu.SurfaceGetCapabilities(g.surface, g.adapter)
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
	r.present.tearing_ok = false
	if st == .Success {
		for i in 0 ..< caps.presentModeCount {
			if caps.presentModes[i] == .Immediate { r.present.tearing_ok = true }
		}
		if wgpu_trace() { fmt.eprintfln("wgpu: surface present modes %v, formats %v, alpha %v", caps.presentModes[:caps.presentModeCount], caps.formats[:caps.formatCount], caps.alphaModes[:caps.alphaModeCount]) }
	}
}

@(private)
wgpu_pick_present_mode :: proc(r: ^Renderer) -> wgpu.PresentMode {
	if r.present.mode == .Tearing && r.present.tearing_ok { return .Immediate }
	return .Fifo
}

@(private)
wgpu_frame_end :: proc(r: ^Renderer, vsync := true) {
	g := &r.wg
	if g.shared != nil && g.shared.lost { r.lost = true }
	if g.surface == nil {   // offscreen
		if g.clear_pending { wgpu_clear_frame(r) }
		return
	}
	if !g.frame_acquired { return }
	if g.clear_pending { wgpu_clear_frame(r) }
	t_pre := time.tick_now()
	ps := profile_present_begin(r)
	wgpu.SurfacePresent(g.surface)
	profile_present_end(r, ps)
	now := time.tick_now()
	if wgpu_trace() {
		c := &g.cpu
		c.present += time.duration_milliseconds(time.tick_diff(t_pre, now))
		c.frames += 1
		if time.tick_diff(c.since, now) > time.Second {
			if c.frames > 0 && c.since._nsec != 0 {
				n := f64(c.frames)
				fmt.eprintfln("wgpu: cpu per frame over %d frames: frame_begin %.3f ms, build tables %.3f, encode %.3f, QueueSubmit %.3f, acquire %.3f, SurfacePresent %.3f", c.frames, c.begin / n, c.upload / n, c.encode / n, c.submit / n, c.acquire / n, c.present / n)
			}
			c^ = {since = now}
		}
	}
	wgpu_drop_frame(r)
	wgpu_present_done(r, now, vsync)
}

// A frame was presented at `now`: arm the latency object, note when it will be on screen.
@(private)
wgpu_present_done :: proc(r: ^Renderer, now: time.Tick, vsync: bool) {
	p := &r.present
	l := &r.wg.latency
	p.presents += 1
	if p.interval == 0 { p.interval = 1 }
	tearing := present_mode(r) == .Tearing
	sync: u32 = vsync && !tearing ? p.interval : 0
	// the compositor's timing: the last vblank (QPC, refresh counter) and the period
	info := DWM_TIMING_INFO{cbSize = size_of(DWM_TIMING_INFO)}
	ok := win.SUCCEEDED(DwmGetCompositionTimingInfo(nil, &info)) && info.qpcRefreshPeriod > 0
	if ok {
		p.stats_ok = true
		freq: win.LARGE_INTEGER
		win.QueryPerformanceFrequency(&freq)
		p.period_ns = f64(info.qpcRefreshPeriod) * 1e9 / f64(freq)
		p.sync_tick = qpc_to_tick(i64(info.qpcVBlank))
		p.sync_count = u32(info.cRefresh)
	}
	shown := now
	index: u64
	if ok && sync > 0 && p.period_ns > 0 {
		// the first vblank after the present (a little margin for the GPU), then `interval - 1` more of them
		since := f64(time.tick_diff(p.sync_tick, now)) + 500_000
		k := since <= 0 ? 0 : u64(since / p.period_ns) + 1
		shown._nsec = p.sync_tick._nsec + i64(f64(k + u64(sync - 1)) * p.period_ns)
		index = info.cRefresh + k + u64(sync - 1)
	} else if ok {
		index = info.cRefresh + u64(max(f64(time.tick_diff(p.sync_tick, now)), 0) / max(p.period_ns, 1))
	}
	// the latency object: the screen has taken the frame when it reaches that vblank (plus the lag learned so far)
	wgpu_latency_arm(r, sync > 0 ? max(i64(time.tick_diff(now, shown) + time.Duration(l.lag_ns)) - 200_000, 0) : 0)
	if sync > 0 && l.lag_ns >= 0.5 * p.period_ns { shown._nsec += i64(l.lag_ns / p.period_ns + 0.5) * i64(p.period_ns) }
	if wgpu_trace() { fmt.eprintfln("wgpu: present done: shown in %.2f ms, interval %d, lag %.2f ms, period %.2f ms, dwm ok %v", f64(time.tick_diff(now, shown)) / 1e6, sync, l.lag_ns / 1e6, p.period_ns / 1e6, ok) }
	d := Displayed_Frame{present = u32(p.presents), input = p.input, presented = now, shown = shown}
	if ok && sync > 0 && l.have_index && index > l.last_index && index - l.last_index < 240 && p.continuous {
		d.refreshes = u32(index - l.last_index)
		allowed := u32(p.expected > 0 ? p.expected + 0.999999 : f64(sync))
		if d.refreshes > max(allowed, 1) { d.missed = d.refreshes - max(allowed, 1) }
	}
	l.last_index, l.have_index = index, ok && sync > 0
	p.displayed += 1
	p.missed += u64(d.missed)
	p.input = {}
	if len(p.out) >= 4 * PRESENT_RING { clear(&p.out) }
	append(&p.out, d)
	when RENDER_PROBE { present_probe(r, now) }
}
