#+build windows
package render

// The Direct3D 11 backend: device, swap chain, DirectComposition for translucent windows, the instanced-quad pipeline,
// textures, pooled targets, GPU timing, presentation teardown. It was split out of render.odin (which keeps the shared
// types and the backend-agnostic procedures) so that the package builds on systems without Direct3D, where only the
// wgpu backend is compiled. Everything here is reached through api.odin's `when !USE_WGPU` dispatch, so it is never
// referenced on Linux; it names Win32, DXGI and DirectComposition freely.

import "core:fmt"
import "core:mem"
import "base:runtime"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"
import "../platform"

// This whole file is the Direct3D 11 backend: it builds only when the renderer uses it (`!USE_WGPU`), which on Windows
// is the default and never the case on another system. `#+build windows` keeps it off non-Windows targets; `when
// !USE_WGPU` keeps it off a Windows build that chose the wgpu backend (-define:TOOLKIT_RENDER=wgpu).
when !USE_WGPU {

// `transparent`: the window shows through wherever the frame has alpha < 1 (open the window with `transparent` too).
// Clear to {0, 0, 0, 0} and draw translucent colours; the output is premultiplied, which is what blending onto a
// transparent clear produces anyway. `space`: what the frame blends in (set_blend_space changes it later).
d3d_init :: proc(r: ^Renderer, surface: platform.Surface_Handles, size: [2]int, transparent := false, space := Blend_Space.Linear) -> bool {
	r.hwnd = win.HWND(surface.hwnd)
	r.size = size
	r.transparent = transparent
	r.space = space
	create_device(r, .HARDWARE) or_return
	create_swapchain(r) or_return
	return init_pipeline(r)
}

// The swap chain of the window (a composition one when translucent), its waitable object and the frame's view.
@(private)
create_swapchain :: proc(r: ^Renderer) -> bool {
	hwnd, size, transparent := r.hwnd, r.size, r.transparent
	dxgi_device: ^dxgi.IDevice
	r.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	adapter: ^dxgi.IAdapter
	dxgi_device->GetAdapter(&adapter)
	factory: ^dxgi.IFactory2
	adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))
	defer { factory->Release(); adapter->Release(); dxgi_device->Release() }

	desc := dxgi.SWAP_CHAIN_DESC1{
		Width       = surface_creating ? u32(size.x) : 0, Height = surface_creating ? u32(size.y) : 0,   // (a second window: its size, as the window has none yet at that point)
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = u32(clamp(r.swap_buffers, 2, 16) if r.swap_buffers > 0 else 2),
		// STRETCH: the presented region (SetSourceSize, see resize) maps onto the client area 1:1 when it has the
		// window's size. (With NONE, DWM drew a source region smaller than the buffers magnified.) A frame that
		// comes after the window changed size is stretched for the refresh it is shown in.
		Scaling     = .STRETCH,
		SwapEffect  = .FLIP_DISCARD,
		AlphaMode   = .UNSPECIFIED,
	}
	when LOW_LATENCY { desc.Flags = {.FRAME_LATENCY_WAITABLE_OBJECT} }
	// tearing presents (variable refresh) need the flag from creation on; a composition swap chain cannot tear
	r.present.tearing_ok = !transparent && check_tearing(factory)
	if r.present.tearing_ok { desc.Flags += {.ALLOW_TEARING} }
	r.swap_flags = desc.Flags
	present_reset(r)
	// translucent: through DirectComposition; where that is missing (Wine, old systems) fall back to an opaque window
	if transparent && !init_composition(r, factory, dxgi_device, hwnd, desc, size) {
		fmt.eprintln("render: DirectComposition unavailable, the window is opaque")
		r.transparent = false
	}
	if !r.transparent {
		if hr := factory->CreateSwapChainForHwnd(r.device, hwnd, &desc, nil, nil, &r.swapchain); win.FAILED(hr) {
			fmt.eprintln("render: CreateSwapChainForHwnd failed", hr)
			return false
		}
	}
	factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER})
	when LOW_LATENCY {
		sc2: ^dxgi.ISwapChain2
		if win.SUCCEEDED(r.swapchain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&sc2))) {
			sc2->SetMaximumFrameLatency(1)
			r.latency_handle = sc2->GetFrameLatencyWaitableObject()
			sc2->Release()
		}
	}
	create_target(r)
	r.source_size = r.buffer_size
	return true
}

