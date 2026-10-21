package render

import "core:fmt"
import "core:math"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/dxgi"

// Presentation: how frames reach the screen and what became of them.
//
//   * set_present_mode: Vsync (each frame waits for a refresh, `sync_interval` refreshes per frame) or Tearing (shown at
//     once: on a variable refresh display (G-Sync, FreeSync) the refresh follows the frames, the app paces them itself).
//     Tearing needs the system's support (tearing_supported); without it frames are presented with vsync.
//   * frame_waitable: the swap chain's latency object, signaled when it can take the next frame (LOW_LATENCY: at most one
//     frame queued). Wait on it at the start of a frame, before reading input (platform.wait_handle takes input meanwhile).
//   * After each present the swap chain's frame statistics say which frame was on screen at which vblank: each frame
//     comes back once as a Displayed_Frame (take_displayed) with the time it reached the screen, the input it was built
//     from (set_frame_input / mark_input) and, in a continuous run of frames, the refreshes it came late for (`missed`).
//     The interval between vblanks is measured from them too (measured_refresh_hz).

Present_Mode :: enum u8 { Vsync, Tearing }

Displayed_Frame :: struct {
	present:   u32,         // the swap chain's present number
	input:     time.Tick,   // earliest input the frame was built from (zero: none given)
	presented: time.Tick,   // when Present returned
	shown:     time.Tick,   // the vblank it reached the screen at
	refreshes: u32,         // vblanks since the previous frame shown, in a continuous run (0: the run starts here)
	missed:    u32,         // of them, those the frame came late for (refreshes - sync interval, Vsync only)
}

@(private) PRESENT_RING :: 256

@(private)
Present_Slot :: struct {
	present:    u32,
	input:      time.Tick,
	presented:  time.Tick,
	continuous: bool,
	interval:   u32,
	expected:   f64,
	mode:       Present_Mode,
}

Present_State :: struct {
	mode:          Present_Mode,
	interval:      u32,                    // refreshes per frame with Vsync (1..4)
	expected:      f64,                    // refreshes per frame of app-timed frames (0: interval)
	tearing_ok:    bool,                   // the system can present with tearing
	ring:          [PRESENT_RING]Present_Slot,
	input:         time.Tick,              // set_frame_input for the next present
	continuous:    bool,                   // set_frame_continuous for the next present
	seen_present:  u32,                    // last present the statistics reported on screen
	seen_refresh:  u32,
	have_seen:     bool,
	sync_count:    u32,                    // last (vblank number, time) pair: the refresh period
	sync_tick:     time.Tick,
	period_ns:     f64,                    // measured vblank interval (0: not yet)
	stats_ok:      bool,                   // the swap chain answers GetFrameStatistics
	stats_fails:   int,
	out:           [dynamic]Displayed_Frame,
	presents, displayed, missed: u64,      // totals
	probe_tick:    time.Tick,
}

// Vsync (default) or Tearing (see the package comment). Tearing without system support stays Vsync.
set_present_mode :: proc(r: ^Renderer, mode: Present_Mode) { r.present.mode = mode }
present_mode :: proc(r: ^Renderer) -> Present_Mode { return r.present.mode == .Tearing && r.present.tearing_ok ? .Tearing : .Vsync }

// The system can present with tearing (Windows 10 1709+ with a driver that allows it): what variable refresh needs.
tearing_supported :: proc(r: ^Renderer) -> bool { return r.present.tearing_ok }

// Refreshes each frame stays on screen with Vsync: 1 = every refresh, 2 = every other one (half the rate)... up to 4.
set_sync_interval :: proc(r: ^Renderer, n: int) { r.present.interval = u32(clamp(n, 1, 4)) }

// Refreshes each frame is expected to stay on screen when the app times its frames itself (e.g. 1.33 for 45 frames per
// second on a 60 Hz display): a frame that stays longer missed refreshes. 0 = the sync interval.
set_expected_refreshes :: proc(r: ^Renderer, refreshes: f64) { r.present.expected = max(refreshes, 0) }

// The swap chain's frame latency object (nil without LOW_LATENCY or offscreen). Signaled when a frame can be queued.
frame_waitable :: proc(r: ^Renderer) -> rawptr { return rawptr(r.latency_handle) }

