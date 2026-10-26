package render

import "core:fmt"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

// A second window drawn by the same renderer (same device, textures, fonts and pipelines): a Surface is a swap chain of its
// own with the state that goes with it. `surface_use` exchanges it with the renderer's own, so that the calls that follow
// (resize, frame_begin, frame_submit, frame_end) work on the other window; call it again to go back. Direct3D 11 only:
// with the wgpu backend `surface_create` fails.

Surface :: struct {
	swapchain:      ^dxgi.ISwapChain1,
	rtv:            ^d3d11.IRenderTargetView,
	frame_tex:      ^d3d11.ITexture2D,
	frame_format:   dxgi.FORMAT,
	frame_view:     dxgi.FORMAT,
	latency_handle: win.HANDLE,
	swap_flags:     dxgi.SWAP_CHAIN,
	present:        Present_State,
	size:           [2]int,
	buffer_size:    [2]int,
	source_size:    [2]int,
	fixed_surface:  bool,
	surface_max:    [2]int,
	hwnd:           win.HWND,
	transparent:    bool,
	dcomp:          ^IDCompositionDevice,
	dcomp_target:   ^IDCompositionTarget,
	dcomp_visual:   ^IDCompositionVisual,
	capture:        Capture_State,   // a capture is of one window: the next frame_end of this surface
	gen:            u64,             // Renderer.swap_gen and swap_space, while the surface is set aside:
	space_epoch:    u64,             // what it was made on and in
	valid:          bool,
}

@(private) surface_creating: bool

@(private)
exchange :: proc(r: ^Renderer, s: ^Surface) {
	r.swapchain, s.swapchain = s.swapchain, r.swapchain
	r.rtv, s.rtv = s.rtv, r.rtv
	r.frame_tex, s.frame_tex = s.frame_tex, r.frame_tex
	r.frame_format, s.frame_format = s.frame_format, r.frame_format
	r.frame_view, s.frame_view = s.frame_view, r.frame_view
	r.latency_handle, s.latency_handle = s.latency_handle, r.latency_handle
	r.swap_flags, s.swap_flags = s.swap_flags, r.swap_flags
	r.present, s.present = s.present, r.present
	r.size, s.size = s.size, r.size
	r.buffer_size, s.buffer_size = s.buffer_size, r.buffer_size
	r.source_size, s.source_size = s.source_size, r.source_size
	r.fixed_surface, s.fixed_surface = s.fixed_surface, r.fixed_surface
	r.surface_max, s.surface_max = s.surface_max, r.surface_max
	r.hwnd, s.hwnd = s.hwnd, r.hwnd
	r.transparent, s.transparent = s.transparent, r.transparent
	r.dcomp, s.dcomp = s.dcomp, r.dcomp
	r.dcomp_target, s.dcomp_target = s.dcomp_target, r.dcomp_target
	r.dcomp_visual, s.dcomp_visual = s.dcomp_visual, r.dcomp_visual
	r.capture, s.capture = s.capture, r.capture
	r.swap_gen, s.gen = s.gen, r.swap_gen
	r.swap_space, s.space_epoch = s.space_epoch, r.swap_space
}

// The window the renderer holds now was set aside while the device was recreated (recover: only the window in use is remade, with
// everything else on the device) or the blend space changed: its swap chain and views belong to the old device, or to the old space.
@(private)
surface_refresh :: proc(r: ^Renderer) {
	if r.swap_gen != r.device_generation {
		rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
		old_device: ^d3d11.IDevice   // the device they were made on: they keep it alive
		if r.swapchain != nil { r.swapchain->GetDevice(d3d11.IDevice_UUID, (^rawptr)(&old_device)) }
		rel(&r.rtv); rel(&r.frame_tex)
		if r.hwnd == nil { rel(&r.offscreen) }
		release_presentation(r)
		if r.latency_handle != nil { win.CloseHandle(r.latency_handle); r.latency_handle = nil }
		capture_release_device_objects(&r.capture)
		if old_device != nil {
			// the old device destroys them when its context runs its queue; until then the old swap chain still owns the window
			old_ctx: ^d3d11.IDeviceContext
			old_device->GetImmediateContext(&old_ctx)
			if old_ctx != nil { old_ctx->ClearState(); old_ctx->Flush(); old_ctx->Release() }
			old_device->Release()
		}
		ok := true
		if r.hwnd == nil {
			ok = create_offscreen_target(r)
		} else {
			surface_creating = true   // the window may not have a size yet: the swap chain gets the one of the surface
			ok = create_swapchain(r)
			surface_creating = false
		}
		if !ok { fmt.eprintln("render: a window could not be remade after the device was recreated") }
		r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
	} else if r.swap_space != r.space_epoch {
		retarget(r)
		r.swap_space = r.space_epoch
	}
}