// Releases every GPU object and the renderer's memory (textures still alive included). The renderer can be
// initialized again afterwards.
d3d_destroy :: proc(r: ^Renderer) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	canvas_pipeline_release(r)
	for i in 1 ..< len(r.textures) { destroy_texture(r, Texture(i)) }
	canvas_pipeline_free(r)
	delete(r.textures); delete(r.free_textures); delete(r.targets); delete(r.scratch); delete(r.zeros)
	for &q in r.gpu_queries { for &x in q { rel(&x) } }
	profile_destroy(r)
	video_pipeline_destroy(r)
	d3d_app_objects_release(r)
	app_shaders_destroy(r)
	rel(&r.xform_view); rel(&r.xform_buf); rel(&r.clip_view); rel(&r.clip_buf); rel(&r.inst_buf); rel(&r.globals)
	rel(&r.points_view); rel(&r.points_buf); rel(&r.blend_replace); rel(&r.fx_vs); rel(&r.fx_ps); rel(&r.fx_constants)
	rel(&r.sampler_border); rel(&r.frame_tex); rel(&r.grads_view); rel(&r.grads_buf); rel(&r.replay_cb)
	rel(&r.damage_clear_vb); rel(&r.damage_verify_rtv); rel(&r.damage_verify_ref)
	heaps_destroy(r)
	rel(&r.sampler); rel(&r.sampler_img); rel(&r.sampler_wrap); rel(&r.raster); rel(&r.blend)
	rel(&r.layout); rel(&r.ps); rel(&r.vs); rel(&r.rtv); rel(&r.offscreen)
	slug_destroy(r)
	capture_destroy(r)
	release_presentation(r)
	if r.latency_handle != nil { win.CloseHandle(r.latency_handle) }
	present_destroy(r)
	if r.ctx != nil { r.ctx->ClearState() }
	rel(&r.ctx); rel(&r.device)
	r^ = {}
}

// A renderer without a window: frames are drawn into an offscreen B8G8R8A8 (sRGB) image of `size` that
// `read_pixels` returns. For tests and image export. `warp`: the software rasterizer (deterministic, no GPU needed).
d3d_init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false, space := Blend_Space.Linear) -> bool {
	r.size = size
	r.space = space
	r.warp = warp
	if !create_device(r, warp ? .WARP : .HARDWARE) {
		if warp || !create_device(r, .WARP) { return false }
		r.warp = true
	}
	create_offscreen_target(r) or_return
	return init_pipeline(r)
}

@(private)
create_offscreen_target :: proc(r: ^Renderer) -> bool {
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
	}, nil, &r.offscreen)
	if r.offscreen == nil { return false }
	r.frame_tex = r.offscreen
	r.frame_tex->AddRef()
	// typeless storage: the view is chosen by the blend space (like the swap chain's), the readback copies raw bytes
	return create_offscreen_view(r)
}

@(private)
create_offscreen_view :: proc(r: ^Renderer) -> bool {
	r.frame_format = .B8G8R8A8_TYPELESS
	r.frame_view = r.space == .Srgb ? .B8G8R8A8_UNORM : .B8G8R8A8_UNORM_SRGB
	r.device->CreateRenderTargetView(r.offscreen, &{Format = r.frame_view, ViewDimension = .TEXTURE2D}, &r.rtv)
	return r.rtv != nil
}

// Remake the offscreen target at `size` (a headless window that resized). The old target, its view and the frame
// texture are released first. False (the old one is kept): no device, or the new target could not be made.
@(private)
d3d_resize_offscreen :: proc(r: ^Renderer, size: [2]int) -> bool {
	if r.offscreen == nil || r.device == nil { return false }
	r.ctx->OMSetRenderTargets(0, nil, nil)
	old_tex, old_rtv, old_off := r.frame_tex, r.rtv, r.offscreen
	prev := r.size
	r.size = size
	r.rtv, r.frame_tex, r.offscreen = nil, nil, nil
	if !create_offscreen_target(r) {
		// put the old target back: the renderer stays usable
		r.size = prev
		r.offscreen, r.frame_tex, r.rtv = old_off, old_tex, old_rtv
		return false
	}
	r.buffer_size, r.source_size = size, size
	if old_rtv != nil { old_rtv->Release() }
	if old_tex != nil { old_tex->Release() }
	if old_off != nil { old_off->Release() }
	return true
}

// Changes what the frame blends in (see Blend_Space) and resets the text rendering to that space's default
// (text_rendering_default; call set_text_rendering afterwards to keep your own). Pooled targets are released (snapshots
// of the frame are read in its space). Existing RGBA textures keep the space they were stored in and are converted
// when drawn; layers keep their own. Call it between frames.
d3d_set_blend_space :: proc(r: ^Renderer, space: Blend_Space) {
	if space == r.space { return }
	previous := r.space
	r.space = space
	r.text = text_rendering_default(space)
	release_targets(r)
	r.space_epoch += 1
	retarget(r, previous)
	r.swap_space = r.space_epoch
}

// The window the renderer holds draws in `r.space`: its render target view (and, for a translucent window, its buffers' format) is
// made again. For a window that was set aside (surface_use) while the space changed: surface_refresh, which has no space to go
// back to. `previous` (set_blend_space): the space to stay in when the buffers cannot take the format.
@(private)
retarget :: proc(r: ^Renderer, previous: Maybe(Blend_Space) = nil) {
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	if r.swapchain == nil && r.offscreen != nil {
		create_offscreen_view(r)
		return
	}
	if r.swapchain == nil { return }
	if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
	if r.transparent {
		// a translucent window's buffers change format: linear fp16 (scRGB) or 8-bit premultiplied sRGB
		b := r.buffer_size
		if b.x <= 0 || b.y <= 0 { b = r.size }
		if hr := r.swapchain->ResizeBuffers(0, u32(max(b.x, 1)), u32(max(b.y, 1)), composition_format(r.space), r.swap_flags); win.FAILED(hr) {
			fmt.eprintln("render: ResizeBuffers to the format of the blend space failed", hr)
			if prev, ok := previous.?; ok {
				fmt.eprintln("render: staying in", prev)
				r.space = prev
				r.text = text_rendering_default(prev)
			}
		}
		set_composition_color_space(r)
	}
	create_target(r)
	if r.transparent {
		r.source_size = r.buffer_size   // ResizeBuffers presents the whole buffers again
		if !r.fixed_surface && r.size != r.buffer_size && !set_source_size(r, r.size) { resize_buffers(r, r.size) }
	}
}

