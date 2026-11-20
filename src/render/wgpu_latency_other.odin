#+build !windows
package render

import "core:math"
import "core:time"
import "../platform"

// No frame latency object here: the present mode (FIFO by default) paces the frames at the vblank, and
// platform.wait_handle(w, wgpu_waitable(r) == nil) returns at once. The compositor's timing is Wayland's presentation
// answers (platform.vblank_timing); X11 gives none yet, and the frame statistics (shown, missed refreshes) stay off there.

@(private) wgpu_latency_start :: proc(r: ^Renderer) {}
@(private) wgpu_latency_stop :: proc(r: ^Renderer) {}
@(private) wgpu_latency_arm :: proc(r: ^Renderer, ns: i64) {}
@(private) wgpu_latency_wait :: proc(r: ^Renderer, timeout_ms: int) -> bool { return true }

// The compositor's timing, as Windows' (wgpu_latency_windows.odin): the last vblank, its refresh counter and the
// period into the present state. The compositor also says which pictures it showed (`counted`): the totals take them
// here, and the refreshes a continuous run missed by the counter's moves. Read at each present, from numbers the
// window's thread already received: no wait (src/md/infrastructure/vblank.md).
@(private)
wgpu_compositor_timing :: proc(r: ^Renderer) -> (refresh: u64, ok, counted: bool) {
	p := &r.present
	v, has := platform.vblank_timing(r.surface_handles)
	if !has || v.shown == 0 { p.stats_ok = false; return }
	counted = true
	l := &r.wg.latency
	if v.shown > l.seen_shown {
		frames := v.shown - l.seen_shown
		p.displayed += frames
		// (as present_collect: n frames of a continuous run span at most ceil(n * expected) refreshes; past that, the
		// screen showed an older picture again. A counter that jumped far is a rest, not a miss)
		if l.have_seen && p.continuous && v.msc > l.seen_msc && v.msc - l.seen_msc < RUN_MAX_REFRESH_JUMP {
			refreshes := v.msc - l.seen_msc
			expected := p.expected > 0 ? p.expected : f64(max(p.interval, 1))
			allowed := u64(math.ceil(f64(frames) * max(expected, 1) - ALLOWED_REFRESHES_EPSILON))
			if refreshes > allowed { p.missed += refreshes - allowed }
		}
		l.seen_shown, l.seen_msc = v.shown, v.msc
		l.have_seen = v.msc != 0
	}
	// (a frame after a rest: the refreshes since the last picture are no miss, the next answer starts a run)
	if !p.continuous { l.have_seen = false }
	if v.period_ns <= 0 { p.stats_ok = false; return }
	p.period_ns = v.period_ns
	p.sync_tick = time.Tick{_nsec = v.last_ns}
	p.sync_count = u32(v.msc)
	p.stats_ok = true
	return v.msc, true, true
}