// A swap chain for the window `hwnd`, on the renderer's device. By default an HWND swap chain (opaque): its buffers map onto the
// client area, so a window being resized shows the last frame stretched until a frame of the new size arrives.
// `transparent`: a composition swap chain, as render.init's (open the window with platform's `transparent` too, which gives it
// no GDI surface); the blend space is the renderer's. With it, `fixed_size` (> 0) is what set_fixed_surface does for the
// renderer's own window: the buffers keep that size (the monitor's, say) while the window is resized, shown 1:1 and clipped by the
// client area, so nothing is ever stretched. Where DirectComposition is missing the surface is an opaque HWND chain, as render.init's.
// `surface_init` makes it in the Surface `s` points to, where the program keeps it. Prefer it to `surface_create`.
surface_init :: proc(r: ^Renderer, s: ^Surface, hwnd: win.HWND, size: [2]int, transparent := false, fixed_size := [2]int{}) -> (ok: bool) {
	when USE_WGPU {
		fmt.eprintln("render: second windows need the Direct3D 11 backend")
		return
	} else {
		s^ = {}
		s.hwnd, s.size = hwnd, size
		exchange(r, s)   // the renderer is the other window's for a moment: create_swapchain makes the chain it has
		r.transparent = transparent
		r.fixed_surface = false
		surface_creating = true
		ok = create_swapchain(r)
		surface_creating = false
		if ok && r.transparent && fixed_size.x > 0 && fixed_size.y > 0 { d3d_set_fixed_surface(r, fixed_size) }
		r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
		r.capture = {}
		exchange(r, s)
		s.valid = ok
		return
	}
}

// `surface_init`, returning the Surface by value. A Surface is several kilobytes (Present_State's ring of 256 frames): held in a local and
// copied into a field, an optimizing build with debug information (`-o:speed -debug`) splits it into thousands of values with a debug
// record each, and LLVM spends more than ten minutes on the module (Wren's dev build did, until it called surface_init). New code calls
// surface_init with the Surface where it lives.
surface_create :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int, transparent := false, fixed_size := [2]int{}) -> (s: Surface, ok: bool) {
	ok = surface_init(r, &s, hwnd, size, transparent, fixed_size)
	return
}

// Releases the surface (it must not be the one in use).
surface_destroy :: proc(r: ^Renderer, s: ^Surface) {
	when !USE_WGPU {
		if !s.valid { return }
		exchange(r, s)
		r.ctx->OMSetRenderTargets(0, nil, nil)
		if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
		if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
		release_presentation(r)   // the swap chain and a translucent window's DirectComposition objects (render.odin)
		if r.latency_handle != nil { win.CloseHandle(r.latency_handle); r.latency_handle = nil }
		capture_destroy(r)
		present_destroy(r)
		exchange(r, s)
		s^ = {}
	}
}

// Makes `s` the window the renderer draws to (its own surface goes into `s`). Call again with the same `s` to go back.
surface_use :: proc(r: ^Renderer, s: ^Surface) {
	when !USE_WGPU {
		if !s.valid { return }
		exchange(r, s)
		surface_refresh(r)
	}
}

_ :: fmt