// The offscreen image (init_offscreen) after the last frame: RGBA8, sRGB, `size.x * size.y * 4` bytes (whatever the
// blend space: in Linear the view encodes, in Srgb the values are stored as they are).
d3d_read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	if r.offscreen == nil { return nil }
	staging: ^d3d11.ITexture2D
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
	}, nil, &staging)
	if staging == nil { return nil }
	defer staging->Release()
	r.ctx->CopyResource(staging, r.offscreen)
	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.FAILED(r.ctx->Map(staging, 0, .READ, {}, &mapped)) { return nil }
	defer r.ctx->Unmap(staging, 0)
	out := make([]u8, r.size.x * r.size.y * 4, allocator)
	for y in 0 ..< r.size.y {
		row := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(y * int(mapped.RowPitch))), r.size.x * 4)
		for x in 0 ..< r.size.x {
			o := (y * r.size.x + x) * 4
			out[o], out[o + 1], out[o + 2], out[o + 3] = row[x * 4 + 2], row[x * 4 + 1], row[x * 4], row[x * 4 + 3]
		}
	}
	return out
}

@(private)
create_device :: proc(r: ^Renderer, driver: d3d11.DRIVER_TYPE) -> bool {
	feature_levels := [?]d3d11.FEATURE_LEVEL{._11_0}
	base_device: ^d3d11.IDevice
	base_ctx: ^d3d11.IDeviceContext
	// VIDEO_SUPPORT: hardware decoders (Media Foundation / DXVA) work on this device and hand their pictures to it as textures
	flags := d3d11.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT, .VIDEO_SUPPORT}
	when D3D_DEBUG { flags += {.DEBUG} }
	hr := d3d11.CreateDevice(nil, driver, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx)
	if win.FAILED(hr) && .VIDEO_SUPPORT in flags {
		// (the software rasterizer has no video support: no hardware decoding there anyway)
		flags -= {.VIDEO_SUPPORT}
		hr = d3d11.CreateDevice(nil, driver, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx)
	}
	if win.FAILED(hr) {
		fmt.eprintln("render: CreateDevice failed", hr)
		return false
	}
	base_device->QueryInterface(d3d11.IDevice_UUID, (^rawptr)(&r.device))
	base_ctx->QueryInterface(d3d11.IDeviceContext_UUID, (^rawptr)(&r.ctx))
	base_device->Release()
	base_ctx->Release()
	return true
}

