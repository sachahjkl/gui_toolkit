package render

// A second window drawn by the same WebGPU renderer (same device, queue, pipelines, textures and fonts): its own wgpu
// surface with the present and latency state that goes with it. The device objects are shared, so only the surface and
// the small amount of renderer state that is per-window are swapped by surface_use, mirroring the Direct3D path in
// surface.odin. Direct3D keeps a swap chain in the Surface struct; here the per-window state is a ^Wgpu_Surface held in
// Surface.wgpu_backing, so surface.odin stays free of wgpu types. Neutral: the surface is made from the window's native
// handles by wgpu_make_surface (HWND + DirectComposition on Windows, Wayland / XCB on Linux).
//
// What is per-window (swapped in and out):
//   * r.wg: surface, surface_format, view_format, frame_tex, frame_rtv, configured, present_mode, clear, clear_pending, first_shown,
//     latency (its frame-latency timer), panel (the DirectComposition visual's swap-chain panel for a translucent window);
//   * r: present (Present_State: mode and frame statistics), capture, size, buffer_size, source_size, hwnd, transparent, and what the
//     window's objects were made on and in (swap_gen, swap_space).
// Everything else (device, queue, instance, adapter, pipelines, buffers, textures) is the renderer's and is not touched.

import "core:fmt"
import win "core:sys/windows"
import "vendor:wgpu"
import "../platform"

@(private)
Wgpu_Surface :: struct {
	// the wgpu per-window state (Wgpu_State fields that belong to one window)
	surface:        wgpu.Surface,
	surface_format: wgpu.TextureFormat,
	view_format:    wgpu.TextureFormat,
	frame_tex:      wgpu.Texture,
	frame_rtv:      wgpu.TextureView,
	configured:     bool,
	present_mode:   wgpu.PresentMode,
	clear:          [4]f64,
	clear_pending:  bool,
	first_shown:    bool,
	latency:        Wgpu_Latency,
	panel:          ^Panel,
	// partial redraw: the persistent target and verify reference belong to one window (damage_wgpu.odin)
	damage_target:  wgpu.Texture,
	damage_view:    wgpu.TextureView,
	damage_sample:  wgpu.TextureView,
	damage_size:    [2]int,
	damage_ready:   bool,
	damage_side:    wgpu.Texture,
	damage_side_view: wgpu.TextureView,
	damage_side_sample: wgpu.TextureView,
	damage_side_size: [2]int,
	damage_side_ready: bool,
	damage_clear:   wgpu.Texture,
	damage_clear_view: wgpu.TextureView,
	damage_clear_size: [2]int,
	// the renderer-level per-window state
	present:        Present_State,
	damage:         Damage_State,
	capture:        Capture_State,
	size:           [2]int,
	buffer_size:    [2]int,
	source_size:    [2]int,
	hwnd:           win.HWND,
	handles:        platform.Surface_Handles,
	transparent:    bool,
	transparent_asked: bool,
	gen:            u64,   // Renderer.swap_gen and swap_space, while the window is set aside:
	space_epoch:    u64,   // what it was made on and in
}

