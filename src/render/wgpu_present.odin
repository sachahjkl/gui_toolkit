package render

import "core:fmt"
import "core:time"
import win "core:sys/windows"
import "vendor:wgpu"
import "../platform"

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
// are the ones the app presented late; a frame the GPU finished late is not seen. On Wayland the compositor says itself
// which pictures it showed and at which refresh (wp_presentation, platform.vblank_timing): the counts are its own.

Wgpu_Latency :: struct {
	timer:      win.HANDLE,   // the frame latency object (frame_waitable)
	last_index: u64,          // the vblank the previous frame was shown at (compositor's refresh counter)
	have_index: bool,
	lag_ns:     f64,          // how much later than the next vblank the swap chain really takes a new frame (learned from the acquires that had to wait)
	// the compositor's own counts (Wayland): the pictures it said it showed, and the refresh counter of the last one, when
	// last read; `have_seen` false: no run to compare the next answer to
	seen_shown: u64,
	seen_msc:   u64,
	have_seen:  bool,
}

// Frames the surface may queue without LOW_LATENCY.
@(private) WGPU_FRAME_LATENCY_DEFAULT :: 3
// An acquire that waited longer than this says the latency object was set too early; else the lag fades by LAG_DECAY.
@(private) LAG_WAIT_MIN_NS :: 300_000
@(private) LAG_MAX_NS :: 3e6
@(private) LAG_DECAY :: 0.9
// A little margin for the GPU: a present this close before a vblank does not make it.
@(private) PRESENT_GPU_MARGIN_NS :: 500_000
// The latency object is signaled this much before the vblank that shows the frame.
@(private) LATENCY_ARM_EARLY_NS :: 200_000
// Added before truncating: the ceil of the expected refreshes.
@(private) EXPECTED_REFRESHES_CEIL :: 0.999999

@(private)
wgpu_frame_latency :: proc(r: ^Renderer) -> u32 {
	when LOW_LATENCY { return 1 } else { return WGPU_FRAME_LATENCY_DEFAULT }
}

// (wgpu_latency_start, wgpu_latency_stop, wgpu_latency_arm, wgpu_latency_wait, wgpu_compositor_timing: the frame
// latency object and the compositor's timing, wgpu_latency_windows.odin; elsewhere none, wgpu_latency_other.odin)

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
		if waited > LAG_WAIT_MIN_NS { l.lag_ns = min(l.lag_ns + 0.5 * waited, LAG_MAX_NS) } else { l.lag_ns *= LAG_DECAY }
	}
	return st
}

// wait_for_frame: the frame latency object, then the texture of the frame (which waits for the real object). On Linux
// there is no latency object; the FIFO present paces instead, and this just acquires the frame.
@(private)
wgpu_wait_frame :: proc(r: ^Renderer, timeout_ms: int) -> bool {
	if !r.present.slot_unused && !wgpu_latency_wait(r, timeout_ms) { return false }
	return wgpu_ensure_frame(r)
}

// Whether the surface can present with tearing (asked once per configure), then the mode the present mode setting asks for.
@(private)
wgpu_query_tearing :: proc(r: ^Renderer) {
	g := &r.wg
	caps, st := wgpu.SurfaceGetCapabilities(g.surface, g.adapter)
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)
	r.present.tearing_ok, r.present.mailbox_ok = false, false
	if st == .Success {
		for i in 0 ..< caps.presentModeCount {
			if caps.presentModes[i] == .Immediate { r.present.tearing_ok = true }
			if caps.presentModes[i] == .Mailbox { r.present.mailbox_ok = true }
		}
		if wgpu_trace() { fmt.eprintfln("wgpu: surface present modes %v, formats %v, alpha %v", caps.presentModes[:caps.presentModeCount], caps.formats[:caps.formatCount], caps.alphaModes[:caps.alphaModeCount]) }
	}
}

@(private)
wgpu_pick_present_mode :: proc(r: ^Renderer) -> wgpu.PresentMode {
	if r.present.no_wait {
		if r.present.mailbox_ok { return .Mailbox }
		if r.present.tearing_ok { return .Immediate }
	}
	// Wayland: the window paces itself on the compositor's word (platform.frame_shown_pending): a picture a refresh, and a
	// compositor never tears a mailbox. A Fifo present adds a barrier the compositor keeps the commit behind (wp_fifo_v1,
	// NVIDIA's driver), with the word the commit carries: a barrier never lifted left the window without a picture.
	if r.surface_handles.backend == .Wayland && r.present.mailbox_ok && present_call(r.present.mode, r.present.tearing_ok, r.present.interval, true).mode == .Vsync {
		return .Mailbox
	}
	return present_call(r.present.mode, r.present.tearing_ok, r.present.interval, true).mode == .Tearing ? .Immediate : .Fifo
}