// Shaders, input layout, constant buffer and fixed states: everything after the device and the frame target.
@(private)
init_pipeline :: proc(r: ^Renderer) -> bool {
	vs_code, vs_blob := shader_code(.Rect_VS) or_return
	defer shader_code_done(vs_blob)
	ps_code, ps_blob := shader_code(.Rect_PS) or_return
	defer shader_code_done(ps_blob)
	r.device->CreateVertexShader(raw_data(vs_code), uint(len(vs_code)), nil, &r.vs)
	r.device->CreatePixelShader(raw_data(ps_code), uint(len(ps_code)), nil, &r.ps)
	if r.vs == nil || r.ps == nil {
		fmt.eprintln("render: the instanced-quad shaders were refused by the device")
		return false
	}

	r.layout = create_instance_layout(r, vs_code)
	if r.layout == nil { return false }

	r.device->CreateBuffer(&{ByteWidth = size_of(Globals), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.globals)
	r.device->CreateBuffer(&{ByteWidth = size_of(Replay_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.replay_cb)
	if r.globals == nil || r.replay_cb == nil { return false }

	bd := d3d11.BLEND_DESC{}
	bd.RenderTarget[0] = {
		BlendEnable = true,
		SrcBlend = .SRC_ALPHA, DestBlend = .INV_SRC_ALPHA, BlendOp = .ADD,
		SrcBlendAlpha = .ONE, DestBlendAlpha = .INV_SRC_ALPHA, BlendOpAlpha = .ADD,
		RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL),
	}
	r.device->CreateBlendState(&bd, &r.blend)
	r.device->CreateRasterizerState(&{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true}, &r.raster)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP}, &r.sampler)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = max(f32)}, &r.sampler_img)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .WRAP, AddressV = .WRAP, AddressW = .CLAMP, MaxLOD = max(f32)}, &r.sampler_wrap)

	bd.RenderTarget[0] = {BlendEnable = false, RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL)}
	r.device->CreateBlendState(&bd, &r.blend_replace)
	d3d_app_blend_states(r)
	d3d_app_empty_texture(r)
	// filter passes and reduced layers: the shader makes the transparent border itself (sample_border: the same code runs on WebGPU)
	r.device->CreateSamplerState(&{Filter = .MIN_MAG_MIP_LINEAR, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP}, &r.sampler_border)
	fx_vs_code, fx_vs_blob := shader_code(.Filter_VS) or_return
	defer shader_code_done(fx_vs_blob)
	fx_ps_code, fx_ps_blob := shader_code(.Filter_PS) or_return
	defer shader_code_done(fx_ps_blob)
	r.device->CreateVertexShader(raw_data(fx_vs_code), uint(len(fx_vs_code)), nil, &r.fx_vs)
	r.device->CreatePixelShader(raw_data(fx_ps_code), uint(len(fx_ps_code)), nil, &r.fx_ps)
	r.device->CreateBuffer(&{ByteWidth = size_of(Pass_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.fx_constants)
	if r.fx_vs == nil || r.fx_ps == nil || r.fx_constants == nil || r.blend_replace == nil || r.sampler_border == nil { return false }

	if len(r.textures) > 0 { return true }   // recover: the settings stay
	append(&r.textures, Texture_Data{})   // dummy slot 0
	r.corner_smoothing = 1
	r.blur_sigma_limit = DEFAULT_BLUR_SIGMA_LIMIT
	r.text = text_rendering_default(r.space)
	return true
}

// The input layout of Rect_Inst for the vertex shaders (rect and Slug): nine attributes, naga's semantics (LOC0..LOC8, the
// @location of the WGSL: eight float4 then the uint4 `extra`).
@(private)
create_instance_layout :: proc(r: ^Renderer, vs_code: []u8) -> ^d3d11.IInputLayout {
	elem :: proc(loc: u32, format: dxgi.FORMAT) -> d3d11.INPUT_ELEMENT_DESC {
		return {SemanticName = "LOC", SemanticIndex = loc, Format = format, InputSlot = 0, AlignedByteOffset = loc * 16,
		        InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1}
	}
	elems: [9]d3d11.INPUT_ELEMENT_DESC
	for i in 0 ..< 8 { elems[i] = elem(u32(i), .R32G32B32A32_FLOAT) }
	elems[8] = elem(8, .R32G32B32A32_UINT)
	layout: ^d3d11.IInputLayout
	if hr := r.device->CreateInputLayout(&elems[0], len(elems), raw_data(vs_code), uint(len(vs_code)), &layout); win.FAILED(hr) {
		fmt.eprintln("render: CreateInputLayout failed", hr)
		return nil
	}
	return layout
}

// Swap chain format of a translucent window: DWM composes scRGB (linear fp16) in linear light, and 8-bit buffers as
// premultiplied sRGB values, which is exactly what each blend space produces.
@(private)
composition_format :: proc(space: Blend_Space) -> dxgi.FORMAT {
	return space == .Srgb ? .B8G8R8A8_UNORM : .R16G16B16A16_FLOAT
}

// Tells DWM how to read a translucent window's buffers: a swap chain keeps its color space through ResizeBuffers, so an
// fp16 chain switched to 8 bits would still be read as linear (and look washed out).
@(private)
set_composition_color_space :: proc(r: ^Renderer) {
	sc3: ^dxgi.ISwapChain3
	if r.swapchain == nil || win.FAILED(r.swapchain->QueryInterface(dxgi.ISwapChain3_UUID, (^rawptr)(&sc3))) { return }
	sc3->SetColorSpace1(r.space == .Srgb ? .RGB_FULL_G22_NONE_P709 : .RGB_FULL_G10_NONE_P709)
	sc3->Release()
}

@(private)
init_composition :: proc(r: ^Renderer, factory: ^dxgi.IFactory2, dxgi_device: ^dxgi.IDevice, hwnd: win.HWND, base: dxgi.SWAP_CHAIN_DESC1, size: [2]int) -> bool {
	desc := base
	desc.Width, desc.Height = u32(max(size.x, 1)), u32(max(size.y, 1))
	desc.Scaling = .STRETCH
	desc.AlphaMode = .PREMULTIPLIED
	// Linear: scRGB (linear fp16), composed by DWM in linear light like our blending. Srgb: 8-bit, which DWM takes as
	// premultiplied sRGB values, our output in that space (a linear output there would look washed out).
	desc.Format = composition_format(r.space)
	if win.FAILED(factory->CreateSwapChainForComposition(r.device, &desc, nil, &r.swapchain)) { return false }
	set_composition_color_space(r)
	ok := win.SUCCEEDED(DCompositionCreateDevice((^win.IUnknown)(dxgi_device), IDCompositionDevice_UUID, (^rawptr)(&r.dcomp)))
	ok = ok && win.SUCCEEDED(r.dcomp->CreateTargetForHwnd(hwnd, true, &r.dcomp_target))
	ok = ok && win.SUCCEEDED(r.dcomp->CreateVisual(&r.dcomp_visual))
	ok = ok && win.SUCCEEDED(r.dcomp_visual->SetContent((^win.IUnknown)(r.swapchain)))
	ok = ok && win.SUCCEEDED(r.dcomp_target->SetRoot(r.dcomp_visual))
	ok = ok && win.SUCCEEDED(r.dcomp->Commit())
	if !ok {
		if r.dcomp_visual != nil { r.dcomp_visual->Release(); r.dcomp_visual = nil }
		if r.dcomp_target != nil { r.dcomp_target->Release(); r.dcomp_target = nil }
		if r.dcomp != nil { r.dcomp->Release(); r.dcomp = nil }
		r.swapchain->Release()
		r.swapchain = nil
	}
	return ok
}

@(private)
compile :: proc(src: string, entry, target: cstring, name: cstring = "shader.hlsl") -> (blob: ^d3d11.IBlob, ok: bool) {
	errors: ^d3d11.IBlob
	hr := d3d_compiler.Compile(raw_data(src), uint(len(src)), name, nil, nil, entry, target, 0, 0, &blob, &errors)
	if win.FAILED(hr) {
		if errors != nil {
			fmt.eprintln("render: shader error:", string(mem.slice_ptr(cast([^]u8)errors->GetBufferPointer(), int(errors->GetBufferSize()))))
			errors->Release()
		}
		return nil, false
	}
	return blob, true
}

@(private)
create_target :: proc(r: ^Renderer) {
	backbuffer: ^d3d11.ITexture2D
	r.swapchain->GetBuffer(0, d3d11.ITexture2D_UUID, (^rawptr)(&backbuffer))
	// Linear: an sRGB view over a UNORM buffer: the shader writes linear colors, the hardware encodes (and blends in
	// linear light). Srgb: a UNORM view: the shader writes sRGB values, blended as they are.
	fp16 := r.transparent && r.space == .Linear
	r.frame_format = fp16 ? .R16G16B16A16_FLOAT : .B8G8R8A8_UNORM
	r.frame_view = fp16 ? .R16G16B16A16_FLOAT : (r.space == .Srgb ? .B8G8R8A8_UNORM : .B8G8R8A8_UNORM_SRGB)
	r.device->CreateRenderTargetView(backbuffer, &{Format = r.frame_view, ViewDimension = .TEXTURE2D}, &r.rtv)
	// kept for snapshots (backdrop filters, blend modes); with flip swap chains buffer 0 is always the one drawn
	r.frame_tex = backbuffer
	// the buffers' own size (resize may keep them larger than what is shown)
	if backbuffer != nil {
		desc: d3d11.TEXTURE2D_DESC
		backbuffer->GetDesc(&desc)
		r.buffer_size = {int(desc.Width), int(desc.Height)}
	}
}

// The window's client area is now `size`. ResizeBuffers is costly (1.6 to 3.5 ms a call: DXGI enumerates the outputs
// each time), so with a resize slack (set_resize_slack) the buffers are allocated with room to grow and a size that
// fits in them is only a new source region of the swap chain (IDXGISwapChain2::SetSourceSize, a few microseconds):
// a window dragged to a new size reallocates once per `slack` pixels crossed instead of at every step. The buffers are
// made smaller again once they hold more than twice the pixels shown. Without SetSourceSize (or with a slack of 0)
// the buffers follow the size exactly.
d3d_resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size || r.swapchain == nil { return }
	if r.fixed_surface {
		// The surface keeps its size: the window shows its top-left `size` pixels, 1:1, clipped by the client area (see
		// set_fixed_surface). Grown beyond the surface, the buffers follow (one step shown scaled by the system).
		r.size = size
		if size.x > r.surface_max.x || size.y > r.surface_max.y {
			r.surface_max = size
			resize_buffers(r, size)
		}
		return
	}
	r.size = size
	slack := resize_slack(r)
	b := r.buffer_size
	fits := size.x <= b.x && size.y <= b.y && b.x * b.y <= 2 * size.x * size.y
	if slack > 0 && fits && set_source_size(r, size) { return }
	want := size
	if slack > 0 { want = {(size.x + slack - 1) / slack * slack, (size.y + slack - 1) / slack * slack} }
	resize_buffers(r, want)
	if want != size && !set_source_size(r, size) {
		resize_buffers(r, size)   // no source region here: buffers of the exact size, as without a slack
		r.resize_slack = -1
	}
}

