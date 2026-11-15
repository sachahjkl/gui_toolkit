#+build !windows
package render

// No frame latency object here: the present mode (FIFO by default) paces the frames at the vblank, and
// platform.wait_handle(w, wgpu_waitable(r) == nil) returns at once. No compositor timing either: the frame statistics
// (shown, missed refreshes) stay off.

@(private) wgpu_latency_start :: proc(r: ^Renderer) {}
@(private) wgpu_latency_stop :: proc(r: ^Renderer) {}
@(private) wgpu_latency_arm :: proc(r: ^Renderer, ns: i64) {}
@(private) wgpu_latency_wait :: proc(r: ^Renderer, timeout_ms: int) -> bool { return true }
@(private) wgpu_compositor_timing :: proc(p: ^Present_State) -> (refresh: u64, ok: bool) { return }