@(private)
wgpu_frame_end :: proc(r: ^Renderer, vsync := true) {
	g := &r.wg
	wgpu_lost_poll(r)
	if g.clear_pending { g.damage_ready = false }   // nothing of this frame reached the kept target: drawn or not, it is behind
	if r.lost || g.frame_rtv == nil {   // no frame (a hidden window, a device gone): a capture asked of it ends here
		if r.capture.requested { capture_copy_wgpu(r, nil, g.surface_format, r.space) }
		return
	}
	if g.clear_pending { wgpu_clear_frame(r) }
	// the capture copies the frame target before the present consumes the surface texture (one more command on the queue)
	if r.capture.requested {
		// (a surface that cannot be copied from: the frame was composed into the kept target, wgpu_damage_setup)
		src := g.frame_tex
		if g.surface != nil && !g.surface_copy { src = g.damage_ready ? g.damage_target : nil }
		capture_copy_wgpu(r, src, g.surface_format, r.space)
	}
	if g.surface == nil {   // offscreen
		wgpu_poll(r, true)   // (no present paces an offscreen frame: on a slow device they would pile up, and a read-back wait behind them)
		return
	}
	if r.damage.skip_present {   // a region of nothing: the window keeps what it shows, and the texture stays acquired
		r.present.slot_unused = true
		return
	}
	// (asked before the present, which commits the surface: the answer is this picture's)
	platform.vblank_ask(r.surface_handles)
	t_pre := time.tick_now()
	r.present.call = t_pre
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

// The refreshes a frame stays for. A surface in Fifo waits for the vblank whatever frame_end asked (`vsync` false): only a reconfigure
// changes its mode.
@(private)
wgpu_present_sync :: proc(asked: u32, mode: wgpu.PresentMode) -> u32 {
	return asked == 0 && mode == .Fifo ? 1 : asked
}

// A surface configured: what was counted of the one before says nothing about it (present_reset, on Direct3D 11).
@(private)
present_reset_wgpu :: proc(r: ^Renderer) {
	r.present.slot_unused = false
	r.wg.latency.have_index = false
	r.wg.latency.have_seen = false
}

// Most frames the surface may queue (api.set_max_frame_latency): the wgpu backend has no equivalent here.
wgpu_set_max_frame_latency :: proc(r: ^Renderer, n: int) -> bool { return false }

// A frame was presented at `now`: arm the latency object, note when it will be on screen.
@(private)
wgpu_present_done :: proc(r: ^Renderer, now: time.Tick, vsync: bool) {
	p := &r.present
	l := &r.wg.latency
	p.slot_unused = false
	p.presents += 1
	if p.interval == 0 { p.interval = 1 }
	sync := wgpu_present_sync(present_call(p.mode, p.tearing_ok, p.interval, vsync).sync, r.wg.present_mode)
	// the compositor's timing: the last vblank (refresh counter, time) and the period. Windows: DWM's. Wayland: the
	// presentation answers, which also count the pictures shown and the refreshes missed (`counted`). X11: none yet,
	// the frame statistics stay off.
	refresh, ok, counted := wgpu_compositor_timing(r)
	shown := now
	index: u64
	if ok && sync > 0 && p.period_ns > 0 {
		// the first vblank after the present (a little margin for the GPU), then `interval - 1` more of them
		since := f64(time.tick_diff(p.sync_tick, now)) + PRESENT_GPU_MARGIN_NS
		k := since <= 0 ? 0 : u64(since / p.period_ns) + 1
		shown._nsec = p.sync_tick._nsec + i64(f64(k + u64(sync - 1)) * p.period_ns)
		index = refresh + k + u64(sync - 1)
	} else if ok {
		index = refresh + u64(max(f64(time.tick_diff(p.sync_tick, now)), 0) / max(p.period_ns, 1))
	}
	// the latency object: the screen has taken the frame when it reaches that vblank (plus the lag learned so far)
	wgpu_latency_arm(r, sync > 0 ? max(i64(time.tick_diff(now, shown) + time.Duration(l.lag_ns)) - LATENCY_ARM_EARLY_NS, 0) : 0)
	if sync > 0 && l.lag_ns >= 0.5 * p.period_ns { shown._nsec += i64(l.lag_ns / p.period_ns + 0.5) * i64(p.period_ns) }
	if wgpu_trace() { fmt.eprintfln("wgpu: present done: shown in %.2f ms, interval %d, lag %.2f ms, period %.2f ms, dwm ok %v", f64(time.tick_diff(now, shown)) / 1e6, sync, l.lag_ns / 1e6, p.period_ns / 1e6, ok) }
	d := Displayed_Frame{present = u32(p.presents), input = p.input, read = p.read, drawn = p.drawn, call = p.call, presented = now, shown = shown}
	// (counted by the compositor: its totals are the true ones, the estimate here would count each present as shown)
	if !counted && ok && sync > 0 && l.have_index && index > l.last_index && index - l.last_index < RUN_MAX_REFRESH_JUMP && p.continuous {
		d.refreshes = u32(index - l.last_index)
		allowed := u32(p.expected > 0 ? p.expected + EXPECTED_REFRESHES_CEIL : f64(sync))
		if d.refreshes > max(allowed, 1) { d.missed = d.refreshes - max(allowed, 1) }
	}
	l.last_index, l.have_index = index, ok && sync > 0
	if !counted {
		p.displayed += 1
		p.missed += u64(d.missed)
	}
	p.input, p.read = {}, {}
	present_publish(p, d)
	when RENDER_PROBE { present_probe(r, now) }
}