// A window grown beyond `max_size` resizes the buffers to it. False: no composition swap chain.
d3d_set_fixed_surface :: proc(r: ^Renderer, max_size: [2]int) -> bool {
	if !r.transparent || r.swapchain == nil || max_size.x <= 0 || max_size.y <= 0 { return false }
	r.fixed_surface = true
	r.surface_max = max_size
	resize_buffers(r, max_size)
	r.source_size = r.buffer_size
	return true
}

@(private)
resize_buffers :: proc(r: ^Renderer, size: [2]int) {
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	if r.frame_tex != nil { r.frame_tex->Release(); r.frame_tex = nil }
	r.swapchain->ResizeBuffers(0, u32(size.x), u32(size.y), .UNKNOWN, r.swap_flags)   // flags must match creation
	create_target(r)
	r.source_size = r.buffer_size   // ResizeBuffers presents the whole buffers again
}

// Presents only the region [0, size) of the buffers. false: not available (the buffers must be the size shown).
@(private)
set_source_size :: proc(r: ^Renderer, size: [2]int) -> bool {
	if size == r.source_size { return true }
	if size.x > r.buffer_size.x || size.y > r.buffer_size.y { return false }
	sc2: ^dxgi.ISwapChain2
	if win.FAILED(r.swapchain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&sc2))) || sc2 == nil { return false }
	defer sc2->Release()
	if win.FAILED(sc2->SetSourceSize(u32(size.x), u32(size.y))) { return false }
	r.source_size = size
	return true
}

