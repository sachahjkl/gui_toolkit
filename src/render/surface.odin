package render

import "core:fmt"
import "core:slice"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "../platform"

// A second window drawn by the same renderer (same device, textures, fonts and pipelines): a Surface is a swap chain of its
// own with the state that goes with it. `surface_use` exchanges it with the renderer's own, so that the calls that follow
// (resize, frame_begin, frame_submit, frame_end) work on the other window; call it again to go back, or let surface_scope do both.
// Both backends: WebGPU's objects of a window are a Wgpu_Window, on the heap (wgpu_surface.odin).

Surface :: struct {
	using target: Window_Target,
	wgpu_backing: ^Wgpu_Window,   // WebGPU: allocated by surface_init
	valid:        bool,
	held:         bool,           // surface_use gave it to the renderer: what it keeps now is the window the renderer had
}

// The window's state changes hands whole. Byte by byte, not `a, b = b, a`: a value of this size is what surface_create warns of.
@(private)
exchange :: proc(r: ^Renderer, s: ^Surface) {
	slice.ptr_swap_non_overlapping(&r.target, &s.target, size_of(Window_Target))
}

// The window the renderer holds now was set aside while the device was recreated (recover: only the window in use is remade, with
// everything else on the device) or the blend space changed: its swap chain and views belong to the old device, or to the old space.
// A window that cannot be remade is a device lost: the next frame_begin makes everything again, this window with it. Direct3D 11 (WebGPU:
// wgpu_surface_refresh).
@(private)
surface_refresh :: proc(r: ^Renderer) {
	when !USE_WGPU {
	if r.swap_gen != r.device_generation {
		rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
		old_device: ^d3d11.IDevice   // the device they were made on: they keep it alive
		if r.swapchain != nil { r.swapchain->GetDevice(d3d11.IDevice_UUID, (^rawptr)(&old_device)) }
		rel(&r.rtv); rel(&r.frame_tex)
		if r.hwnd == nil { rel(&r.offscreen) }
		release_presentation(r)
		if r.latency_handle != nil { win.CloseHandle(r.latency_handle); r.latency_handle = nil }
		capture_release_device_objects(&r.capture)
		d3d_damage_release(&r.damage)
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
			r.transparent = r.transparent_asked
			ok = create_swapchain(r, sized_by_surface = true)   // the window may not have a size yet: the swap chain gets the one of the surface
		}
		if !ok {
			fmt.eprintln("render: a window could not be remade after the device was recreated")
			r.lost = true
		}
		r.swap_gen, r.swap_space = r.device_generation, r.space_epoch
	} else if r.swap_space != r.space_epoch {
		retarget(r)
		r.swap_space = r.space_epoch
	}
	}
}

// A swap chain for the window `hwnd`, on the renderer's device. By default an HWND swap chain (opaque): its buffers map onto the
// client area, so a window being resized shows the last frame stretched until a frame of the new size arrives.
// `transparent`: a composition swap chain, as render.init's (open the window with platform's `transparent` too, which gives it
// no GDI surface); the blend space is the renderer's. With it, `fixed_size` (> 0) is what set_fixed_surface does for the
// renderer's own window: the buffers keep that size (the monitor's, say) while the window is resized, shown 1:1 and clipped by the
// client area, so nothing is ever stretched. Where DirectComposition is missing the surface is an opaque HWND chain, as render.init's.
// `under_children`: a composition surface goes above the window's child windows, and one moved into the window from elsewhere (a web
// view) would be hidden behind it: this puts it below them. Direct3D (fixed_size neither has a meaning on WebGPU).
// `surface_init` makes it in the Surface `s` points to, where the program keeps it. Prefer it to `surface_create`.
surface_init :: proc(r: ^Renderer, s: ^Surface, handles: platform.Surface_Handles, size: [2]int, transparent := false, fixed_size := [2]int{}, under_children := false) -> (ok: bool) {
	when USE_WGPU {
		// a second window on WebGPU: its own wgpu surface (and the latency / present state that go with it), swapped with the
		// renderer's by surface_use, exactly as the Direct3D path swaps its swap chain. fixed_size is Direct3D's composition
		// trick (buffers kept one size while the window resizes); wgpu reconfigures on resize, so it is ignored here.
		s^ = {}
		ok = wgpu_surface_init(r, s, handles, size, transparent)
		s.valid = ok
		return
	} else {
		s^ = {}
		s.hwnd, s.size = win.HWND(handles.hwnd), size
		exchange(r, s)   // the renderer is the other window's for a moment: create_swapchain makes the chain it has
		r.transparent, r.transparent_asked = transparent, transparent
		r.under_children = under_children
		r.fixed_surface = false
		ok = create_swapchain(r, sized_by_surface = true)
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
surface_create :: proc(r: ^Renderer, handles: platform.Surface_Handles, size: [2]int, transparent := false, fixed_size := [2]int{}, under_children := false) -> (s: Surface, ok: bool) {
	ok = surface_init(r, &s, handles, size, transparent, fixed_size, under_children)
	return
}

// Releases the surface. The one in use gives the renderer back its window first.
surface_destroy :: proc(r: ^Renderer, s: ^Surface) {
	if s.valid && s.held { surface_use(r, s) }
	when USE_WGPU {
		if !s.valid { return }
		wgpu_surface_destroy(r, s)
		s^ = {}
		return
	}
	when !USE_WGPU {
		if !s.valid { return }
		exchange(r, s)
		r.ctx->OMSetRenderTargets(0, nil, nil)
		if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
		if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
		release_presentation(r)   // the swap chain and a translucent window's DirectComposition objects (render.odin)
		if r.latency_handle != nil { win.CloseHandle(r.latency_handle); r.latency_handle = nil }
		capture_destroy(r)
		d3d_damage_release(&r.damage)
		present_destroy(r)
		exchange(r, s)
		s^ = {}
	}
}

// Makes `s` the window the renderer draws to (its own surface goes into `s`). Call again with the same `s` to go back.
surface_use :: proc(r: ^Renderer, s: ^Surface) {
	if !s.valid { return }
	s.held = !s.held
	when USE_WGPU { wgpu_surface_use(r, s) } else {
		exchange(r, s)
		surface_refresh(r)
	}
}

// The window of the current surface leaves the screen (platform.hide_window): its surface and swap chain go before the
// window's native surface does (Wayland destroys it). No frame is drawn until surface_remake. Direct3D's swap chain
// survives a hide: nothing to do.
surface_drop :: proc(r: ^Renderer) {
	when USE_WGPU { wgpu_surface_drop(r) }
}

// The window of the current surface came back on the screen (platform.show_window after a hide): a surface on its native
// handles now (new ones on Wayland), configured at the next frame. Direct3D: nothing to do.
surface_remake :: proc(r: ^Renderer, handles: platform.Surface_Handles) {
	when USE_WGPU { wgpu_surface_make_again(r, handles) }
}

// surface_use until the end of the calling scope: no way out of a frame forgets to go back.
@(deferred_in = surface_use)
surface_scope :: proc(r: ^Renderer, s: ^Surface) { surface_use(r, s) }

_ :: fmt
_ :: win     // (the three: used in Direct3D's branches only)
_ :: d3d11