// The earliest input the next frame is built from (its event time): Displayed_Frame.input, for input latency.
set_frame_input :: proc(r: ^Renderer, t: time.Tick) { r.present.input = t }

// The next frame follows the previous one without a pause (an animation, scrolling): a refresh it misses is a missed
// frame. A frame after idle time is not continuous (nothing was due in between).
set_frame_continuous :: proc(r: ^Renderer, continuous: bool) { r.present.continuous = continuous }

// Frames that reached the screen since the last call (oldest first). The slice is valid until the next frame_end.
take_displayed :: proc(r: ^Renderer) -> []Displayed_Frame {
	out := r.present.out[:]
	clear(&r.present.out)
	return out
}

// Totals since the swap chain was made: frames presented, seen on screen, refreshes missed in continuous runs.
present_totals :: proc(r: ^Renderer) -> (presents, displayed, missed: u64) {
	return r.present.presents, r.present.displayed, r.present.missed
}

// The vblank interval measured from the frame statistics, as a rate (0: not measured yet).
measured_refresh_hz :: proc(r: ^Renderer) -> f64 { return r.present.period_ns > 0 ? 1e9 / r.present.period_ns : 0 }

// The last vblank a frame of ours was shown at, and the measured period: the grid frames land on (ok false: unknown).
vblank_grid :: proc(r: ^Renderer) -> (last: time.Tick, period_ns: f64, ok: bool) {
	if !r.present.stats_ok || r.present.period_ns <= 0 || r.present.sync_tick._nsec == 0 { return }
	return r.present.sync_tick, r.present.period_ns, true
}

// The QueryPerformanceCounter value `qpc` on core:time's tick scale (what time.tick_now returns on Windows).
qpc_to_tick :: proc(qpc: i64) -> time.Tick {
	@(static) freq: win.LARGE_INTEGER
	if freq == 0 { win.QueryPerformanceFrequency(&freq) }
	f := i64(freq)
	return time.Tick{_nsec = (qpc / f) * 1e9 + (qpc % f) * 1e9 / f}
}

// Whether tearing presents are possible on this system (IDXGIFactory5::CheckFeatureSupport).
@(private)
check_tearing :: proc(factory: ^dxgi.IFactory2) -> bool {
	f5: ^dxgi.IFactory5
	if win.FAILED(factory->QueryInterface(dxgi.IFactory5_UUID, (^rawptr)(&f5))) || f5 == nil { return false }
	defer f5->Release()
	allow: win.BOOL
	if win.FAILED(f5->CheckFeatureSupport(.PRESENT_ALLOW_TEARING, &allow, size_of(allow))) { return false }
	return bool(allow)
}

// A new swap chain: its present numbers start over.
@(private)
present_reset :: proc(r: ^Renderer) {
	p := &r.present
	p.ring = {}
	p.have_seen = false
	p.sync_count, p.sync_tick = 0, {}
	p.stats_ok, p.stats_fails = false, 0
}

@(private)
present_destroy :: proc(r: ^Renderer) { delete(r.present.out) }

// Presents the frame (frame_end). Returns the HRESULT of Present.
@(private)
present_frame :: proc(r: ^Renderer, vsync: bool) -> win.HRESULT {
	p := &r.present
	if p.interval == 0 { p.interval = 1 }
	tearing := p.mode == .Tearing && p.tearing_ok && .ALLOW_TEARING in r.swap_flags
	sync: u32 = vsync && !tearing ? p.interval : 0
	flags: dxgi.PRESENT
	if sync == 0 && .ALLOW_TEARING in r.swap_flags && p.tearing_ok { flags += {.ALLOW_TEARING} }
	ps := profile_present_begin(r)
	hr := r.swapchain->Present(sync, flags)
	profile_present_end(r, ps)
	now := time.tick_now()
	if win.FAILED(hr) { return hr }
	p.presents += 1
	id: u32
	if win.SUCCEEDED(r.swapchain->GetLastPresentCount(&id)) {
		p.ring[id % PRESENT_RING] = Present_Slot{present = id, input = p.input, presented = now, continuous = p.continuous, interval = max(sync, 1), expected = p.expected > 0 ? p.expected : f64(max(sync, 1)), mode = tearing ? .Tearing : .Vsync}
	}
	p.input = {}
	present_collect(r)
	when RENDER_PROBE { present_probe(r, now) }
	return hr
}