// A single-channel (coverage) texture, used for the glyph atlas.
d3d_create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	td := Texture_Data{size = size, w = size, h = size, kind = .R8}
	if !texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

// The GPU texture and view of an R8 or RGBA texture described by `td` (kind, size, mips, space), contents zeroed
// (D3D leaves DEFAULT textures undefined). Used by the create procs and to recreate textures after a device loss.
@(private)
texture_objects :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	if td.canvas != 0 { return canvas_texture_objects(r, td) }
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(td.w), Height = u32(td.h), MipLevels = 1, ArraySize = 1, Format = .R8_UNORM,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	texel := 1
	if td.kind == .RGBA {
		desc.Format = td.space == .Srgb ? .R8G8B8A8_UNORM : .R8G8B8A8_UNORM_SRGB
		texel = 4
		if td.mips { desc.MipLevels = 0; desc.BindFlags += {.RENDER_TARGET}; desc.MiscFlags = {.GENERATE_MIPS} }
	}
	if td.kind == .Data {
		if td.data_format == .RGBA8 { desc.Format, texel = .R8G8B8A8_UNORM, 4 }
		if td.mips { desc.MipLevels = 0; desc.BindFlags += {.RENDER_TARGET}; desc.MiscFlags = {.GENERATE_MIPS} }
	}
	#partial switch td.kind {
	case .Slug_Curves: desc.Format, texel = .R16G16B16A16_FLOAT, 8
	case .Slug_Bands: desc.Format, texel = .R16G16_UINT, 4
	}
	if win.FAILED(r.device->CreateTexture2D(&desc, nil, &td.tex)) { td.tex = nil; return false }
	if win.FAILED(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); td.tex, td.view = nil, nil; return false }
	if td.kind == .RGBA {
		// an image is nearly always written whole right after (update_texture_rgba): the zeroing waits for the first
		// frame that draws it (zero_unfilled), and not at all when the whole texture is written before that. Zeroing here
		// took one driver call per row, 1 to 4 ms for a photo.
		td.unfilled = true
		td.mips_dirty = false
		return true
	}
	zero := make([]u8, td.w * texel)
	defer delete(zero)
	for y in 0 ..< td.h {
		box := d3d11.BOX{left = 0, top = u32(y), front = 0, right = u32(td.w), bottom = u32(y + 1), back = 1}
		r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(zero), u32(td.w * texel), 0)
	}
	td.mips_dirty = td.mips
	return true
}

// Writes zeros into an RGBA texture nothing was written to (see Texture_Data.unfilled): one UpdateSubresource of the
// whole level 0 (its mips follow), through a zeroed buffer made once and kept.
@(private)
zero_unfilled :: proc(r: ^Renderer, td: ^Texture_Data) {
	td.unfilled = false
	rows := max(1, min(td.h, (1 << 20) / (td.w * 4)))
	if len(r.zeros) < rows * td.w * 4 { runtime.resize(&r.zeros, rows * td.w * 4); mem.zero_slice(r.zeros[:]) }
	for y := 0; y < td.h; y += rows {
		box := d3d11.BOX{left = 0, top = u32(y), front = 0, right = u32(td.w), bottom = u32(min(y + rows, td.h)), back = 1}
		r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(r.zeros), u32(td.w * 4), 0)
	}
	td.mips_dirty = td.mips
}

d3d_update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	if int(t) <= 0 || int(t) >= len(r.textures) || w <= 0 || h <= 0 { return }
	td := r.textures[int(t)]
	// (as the other upload: a destroyed texture, a block outside it or pixels too short for it write nothing)
	if td.tex == nil || x < 0 || y < 0 || x + w > td.w || y + h > td.h || len(pixels) < pitch * (h - 1) + w { return }
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
}

// Largest width / height `create_texture_rgba` accepts (from the device's feature level).
d3d_max_texture_size :: proc(r: ^Renderer) -> int {
	#partial switch r.device->GetFeatureLevel() {
	case ._9_1, ._9_2: return 2048
	case ._9_3: return 4096
	case ._10_0, ._10_1: return 8192
	}
	return d3d11.REQ_TEXTURE2D_U_OR_V_DIMENSION
}

// A color image for `draw.image`. See create_texture_rgba for the storage rules.
d3d_create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	limit := max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA, space = r.space}
	format: dxgi.FORMAT = td.space == .Srgb ? .R8G8B8A8_UNORM : .R8G8B8A8_UNORM_SRGB
	support: u32
	r.device->CheckFormatSupport(format, &support)
	td.mips = mips && support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0 && (w > 1 || h > 1)
	if !texture_objects(r, &td) { return 0 }   // starts transparent
	return add_texture(r, td)
}

// Uploads a w x h block at (x, y). `pixels`: RGBA8, sRGB encoded, NOT premultiplied; `stride` = bytes per row (0: w * 4).
d3d_update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind != .RGBA || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
	pitch := stride > 0 ? stride : w * 4
	if len(pixels) < pitch * (h - 1) + w * 4 { return }
	if td.unfilled {
		if x == 0 && y == 0 && w == td.w && h == td.h { td.unfilled = false } else { zero_unfilled(r, td) }
	}
	data, row, _ := premultiply_upload(r, td, w, h, pixels, pitch)
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, data, u32(row), 0)
	if td.mips { td.mips_dirty = true }
}

