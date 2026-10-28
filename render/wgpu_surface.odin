package render

// A second window drawn by the same WebGPU renderer (same device, queue, pipelines, textures and fonts): its own wgpu
// surface with the present and latency state that goes with it. The device objects are shared, so only the surface and
// the small amount of renderer state that is per-window are swapped by surface_use, mirroring the Direct3D path in
// surface.odin. Direct3D keeps a swap chain in the Surface struct; here the per-window state is a ^Wgpu_Surface held in
// Surface.wgpu_backing, so surface.odin stays free of wgpu types. Neutral: the surface is made from the window's native
// handles by wgpu_make_surface (HWND + DirectComposition on Windows, Wayland / XCB on Linux).
//
// What is per-window (swapped in and out):
//   * r.wg: surface, surface_format, view_format, frame_tex, frame_rtv, frame_acquired, configured, present_mode,
//     latency (its frame-latency timer), panel (the DirectComposition visual's swap-chain panel for a translucent window);
//   * r: present (Present_State: mode and frame statistics), size, buffer_size, source_size, hwnd, transparent.
// Everything else (device, queue, instance, adapter, pipelines, buffers, textures) is the renderer's and is not touched.

import "core:fmt"
import win "core:sys/windows"
import "vendor:wgpu"
import "toolkit:platform"

@(private)
Wgpu_Surface :: struct {
	// the wgpu per-window state (Wgpu_State fields that belong to one window)
	surface:        wgpu.Surface,
	surface_format: wgpu.TextureFormat,
	view_format:    wgpu.TextureFormat,
	frame_tex:      wgpu.Texture,
	frame_rtv:      wgpu.TextureView,
	frame_acquired: bool,
	configured:     bool,
	present_mode:   wgpu.PresentMode,
	latency:        Wgpu_Latency,
	panel:          ^Panel,
	// partial redraw: the persistent target and verify reference belong to one window (damage_wgpu.odin)
	damage_target:  wgpu.Texture,
	damage_view:    wgpu.TextureView,
	damage_sample:  wgpu.TextureView,
	damage_size:    [2]int,
	damage_ready:   bool,
	damage_ref:     wgpu.Texture,
	damage_ref_view: wgpu.TextureView,
	// the renderer-level per-window state
	present:        Present_State,
	damage:         Damage_State,
	size:           [2]int,
	buffer_size:    [2]int,
	source_size:    [2]int,
	hwnd:           win.HWND,
	handles:        platform.Surface_Handles,
	transparent:    bool,
	space_epoch:    u64,
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
	g.frame_acquired, b.frame_acquired = b.frame_acquired, g.frame_acquired
	g.configured, b.configured = b.configured, g.configured
	g.present_mode, b.present_mode = b.present_mode, g.present_mode
	g.latency, b.latency = b.latency, g.latency
	g.panel, b.panel = b.panel, g.panel
	g.damage_target, b.damage_target = b.damage_target, g.damage_target
	g.damage_view, b.damage_view = b.damage_view, g.damage_view
	g.damage_sample, b.damage_sample = b.damage_sample, g.damage_sample
	g.damage_size, b.damage_size = b.damage_size, g.damage_size
	g.damage_ready, b.damage_ready = b.damage_ready, g.damage_ready
	g.damage_ref, b.damage_ref = b.damage_ref, g.damage_ref
	g.damage_ref_view, b.damage_ref_view = b.damage_ref_view, g.damage_ref_view
	r.present, b.present = b.present, r.present
	r.damage, b.damage = b.damage, r.damage
	r.size, b.size = b.size, r.size
	r.buffer_size, b.buffer_size = b.buffer_size, r.buffer_size
	r.source_size, b.source_size = b.source_size, r.source_size
	r.hwnd, b.hwnd = b.hwnd, r.hwnd
	r.surface_handles, b.handles = b.handles, r.surface_handles
	r.transparent, b.transparent = b.transparent, r.transparent
	r.swap_space, b.space_epoch = b.space_epoch, r.swap_space
}

// Creates the wgpu surface for the native handles on the renderer's device and configures it, leaving the renderer
// pointed back at its own window. `s.wgpu_backing` then holds the new window's state, ready for surface_use.
@(private)
wgpu_surface_init :: proc(r: ^Renderer, s: ^Surface, handles: platform.Surface_Handles, size: [2]int, transparent: bool) -> bool {
	g := &r.wg
	if g.device == nil { fmt.eprintln("render: wgpu: no device for a second window"); return false }
	b := new(Wgpu_Surface)
	// the renderer's window steps aside while we build the second window's surface on it (wgpu_make_surface reads
	// r.transparent, and configure reads r.size and the formats), then steps back; the second window's state stays in `b`.
	wgpu_surface_exchange(r, b)
	r.size, r.surface_handles, r.transparent, r.swap_space = size, handles, transparent, r.space_epoch
	when ODIN_OS == .Windows { r.hwnd = win.HWND(handles.hwnd) }
	r.present = {}
	g.surface, g.panel, g.configured, g.frame_acquired = nil, nil, false, false
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
	// the blend space may have changed while this surface was set aside (set_blend_space touches only the current window):
	// bring its formats and configuration in line, as the Direct3D surface_refresh does for a space change.
	if r.swap_space != r.space_epoch {
		wgpu_frame_formats(r)
		if r.wg.surface != nil { wgpu_configure_surface(r) }
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
	wgpu_drop_frame(r)
	wgpu_damage_release_target(r)   // the second window's persistent target and verify reference (damage_wgpu.odin)
	if g.surface != nil { wgpu.SurfaceUnconfigure(g.surface); wgpu.SurfaceRelease(g.surface); g.surface = nil }
	wgpu_dcomp_destroy(r)   // frees the translucent window's DirectComposition panel, if any (wgpu_dcomp.odin)
	wgpu_surface_exchange(r, b)
	free(b)
	s.wgpu_backing = nil
}