// Reads the frame statistics: a frame newly on screen becomes a Displayed_Frame.
@(private)
present_collect :: proc(r: ^Renderer) {
	p := &r.present
	if p.stats_fails > 64 { return }   // not supported here (some remote sessions): stop asking
	st: dxgi.FRAME_STATISTICS
	hr := r.swapchain->GetFrameStatistics(&st)
	if hr == dxgi.ERROR_FRAME_STATISTICS_DISJOINT { p.have_seen = false; p.sync_count = 0; return }
	if win.FAILED(hr) { p.stats_fails += 1; return }
	p.stats_ok = true
	p.stats_fails = 0
	sync := qpc_to_tick(i64(st.SyncQPCTime))
	// the vblank period from two (vblank number, time) samples
	if p.sync_count != 0 && st.SyncRefreshCount > p.sync_count && st.SyncRefreshCount - p.sync_count < 1000 {
		per := f64(sync._nsec - p.sync_tick._nsec) / f64(st.SyncRefreshCount - p.sync_count)
		if per > 1e6 && per < 1e8 {   // 10 .. 1000 Hz
			p.period_ns = p.period_ns == 0 ? per : p.period_ns + (per - p.period_ns) * 0.1
		}
	}
	if st.SyncRefreshCount != p.sync_count { p.sync_count, p.sync_tick = st.SyncRefreshCount, sync }
	if p.have_seen && st.PresentCount == p.seen_present { return }
	if p.have_seen && st.PresentCount < p.seen_present { p.have_seen = false }   // counters started over
	slot := p.ring[st.PresentCount % PRESENT_RING]
	if slot.present != st.PresentCount { slot = {} }
	// when it showed: SyncQPCTime is the latest vblank; the frame came PresentRefreshCount - SyncRefreshCount before
	shown := sync
	if p.period_ns > 0 && st.SyncRefreshCount >= st.PresentRefreshCount {
		shown._nsec -= i64(f64(st.SyncRefreshCount - st.PresentRefreshCount) * p.period_ns)
	}
	d := Displayed_Frame{present = st.PresentCount, input = slot.input, presented = slot.presented, shown = shown}
	// counters that go back or jump far (the swap chain was out of view, the display mode changed): no run to compare to
	run := p.have_seen && st.PresentCount > p.seen_present && st.PresentCount - p.seen_present < PRESENT_RING &&
	       st.PresentRefreshCount > p.seen_refresh && st.PresentRefreshCount - p.seen_refresh <= (st.PresentCount - p.seen_present) * slot.interval + 240
	// every frame since the last one seen followed its previous one without a pause
	for id := p.seen_present + 1; run && id <= st.PresentCount; id += 1 {
		s := p.ring[id % PRESENT_RING]
		if s.present != id || !s.continuous { run = false }
	}
	if run {
		frames := st.PresentCount - p.seen_present
		d.refreshes = st.PresentRefreshCount - p.seen_refresh
		// app-timed frames land on whole refreshes: n frames span at most ceil(n * expected) of them
		allowed := u32(math.ceil(f64(frames) * max(slot.expected, 1) - 1e-6))
		if slot.mode == .Vsync && d.refreshes > allowed { d.missed = d.refreshes - allowed }
	}
	p.seen_present, p.seen_refresh, p.have_seen = st.PresentCount, st.PresentRefreshCount, true
	p.displayed += 1
	p.missed += u64(d.missed)
	if len(p.out) >= 4 * PRESENT_RING { clear(&p.out) }   // nobody takes them: keep only recent ones
	append(&p.out, d)
}

// RENDER_PROBE: once per second, frames, misses, input -> screen latency and the measured refresh rate.
@(private)
present_probe :: proc(r: ^Renderer, now: time.Tick) {
	p := &r.present
	if time.tick_diff(p.probe_tick, now) < time.Second { return }
	p.probe_tick = now
	lat, n: f64
	for d in p.out { if d.input._nsec != 0 && d.shown._nsec > d.input._nsec { lat += f64(d.shown._nsec - d.input._nsec) / 1e6; n += 1 } }
	fmt.eprintf("render: %d presents, %d shown, %d missed | input -> screen %.1f ms (%d samples) | %.2f Hz measured | %v\n",
		p.presents, p.displayed, p.missed, n > 0 ? lat / n : 0, int(n), measured_refresh_hz(r), present_mode(r))
}