// A data texture: raw 8-bit values the shaders of draw.app_shader read as they are. Same limits as create_texture_rgba.
d3d_create_texture_data :: proc(r: ^Renderer, w, h: int, format: Data_Format, mips: bool) -> Texture {
	limit := max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .Data, data_format = format}
	support: u32
	r.device->CheckFormatSupport(format == .R8 ? .R8_UNORM : .R8G8B8A8_UNORM, &support)
	td.mips = mips && support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0 && (w > 1 || h > 1)
	if !texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

d3d_update_texture_data :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride: int) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	texel := td.data_format == .R8 ? 1 : 4
	if td.kind != .Data || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
	pitch := stride > 0 ? stride : w * texel
	if len(pixels) < pitch * (h - 1) + w * texel { return }
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
	if td.mips { td.mips_dirty = true }
}

// Frees the GPU texture; the handle may be reused by a later create. Drawing a destroyed texture draws nothing.
d3d_destroy_texture :: proc(r: ^Renderer, t: Texture) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind == .None { return }
	if td.canvas == 2 { canvas_state_free(r, t) }
	td = &r.textures[int(t)]
	if td.rtv != nil { td.rtv->Release() }
	if td.view != nil { td.view->Release() }
	if td.tex != nil { td.tex->Release() }
	td^ = {}
	append(&r.free_textures, t)
}

// Blocks until the swap chain can take a new frame (returns at once when nothing is queued). Call it BEFORE
// polling input and building the UI: then the frame you build is the next one shown.
d3d_wait_for_frame :: proc(r: ^Renderer, timeout_ms := 100) -> bool {
	if r.latency_handle == nil { return true }
	latency_drain(&r.present, r.latency_handle)
	return win.WaitForSingleObjectEx(r.latency_handle, u32(max(timeout_ms, 0)), true) == win.WAIT_OBJECT_0
}

// Clears the frame to `clear`: linear, premultiplied (the same thing for an opaque color), whatever the blend space.
d3d_frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	if r.lost && !recover(r) { return }
	c := clear
	if r.space == .Srgb && c.a > 0 {
		for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a }
	}
	// A partial frame does not clear the whole back buffer (the kept content outside the region must survive): the
	// region is cleared per rectangle in d3d_frame_submit, inside the scissor.
	if r.damage.mode == .On && r.damage.building {
		r.damage.clear = c
		r.damage.have_clear = true
		return
	}
	r.damage.have_clear = false
	r.ctx->ClearRenderTargetView(r.rtv, &c)
}

@(private)
gpu_timing_begin :: proc(r: ^Renderer) {
	q := &r.gpu_queries[r.gpu_frame % GPU_QUERY_FRAMES]
	if q[0] == nil {
		r.device->CreateQuery(&{Query = .TIMESTAMP_DISJOINT}, &q[0])
		r.device->CreateQuery(&{Query = .TIMESTAMP}, &q[1])
		r.device->CreateQuery(&{Query = .TIMESTAMP}, &q[2])
	} else if r.gpu_frame >= GPU_QUERY_FRAMES {
		// this slot was issued GPU_QUERY_FRAMES frames ago: its results are (almost always) ready
		dj: d3d11.QUERY_DATA_TIMESTAMP_DISJOINT
		t0, t1: u64
		if r.ctx->GetData((^d3d11.IAsynchronous)(q[0]), &dj, size_of(dj), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(q[1]), &t0, size_of(t0), 0) == 0 &&
		   r.ctx->GetData((^d3d11.IAsynchronous)(q[2]), &t1, size_of(t1), 0) == 0 && !bool(dj.Disjoint) && dj.Frequency > 0 {
			r.gpu_last_ms = f32(f64(t1 - t0) * 1000 / f64(dj.Frequency))
			r.gpu_last_frame = r.gpu_frame - GPU_QUERY_FRAMES + 1
			profile_collect(r, r.gpu_frame % GPU_QUERY_FRAMES, r.gpu_frame - GPU_QUERY_FRAMES, t0, dj.Frequency, r.gpu_last_ms)
		}
	}
	r.ctx->Begin((^d3d11.IAsynchronous)(q[0]))
	r.ctx->End((^d3d11.IAsynchronous)(q[1]))
	profile_begin(r, r.gpu_frame % GPU_QUERY_FRAMES)
}

@(private)
gpu_timing_end :: proc(r: ^Renderer) {
	profile_end(r)
	q := &r.gpu_queries[r.gpu_frame % GPU_QUERY_FRAMES]
	r.ctx->End((^d3d11.IAsynchronous)(q[2]))
	r.ctx->End((^d3d11.IAsynchronous)(q[0]))
	r.gpu_frame += 1
}

@(private)
texture_view :: proc(r: ^Renderer, t: Texture) -> ^d3d11.IShaderResourceView {
	return int(t) > 0 && int(t) < len(r.textures) ? r.textures[int(t)].view : nil
}

