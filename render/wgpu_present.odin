package render

import "vendor:wgpu"

// WebGPU backend: presentation. wgpu-native exposes neither the swap chain's frame latency object nor its frame
// statistics, so what Direct3D 11 got from DXGI is rebuilt here (see the comments of each procedure).

// The frame latency "object" (platform.wait_handle waits on it with the window's input): see wgpu_latency_*.
Wgpu_Latency :: struct {
	started: bool,
}

@(private)
wgpu_frame_latency :: proc(r: ^Renderer) -> u32 {
	when LOW_LATENCY { return 1 } else { return 3 }
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
	}
}

@(private)
wgpu_pick_present_mode :: proc(r: ^Renderer) -> wgpu.PresentMode {
	if r.present.mode == .Tearing && r.present.tearing_ok { return .Immediate }
	return .Fifo
}

@(private)
wgpu_acquire :: proc(r: ^Renderer) -> wgpu.SurfaceTexture {
	return wgpu.SurfaceGetCurrentTexture(r.wg.surface)
}

@(private)
wgpu_wait_frame :: proc(r: ^Renderer, timeout_ms: int) -> bool {
	return wgpu_ensure_frame(r)
}

@(private)
wgpu_latency_stop :: proc(r: ^Renderer) {}

@(private)
wgpu_profile_release :: proc(r: ^Renderer) {}

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
	wgpu.SurfacePresent(g.surface)
	r.present.presents += 1
	wgpu_drop_frame(r)
}
