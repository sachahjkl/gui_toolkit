package render

// A second window drawn by the same WebGPU renderer (same device, queue, pipelines, textures and fonts): its own wgpu
// surface with the present and latency state that goes with it. The device objects are shared, so only what is one
// window's is exchanged by surface_use, as on Direct3D (surface.odin): the Window_Target and, here, the Wgpu_Window, kept
// on the heap in Surface.wgpu_backing. Neutral: the surface is made from the window's native handles by wgpu_make_surface
// (HWND + DirectComposition on Windows, Wayland / XCB on Linux).

import "core:fmt"
import "core:slice"
import win "core:sys/windows"
import "vendor:wgpu"
import "../platform"

_ :: win   // (used on Windows only)

// Exchanges what is one window's between the renderer and `s`. After it, the renderer draws to the window `s` was made
// for; call it again (with the same `s`) to go back to the window that was current.
@(private)
wgpu_surface_exchange :: proc(r: ^Renderer, s: ^Surface) {
	exchange(r, s)
	slice.ptr_swap_non_overlapping(&r.wg.window, s.wgpu_backing, size_of(Wgpu_Window))
}

// Creates the wgpu surface for the native handles on the renderer's device and configures it, leaving the renderer
// pointed back at its own window. `s` then holds the new window's state, ready for surface_use.
@(private)
wgpu_surface_init :: proc(r: ^Renderer, s: ^Surface, handles: platform.Surface_Handles, size: [2]int, transparent: bool) -> bool {
	g := &r.wg
	if g.device == nil || r.lost { fmt.eprintln("render: wgpu: no device for a second window"); return false }
	s.wgpu_backing = new(Wgpu_Window)
	// the renderer's window steps aside while we build the second window's surface on it (wgpu_make_surface reads
	// r.transparent, and configure reads r.size and the formats), then steps back; the second window's state stays in `s`.
	wgpu_surface_exchange(r, s)
	r.size, r.surface_handles, r.transparent, r.transparent_asked = size, handles, transparent, transparent
	r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
	when ODIN_OS == .Windows { r.hwnd = win.HWND(handles.hwnd) }
	ok := true
	g.surface = wgpu_make_surface(r, handles)
	if handles.backend != .None && g.surface == nil { fmt.eprintln("render: wgpu: cannot create the second window's surface"); ok = false }
	if ok {
		wgpu_frame_formats(r)   // sets g.surface_format / g.view_format for this surface's transparency and the blend space
		ok = wgpu_configure_surface(r)
	}
	// step the renderer back onto its own window; `s` now carries the second window's surface and state (or a clean nil state on failure)
	wgpu_surface_exchange(r, s)
	if !ok { free(s.wgpu_backing); s.wgpu_backing = nil; return false }
	return true
}

@(private)
wgpu_surface_use :: proc(r: ^Renderer, s: ^Surface) {
	if s.wgpu_backing == nil { return }
	wgpu_surface_exchange(r, s)
	wgpu_surface_refresh(r)
}

// The window the renderer holds now was set aside while the device was recreated (recover: only the window in use is remade) or the
// blend space changed (set_blend_space: idem), what surface_refresh does on Direct3D 11. A device still lost: its recovery remakes it.
@(private)
wgpu_surface_refresh :: proc(r: ^Renderer) {
	if r.lost { return }
	g := &r.wg
	if r.swap_gen != r.device_generation {
		wgpu_latency_stop(r)
		wgpu_release_frame(g)
		capture_release_device_objects(&r.capture)
		wgpu_damage_release_target(r)
		if g.surface != nil { wgpu.SurfaceUnconfigure(g.surface); wgpu.SurfaceRelease(g.surface); g.surface = nil }
		wgpu_dcomp_destroy(r)
		g.configured = false
		ok := true
		if r.surface_handles.backend == .None {
			wgpu_frame_formats(r)
			ok = wgpu_create_offscreen(r)
		} else {
			r.transparent = r.transparent_asked
			g.surface = wgpu_make_surface(r, r.surface_handles)
			ok = wgpu_surface_fits(g)
			if ok {
				wgpu_frame_formats(r)
				ok = wgpu_configure_surface(r)
			}
		}
		if !ok {
			fmt.eprintln("render: a window could not be remade after the device was recreated")
			r.lost = true   // (the next frame_begin tries again, with everything else)
		}
		r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
	} else if r.swap_space != r.space_epoch {
		wgpu_retarget(r)
		r.swap_space = r.space_epoch
	}
}

@(private)
wgpu_surface_destroy :: proc(r: ^Renderer, s: ^Surface) {
	if s.wgpu_backing == nil { return }
	// release what the surface owns on its own state (not the current window's): swap it in, tear it down, and leave the
	// renderer on its own window with a clean (nil) backing so nothing dangles.
	wgpu_surface_exchange(r, s)
	g := &r.wg
	wgpu_latency_stop(r)
	wgpu_release_frame(g)
	wgpu_damage_release_target(r)   // the second window's persistent target and verify reference (damage_wgpu.odin)
	if g.surface != nil { wgpu.SurfaceUnconfigure(g.surface); wgpu.SurfaceRelease(g.surface); g.surface = nil }
	wgpu_dcomp_destroy(r)   // frees the translucent window's DirectComposition panel, if any (wgpu_dcomp.odin)
	capture_destroy(r)
	present_destroy(r)
	wgpu_surface_exchange(r, s)
	free(s.wgpu_backing)
	s.wgpu_backing = nil
}