// A raw view of `bytes` bytes of a buffer made with BUFFER_ALLOW_RAW_VIEWS: what a WGSL `var<storage, read>` array becomes in
// naga's HLSL (a ByteAddressBuffer, read with Load / Load2 / Load4).
@(private)
raw_buffer_view :: proc(r: ^Renderer, buf: ^d3d11.IBuffer, bytes: int) -> ^d3d11.IShaderResourceView {
	if buf == nil { return nil }
	srv := d3d11.SHADER_RESOURCE_VIEW_DESC{Format = .R32_TYPELESS, ViewDimension = .BUFFEREX}
	srv.BufferEx = {FirstElement = 0, NumElements = u32(bytes / 4), Flags = {.RAW}}
	view: ^d3d11.IShaderResourceView
	r.device->CreateShaderResourceView(buf, &srv, &view)
	return view
}

// (Re)creates a dynamic raw buffer (the tables of the frame) and its view when `n` elements do not fit, then uploads `data`.
@(private)
upload_structured :: proc(r: ^Renderer, buf: ^^d3d11.IBuffer, view: ^^d3d11.IShaderResourceView, cap: ^int, data: rawptr, n, stride: int) {
	if buf^ == nil || n > cap^ {
		if view^ != nil { view^->Release(); view^ = nil }
		if buf^ != nil { buf^->Release(); buf^ = nil }
		cap^ = max(n, cap^ * 2, 64)
		r.device->CreateBuffer(&{ByteWidth = u32(cap^ * stride), Usage = .DYNAMIC, BindFlags = {.SHADER_RESOURCE},
			CPUAccessFlags = {.WRITE}, MiscFlags = {.BUFFER_ALLOW_RAW_VIEWS}}, nil, buf)
		view^ = raw_buffer_view(r, buf^, cap^ * stride)
	}
	if n == 0 { return }
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(buf^, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, data, n * stride)
	r.ctx->Unmap(buf^, 0)
}

// Presents the frame: `vsync` false presents at once (with tearing where supported) whatever set_present_mode says.
d3d_frame_end :: proc(r: ^Renderer, vsync := true) {
	if r.swapchain == nil {   // offscreen: no present to tell, ask
		r.ctx->Flush()
		if is_device_loss(r.device->GetDeviceRemovedReason()) { r.lost = true }
		return
	}
	if hr := d3d_present_partial(r, vsync); is_device_loss(hr) || is_device_loss(r.device->GetDeviceRemovedReason()) {
		r.lost = true
	}
}

// Most frames the swap chain may queue (IDXGISwapChain2::SetMaximumFrameLatency; see api.set_max_frame_latency).
d3d_set_max_frame_latency :: proc(r: ^Renderer, n: int) -> bool {
	if r.swapchain == nil { return false }
	sc2: ^dxgi.ISwapChain2
	if win.FAILED(r.swapchain->QueryInterface(dxgi.ISwapChain2_UUID, (^rawptr)(&sc2))) || sc2 == nil { return false }
	defer sc2->Release()
	frames := clamp(n, 1, 16)
	if win.FAILED(sc2->SetMaximumFrameLatency(u32(frames))) { return false }
	latency_lowered(&r.present, frames)
	return true
}

// What presents the frame (the swap chain and, for a translucent window, its DirectComposition objects) is released. See
// set_teardown_wait for the asynchronous release on a slow compositor.
@(private)
release_presentation :: proc(r: ^Renderer) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	if r.teardown_wait_ms <= 0 || r.swapchain == nil {
		rel(&r.dcomp_visual); rel(&r.dcomp_target); rel(&r.dcomp); rel(&r.swapchain)
		return
	}
	a := new(Async_Release, runtime.heap_allocator())
	a^ = {visual = r.dcomp_visual, target = r.dcomp_target, dcomp = r.dcomp, swapchain = r.swapchain}
	r.dcomp_visual, r.dcomp_target, r.dcomp, r.swapchain = nil, nil, nil, nil
	a.done = win.CreateEventW(nil, true, false, nil)
	thread := win.CreateThread(nil, 0, async_release_main, a, 0, nil)
	if thread == nil {
		async_release_main(a)   // (no thread: here, and wait as before)
		win.CloseHandle(a.done)
		free(a, runtime.heap_allocator())
		return
	}
	win.CloseHandle(thread)
	if win.WaitForSingleObject(a.done, win.DWORD(r.teardown_wait_ms)) == win.WAIT_OBJECT_0 {
		win.CloseHandle(a.done)
		free(a, runtime.heap_allocator())
	}   // else: the thread finishes alone (and keeps `a` and the event: a few bytes, in a program that is ending)
}

@(private)
Async_Release :: struct {
	visual:    ^IDCompositionVisual,
	target:    ^IDCompositionTarget,
	dcomp:     ^IDCompositionDevice,
	swapchain: ^dxgi.ISwapChain1,
	done:      win.HANDLE,
}

@(private)
async_release_main :: proc "system" (p: rawptr) -> win.DWORD {
	a := (^Async_Release)(p)
	if a.visual != nil { a.visual->Release() }
	if a.target != nil { a.target->Release() }
	if a.dcomp != nil { a.dcomp->Release() }
	if a.swapchain != nil { a.swapchain->Release() }
	win.SetEvent(a.done)
	return 0
}

}   // when !USE_WGPU