// Swaps the window-specific state of the renderer with the backing of `s`. After it, the renderer draws to the window
// `s` was made for; call it again (with the same `s`) to go back to the window that was current.
@(private)
wgpu_surface_exchange :: proc(r: ^Renderer, b: ^Wgpu_Surface) {
	g := &r.wg
	g.surface, b.surface = b.surface, g.surface
	g.surface_format, b.surface_format = b.surface_format, g.surface_format
	g.view_format, b.view_format = b.view_format, g.view_format
	g.frame_tex, b.frame_tex = b.frame_tex, g.frame_tex
	g.frame_rtv, b.frame_rtv = b.frame_rtv, g.frame_rtv
	g.configured, b.configured = b.configured, g.configured
	g.present_mode, b.present_mode = b.present_mode, g.present_mode
	g.clear, b.clear = b.clear, g.clear
	g.clear_pending, b.clear_pending = b.clear_pending, g.clear_pending
	g.first_shown, b.first_shown = b.first_shown, g.first_shown
	g.latency, b.latency = b.latency, g.latency
	g.panel, b.panel = b.panel, g.panel
	g.damage_target, b.damage_target = b.damage_target, g.damage_target
	g.damage_view, b.damage_view = b.damage_view, g.damage_view
	g.damage_sample, b.damage_sample = b.damage_sample, g.damage_sample
	g.damage_size, b.damage_size = b.damage_size, g.damage_size
	g.damage_ready, b.damage_ready = b.damage_ready, g.damage_ready
	g.damage_side, b.damage_side = b.damage_side, g.damage_side
	g.damage_side_view, b.damage_side_view = b.damage_side_view, g.damage_side_view
	g.damage_side_sample, b.damage_side_sample = b.damage_side_sample, g.damage_side_sample
	g.damage_side_size, b.damage_side_size = b.damage_side_size, g.damage_side_size
	g.damage_side_ready, b.damage_side_ready = b.damage_side_ready, g.damage_side_ready
	g.damage_clear, b.damage_clear = b.damage_clear, g.damage_clear
	g.damage_clear_view, b.damage_clear_view = b.damage_clear_view, g.damage_clear_view
	g.damage_clear_size, b.damage_clear_size = b.damage_clear_size, g.damage_clear_size
	r.present, b.present = b.present, r.present
	r.damage, b.damage = b.damage, r.damage
	r.capture, b.capture = b.capture, r.capture
	r.size, b.size = b.size, r.size
	r.buffer_size, b.buffer_size = b.buffer_size, r.buffer_size
	r.source_size, b.source_size = b.source_size, r.source_size
	r.hwnd, b.hwnd = b.hwnd, r.hwnd
	r.surface_handles, b.handles = b.handles, r.surface_handles
	r.transparent, b.transparent = b.transparent, r.transparent
	r.transparent_asked, b.transparent_asked = b.transparent_asked, r.transparent_asked
	r.swap_gen, b.gen = b.gen, r.swap_gen
	r.swap_space, b.space_epoch = b.space_epoch, r.swap_space
}

// Creates the wgpu surface for the native handles on the renderer's device and configures it, leaving the renderer
// pointed back at its own window. `s.wgpu_backing` then holds the new window's state, ready for surface_use.
@(private)
wgpu_surface_init :: proc(r: ^Renderer, s: ^Surface, handles: platform.Surface_Handles, size: [2]int, transparent: bool) -> bool {
	g := &r.wg
	if g.device == nil || r.lost { fmt.eprintln("render: wgpu: no device for a second window"); return false }
	b := new(Wgpu_Surface)
	// the renderer's window steps aside while we build the second window's surface on it (wgpu_make_surface reads
	// r.transparent, and configure reads r.size and the formats), then steps back; the second window's state stays in `b`.
	wgpu_surface_exchange(r, b)
	r.size, r.surface_handles, r.transparent, r.transparent_asked = size, handles, transparent, transparent
	r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
	when ODIN_OS == .Windows { r.hwnd = win.HWND(handles.hwnd) }
	r.present = {}
	g.surface, g.panel, g.configured, g.frame_tex, g.frame_rtv = nil, nil, false, nil, nil
	g.latency = {}
	ok := true
	g.surface = wgpu_make_surface(r, handles)
	if handles.backend != .None && g.surface == nil { fmt.eprintln("render: wgpu: cannot create the second window's surface"); ok = false }
	if ok {
		wgpu_frame_formats(r)   // sets g.surface_format / g.view_format for this surface's transparency and the blend space
		ok = wgpu_configure_surface(r)
	}
	// step the renderer back onto its own window; `b` now carries the second window's surface and state (or a clean nil state on failure)
	wgpu_surface_exchange(r, b)
	if !ok { free(b); return false }
	s.wgpu_backing = b
	return true
}

@(private)
wgpu_surface_use :: proc(r: ^Renderer, s: ^Surface) {
	b := (^Wgpu_Surface)(s.wgpu_backing)
	if b == nil { return }
	wgpu_surface_exchange(r, b)
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
	b := (^Wgpu_Surface)(s.wgpu_backing)
	if b == nil { return }
	// release what the surface owns on its own state (not the current window's): swap it in, tear it down, and leave the
	// renderer on its own window with a clean (nil) backing so nothing dangles.
	wgpu_surface_exchange(r, b)
	g := &r.wg
	wgpu_latency_stop(r)
	wgpu_release_frame(g)
	wgpu_damage_release_target(r)   // the second window's persistent target and verify reference (damage_wgpu.odin)
	if g.surface != nil { wgpu.SurfaceUnconfigure(g.surface); wgpu.SurfaceRelease(g.surface); g.surface = nil }
	wgpu_dcomp_destroy(r)   // frees the translucent window's DirectComposition panel, if any (wgpu_dcomp.odin)
	capture_destroy(r)
	present_destroy(r)
	wgpu_surface_exchange(r, b)
	free(b)
	s.wgpu_backing = nil
}
