// Package render: Direct3D 11 backend. One instanced-quad pipeline draws everything (see rect.hlsl).
package render

import "core:fmt"
import "core:math"
import "core:mem"
import "base:runtime"
import "core:time"

_ :: time   // RENDER_PROBE only
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"

SHADER_SOURCE :: #load("rect.hlsl", string)

// LOW_LATENCY (default on): at most one frame in flight + a waitable swap chain. The app waits for the GPU *before*
// reading input, so what is drawn is based on the freshest mouse position. With DXGI's default (3 frames queued) a
// hover or a drag shows up 2-3 refreshes late, which feels "floaty". Build with -define:LOW_LATENCY=false to compare.
LOW_LATENCY :: #config(LOW_LATENCY, true)
// RENDER_PROBE: print, once per second, how many presented frames are still waiting to reach the screen.
RENDER_PROBE :: #config(RENDER_PROBE, false)
// GPU_TIMING: timestamp queries around frame_submit; `gpu_ms` returns the GPU time of a recent frame (read a few
// frames late so it never stalls).
GPU_TIMING :: #config(GPU_TIMING, false)
@(private) GPU_QUERY_FRAMES :: 4

// One primitive. 144 bytes, laid out exactly as the vertex shader's per-instance input.
// Without a transform (`xform` = 0) `dst` is in pixels. With one, `dst`, `radii`, `border` and `soft` are in the
// transform's local space: the vertex shader maps the corners to the screen and the pixel shader evaluates the shape
// in local space, so rotated / skewed rects keep exact rounded corners and a 1 px antialiased edge.
Rect_Inst :: struct #packed {
	dst:    [4]f32,       // x0 y0 x1 y1 (pixels, or local units with a transform)
	src:    [4]f32,       // u0 v0 u1 v1 (texels)
	colors: [4][4]f32,    // top-left, bottom-left, top-right, bottom-right (linear rgba)
	radii:  [4]f32,       // same corner order
	border: f32,          // > 0: draw only a ring of this thickness
	soft:   f32,          // <= 1: crisp antialiased edge; > 1: soft shape (shadows)
	use_tex: f32,         // KIND_SHAPE, KIND_GLYPH (alpha x atlas coverage) or KIND_IMAGE (color x RGBA texel)
	tex_size: f32,        // atlas width/height in texels (square); 1 for images (the shader asks the texture)
	xform:  u32,          // index into the frame's transform table (`frame_submit`), 0 = none (dst in pixels)
	clip:   u32,          // index into the frame's clip-shape table, 0 = none (only the batch scissor clips)
	flags:  u32,          // FLAG_*
	_:      u32,
}
#assert(size_of(Rect_Inst) == 144)

KIND_SHAPE :: 0
KIND_GLYPH :: 1
KIND_IMAGE :: 2

FLAG_TILE :: 1   // image: repeat (wrap addressing) instead of clamping to `src`; `src` should be the whole texture
FLAG_LAYER :: 2  // image: a layer composited 1:1 in screen pixels (texels fetched, not filtered); no transform

// A 2D affine transform for the vertex shader, x' = a*x + c*y + e, y' = b*x + d*y + f (`m` = a b c d e f).
Xform_Data :: struct {
	m: [6]f32,
	_: [2]f32,
}
#assert(size_of(Xform_Data) == 32)

// A rounded-rect clip evaluated per pixel: `inv` maps screen pixels to the clip's local space (same layout as
// Xform_Data.m), where the shape is centered on `center` with `half_size` and per-corner `radii` (top-left,
// bottom-left, top-right, bottom-right). `px` = screen pixels per local unit (antialiasing width). `parent` chains
// nested clips (0 = end); the shader follows at most MAX_CLIP_DEPTH links.
Clip_Data :: struct {
	inv:       [6]f32,
	px:        f32,
	parent:    u32,
	center:    [2]f32,
	half_size: [2]f32,
	radii:     [4]f32,
}
#assert(size_of(Clip_Data) == 64)

MAX_CLIP_DEPTH :: 8

Texture :: distinct int

Batch :: struct {
	clip:  [4]f32,        // scissor x0 y0 x1 y1 (screen pixels, also inside a layer)
	tex:   Texture,       // coverage texture (glyph atlas, t0), 0 = none
	first: int,
	count: int,
	image: Texture,       // RGBA texture of the batch's KIND_IMAGE instances (t1), 0 = none
	target: int,          // 0 = the frame; k > 0 = layers[k - 1] (offscreen, see Layer)
}

// An offscreen layer: the batches whose `target` is its index + 1 draw into `tex` (a render target from
// acquire_target, cleared to transparent) instead of the frame, with screen pixel (x, y) landing on texel
// (x, y) - origin. Layers are drawn before the frame, in the order of `done` (a layer is complete before the one
// that composites it), so a layer's texture is ready when an instance of the frame (or of an enclosing layer)
// samples it. Content accumulates as premultiplied color: sampling it as a KIND_IMAGE composites it exactly.
Layer :: struct {
	tex:    Texture,      // 0: nothing to draw (empty or refused): its batches are skipped
	origin: [2]f32,
	size:   [2]int,
	done:   int,          // completion rank
}

Texture_Kind :: enum u8 { None, R8, RGBA, Target }

Texture_Data :: struct {
	tex:  ^d3d11.ITexture2D,
	view: ^d3d11.IShaderResourceView,
	rtv:  ^d3d11.IRenderTargetView,   // Target only
	size: int,            // R8: width = height
	w, h: int,
	kind: Texture_Kind,
	mips: bool,           // has a full mip chain (generated after updates, before the next draw)
	mips_dirty: bool,
}

Renderer :: struct {
	device:      ^d3d11.IDevice,
	ctx:         ^d3d11.IDeviceContext,
	swapchain:   ^dxgi.ISwapChain1,
	rtv:         ^d3d11.IRenderTargetView,
	vs:          ^d3d11.IVertexShader,
	ps:          ^d3d11.IPixelShader,
	layout:      ^d3d11.IInputLayout,
	inst_buf:    ^d3d11.IBuffer,
	inst_cap:    int,
	globals:     ^d3d11.IBuffer,
	blend:       ^d3d11.IBlendState,
	raster:      ^d3d11.IRasterizerState,
	sampler:     ^d3d11.ISamplerState,    // glyph atlas: bilinear, clamp, level 0 only
	sampler_img: ^d3d11.ISamplerState,    // images: trilinear, clamp
	sampler_wrap: ^d3d11.ISamplerState,   // tiled images: trilinear, wrap
	xform_buf:   ^d3d11.IBuffer,          // StructuredBuffer<Xform_Data> (t2, vertex shader)
	xform_view:  ^d3d11.IShaderResourceView,
	xform_cap:   int,
	clip_buf:    ^d3d11.IBuffer,          // StructuredBuffer<Clip_Data> (t3, pixel shader)
	clip_view:   ^d3d11.IShaderResourceView,
	clip_cap:    int,
	textures:    [dynamic]Texture_Data,   // index 0 is a dummy so Texture(0) means "none"
	free_textures: [dynamic]Texture,      // destroyed slots, reused by the next create
	targets:     [dynamic]Pooled_Target,  // layer render targets, reused from frame to frame
	scratch:     [dynamic]u8,             // RGBA upload conversion
	gpu_queries: [GPU_QUERY_FRAMES][3]^d3d11.IQuery,   // GPU_TIMING: disjoint, begin, end per frame slot
	gpu_frame:   int,
	gpu_last_ms: f32,
	latency_handle: win.HANDLE,           // signaled when the swap chain can accept a new frame (LOW_LATENCY)
	swap_flags:  dxgi.SWAP_CHAIN,
	probe_sum, probe_n, probe_fail, probe_frames: int,
	probe_hr: u32,
	probe_input_qpc: [64]i64,   // QPC at input read, indexed by present id
	probe_pending_qpc: i64,
	probe_lat_sum: f64,
	probe_lat_n: int,
	probe_last_seen: u32,
	probe_prev_ns: u64,
	probe_worst_ms: f64,
	probe_tick: u64,
	size:        [2]int,
	hwnd:        win.HWND,
	corner_smoothing: f32,                // 0 = circular corners, 1 = full squircle (see set_corner_smoothing)
	transparent: bool,                    // presented through DirectComposition with premultiplied alpha
	dcomp:        ^IDCompositionDevice,
	dcomp_target: ^IDCompositionTarget,
	dcomp_visual: ^IDCompositionVisual,
	offscreen:   ^d3d11.ITexture2D,      // init_offscreen: the frame target instead of a swap chain
}

// `transparent`: the window shows through wherever the frame has alpha < 1 (open the window with `transparent` too).
// Clear to {0, 0, 0, 0} and draw translucent colours; the output is premultiplied, which is what blending onto a
// transparent clear produces anyway.
init :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int, transparent := false) -> bool {
	r.hwnd = hwnd
	r.size = size
	r.transparent = transparent
	create_device(r, .HARDWARE) or_return

	dxgi_device: ^dxgi.IDevice
	r.device->QueryInterface(dxgi.IDevice_UUID, (^rawptr)(&dxgi_device))
	adapter: ^dxgi.IAdapter
	dxgi_device->GetAdapter(&adapter)
	factory: ^dxgi.IFactory2
	adapter->GetParent(dxgi.IFactory2_UUID, (^rawptr)(&factory))
	defer { factory->Release(); adapter->Release(); dxgi_device->Release() }

	desc := dxgi.SWAP_CHAIN_DESC1{
		Width       = 0, Height = 0,
		Format      = .B8G8R8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = 2,
		Scaling     = .NONE,
		SwapEffect  = .FLIP_DISCARD,
		AlphaMode   = .UNSPECIFIED,
	}
	when LOW_LATENCY { desc.Flags = {.FRAME_LATENCY_WAITABLE_OBJECT} }
	r.swap_flags = desc.Flags
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
	return init_pipeline(r)
}

// Releases every GPU object and the renderer's memory (textures still alive included). The renderer can be
// initialized again afterwards.
destroy :: proc(r: ^Renderer) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	for i in 1 ..< len(r.textures) { destroy_texture(r, Texture(i)) }
	delete(r.textures); delete(r.free_textures); delete(r.targets); delete(r.scratch)
	for &q in r.gpu_queries { for &x in q { rel(&x) } }
	rel(&r.xform_view); rel(&r.xform_buf); rel(&r.clip_view); rel(&r.clip_buf); rel(&r.inst_buf); rel(&r.globals)
	rel(&r.sampler); rel(&r.sampler_img); rel(&r.sampler_wrap); rel(&r.raster); rel(&r.blend)
	rel(&r.layout); rel(&r.ps); rel(&r.vs); rel(&r.rtv); rel(&r.offscreen)
	rel(&r.dcomp_visual); rel(&r.dcomp_target); rel(&r.dcomp); rel(&r.swapchain)
	if r.latency_handle != nil { win.CloseHandle(r.latency_handle) }
	if r.ctx != nil { r.ctx->ClearState() }
	rel(&r.ctx); rel(&r.device)
	r^ = {}
}

// A renderer without a window: frames are drawn into an offscreen B8G8R8A8 (sRGB) image of `size` that
// `read_pixels` returns. For tests and image export. `warp`: the software rasterizer (deterministic, no GPU needed).
init_offscreen :: proc(r: ^Renderer, size: [2]int, warp := false) -> bool {
	r.size = size
	if !create_device(r, warp ? .WARP : .HARDWARE) {
		if warp || !create_device(r, .WARP) { return false }
	}
	r.device->CreateTexture2D(&{
		Width = u32(size.x), Height = u32(size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
	}, nil, &r.offscreen)
	if r.offscreen == nil { return false }
	// typeless storage: the view is sRGB (like the swap chain's), the readback copies raw bytes
	r.device->CreateRenderTargetView(r.offscreen, &{Format = .B8G8R8A8_UNORM_SRGB, ViewDimension = .TEXTURE2D}, &r.rtv)
	if r.rtv == nil { return false }
	return init_pipeline(r)
}

// The offscreen image (init_offscreen) after the last frame: RGBA8, sRGB, `size.x * size.y * 4` bytes.
read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
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
	flags := d3d11.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT}
	when ODIN_DEBUG { flags += {.DEBUG} }
	if hr := d3d11.CreateDevice(nil, driver, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx); win.FAILED(hr) {
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
	vs_blob := compile(SHADER_SOURCE, "vs_main", "vs_5_0") or_return
	ps_blob := compile(SHADER_SOURCE, "ps_main", "ps_5_0") or_return
	defer { vs_blob->Release(); ps_blob->Release() }
	r.device->CreateVertexShader(vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), nil, &r.vs)
	r.device->CreatePixelShader(ps_blob->GetBufferPointer(), ps_blob->GetBufferSize(), nil, &r.ps)

	inst :: proc(name: cstring, idx: u32, off: u32) -> d3d11.INPUT_ELEMENT_DESC {
		return {SemanticName = name, SemanticIndex = idx, Format = .R32G32B32A32_FLOAT, InputSlot = 0,
		        AlignedByteOffset = off, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1}
	}
	elems := [?]d3d11.INPUT_ELEMENT_DESC{
		inst("DST", 0, 0), inst("SRC", 0, 16), inst("C", 0, 32), inst("C", 1, 48), inst("C", 2, 64), inst("C", 3, 80),
		inst("RADII", 0, 96), inst("STYLE", 0, 112),
		{SemanticName = "EXTRA", Format = .R32G32B32A32_UINT, AlignedByteOffset = 128, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
	}
	// semantic names in the shader are C0..C3: D3D matches "C" + index, so the HLSL semantics C0..C3 are "C" 0..3
	if hr := r.device->CreateInputLayout(&elems[0], len(elems), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &r.layout); win.FAILED(hr) {
		fmt.eprintln("render: CreateInputLayout failed", hr)
		return false
	}

	r.device->CreateBuffer(&{ByteWidth = 32, Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.globals)

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

	append(&r.textures, Texture_Data{})   // dummy slot 0
	r.corner_smoothing = 1
	return true
}

@(private)
init_composition :: proc(r: ^Renderer, factory: ^dxgi.IFactory2, dxgi_device: ^dxgi.IDevice, hwnd: win.HWND, base: dxgi.SWAP_CHAIN_DESC1, size: [2]int) -> bool {
	desc := base
	desc.Width, desc.Height = u32(max(size.x, 1)), u32(max(size.y, 1))
	desc.Scaling = .STRETCH
	desc.AlphaMode = .PREMULTIPLIED
	// scRGB (linear fp16): DWM composes it in linear light, like our blending, so translucent pixels come out
	// right. With 8-bit sRGB it expects alpha premultiplied in sRGB space, and our linear output looks washed out.
	desc.Format = .R16G16B16A16_FLOAT
	if win.FAILED(factory->CreateSwapChainForComposition(r.device, &desc, nil, &r.swapchain)) { return false }
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

// True when the window shows through pixels with alpha < 1 (init asked for it and the system supports it).
is_transparent :: proc(r: ^Renderer) -> bool { return r.transparent }

@(private)
compile :: proc(src: string, entry, target: cstring) -> (blob: ^d3d11.IBlob, ok: bool) {
	errors: ^d3d11.IBlob
	hr := d3d_compiler.Compile(raw_data(src), uint(len(src)), "rect.hlsl", nil, nil, entry, target, 0, 0, &blob, &errors)
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
	// sRGB view over a UNORM buffer: the shader writes linear colors, the hardware encodes (and blends) correctly
	format: dxgi.FORMAT = r.transparent ? .R16G16B16A16_FLOAT : .B8G8R8A8_UNORM_SRGB
	r.device->CreateRenderTargetView(backbuffer, &{Format = format, ViewDimension = .TEXTURE2D}, &r.rtv)
	backbuffer->Release()
}

resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size || r.swapchain == nil { return }
	r.size = size
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	r.swapchain->ResizeBuffers(0, u32(size.x), u32(size.y), .UNKNOWN, r.swap_flags)   // flags must match creation
	create_target(r)
}

// A single-channel (coverage) texture, used for the glyph atlas.
create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	td := Texture_Data{size = size, w = size, h = size, kind = .R8}
	r.device->CreateTexture2D(&{
		Width = u32(size), Height = u32(size), MipLevels = 1, ArraySize = 1, Format = .R8_UNORM,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}, nil, &td.tex)
	r.device->CreateShaderResourceView(td.tex, nil, &td.view)
	return add_texture(r, td)
}

update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	td := r.textures[int(t)]
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
}

@(private)
add_texture :: proc(r: ^Renderer, td: Texture_Data) -> Texture {
	if n := len(r.free_textures); n > 0 {
		t := pop(&r.free_textures)
		r.textures[int(t)] = td
		return t
	}
	append(&r.textures, td)
	return Texture(len(r.textures) - 1)
}

// Largest width / height `create_texture_rgba` accepts (from the device's feature level).
max_texture_size :: proc(r: ^Renderer) -> int {
	#partial switch r.device->GetFeatureLevel() {
	case ._9_1, ._9_2: return 2048
	case ._9_3: return 4096
	case ._10_0, ._10_1: return 8192
	}
	return d3d11.REQ_TEXTURE2D_U_OR_V_DIMENSION
}

// Size in texels (0, 0 for an invalid or destroyed texture).
texture_size :: proc(r: ^Renderer, t: Texture) -> [2]int {
	if int(t) <= 0 || int(t) >= len(r.textures) { return {} }
	td := r.textures[int(t)]
	return {td.w, td.h}
}

// A color image for `draw.image`. Contents start transparent; fill it with `update_texture_rgba`.
// `mips`: allocate a full mip chain, regenerated (GenerateMips) before the next frame that follows an update, so
// images drawn smaller than their size stay smooth instead of shimmering. Returns 0 when the size is out of range or
// the device refuses the texture.
//
// Storage is R8G8B8A8_UNORM_SRGB holding PREMULTIPLIED colors (see update_texture_rgba): the sampler decodes sRGB to
// linear before filtering, so bilinear filtering and mip averaging happen in linear light on premultiplied values
// (no dark fringes around transparent pixels), consistent with the renderer's linear blending.
create_texture_rgba :: proc(r: ^Renderer, w, h: int, mips := true) -> Texture {
	limit := max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA}
	support: u32
	r.device->CheckFormatSupport(.R8G8B8A8_UNORM_SRGB, &support)
	td.mips = mips && support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0 && (w > 1 || h > 1)
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(w), Height = u32(h), MipLevels = td.mips ? 0 : 1, ArraySize = 1, Format = .R8G8B8A8_UNORM_SRGB,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	if td.mips { desc.BindFlags += {.RENDER_TARGET}; desc.MiscFlags = {.GENERATE_MIPS} }
	if win.FAILED(r.device->CreateTexture2D(&desc, nil, &td.tex)) { return 0 }
	if win.FAILED(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); return 0 }
	// start transparent (D3D leaves DEFAULT textures undefined)
	zero := make([]u8, w * 4)
	defer delete(zero)
	for y in 0 ..< h {
		box := d3d11.BOX{left = 0, top = u32(y), front = 0, right = u32(w), bottom = u32(y + 1), back = 1}
		r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(zero), u32(w * 4), 0)
	}
	td.mips_dirty = td.mips
	return add_texture(r, td)
}

// Uploads a w x h block at (x, y). `pixels`: RGBA8, sRGB encoded, NOT premultiplied (what PNG / JPEG decoders and
// the web produce); `stride` = bytes per row (0: w * 4). Converted on the CPU to premultiplied alpha in linear light,
// re-encoded as sRGB for storage. Opaque pixels go through unchanged.
update_texture_rgba :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind != .RGBA || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
	pitch := stride > 0 ? stride : w * 4
	if len(pixels) < pitch * (h - 1) + w * 4 { return }
	srgb_tables_init()
	runtime.resize(&r.scratch, w * h * 4)
	for row in 0 ..< h {
		src := pixels[row * pitch:][:w * 4]
		dst := r.scratch[row * w * 4:][:w * 4]
		for i := 0; i < w * 4; i += 4 {
			a := src[i + 3]
			switch a {
			case 255: dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = src[i], src[i + 1], src[i + 2], 255
			case 0:   dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = 0, 0, 0, 0
			case:
				af := f32(a) / 255
				for k in 0 ..< 3 {
					lin := srgb_to_linear_table[src[i + k]] * af
					dst[i + k] = linear_to_srgb_table[int(lin * (LINEAR_STEPS - 1) + 0.5)]
				}
				dst[i + 3] = a
			}
		}
	}
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(r.scratch), u32(w * 4), 0)
	if td.mips { td.mips_dirty = true }
}

// Frees the GPU texture; the handle may be reused by a later create. Drawing a destroyed texture draws nothing.
destroy_texture :: proc(r: ^Renderer, t: Texture) {
	if int(t) <= 0 || int(t) >= len(r.textures) { return }
	td := &r.textures[int(t)]
	if td.kind == .None { return }
	if td.rtv != nil { td.rtv->Release() }
	if td.view != nil { td.view->Release() }
	if td.tex != nil { td.tex->Release() }
	td^ = {}
	append(&r.free_textures, t)
}

////////////////////////////////
// Layer targets

@(private)
Pooled_Target :: struct {
	tex:   Texture,
	w, h:  int,
	used:  bool,          // handed out for the frame being built
	idle:  int,           // frames since it was last used
}

// Pooled targets are allocated in steps of this many pixels, so a layer that grows or shrinks a little (an animation)
// keeps its texture.
@(private) TARGET_STEP :: 128
// A pooled target nobody used for this many frames is released.
@(private) TARGET_IDLE_FRAMES :: 120

// A render target of at least w x h pixels for a layer of the frame being built (linear fp16, premultiplied).
// It belongs to the renderer and is handed back by frame_submit. 0 when the size is out of range or the device
// refuses (draw then falls back to per-primitive alpha).
acquire_target :: proc(r: ^Renderer, w, h: int) -> Texture {
	if w <= 0 || h <= 0 || w > max_texture_size(r) || h > max_texture_size(r) { return 0 }
	best := -1
	for &p, i in r.targets {
		if p.used || p.w < w || p.h < h { continue }
		if best < 0 || p.w * p.h < r.targets[best].w * r.targets[best].h { best = i }
	}
	if best >= 0 {
		r.targets[best].used, r.targets[best].idle = true, 0
		return r.targets[best].tex
	}
	limit := max_texture_size(r)
	aw := min((w + TARGET_STEP - 1) / TARGET_STEP * TARGET_STEP, limit)
	ah := min((h + TARGET_STEP - 1) / TARGET_STEP * TARGET_STEP, limit)
	td := Texture_Data{w = aw, h = ah, size = max(aw, ah), kind = .Target}
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(aw), Height = u32(ah), MipLevels = 1, ArraySize = 1, Format = .R16G16B16A16_FLOAT,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE, .RENDER_TARGET},
	}
	if win.FAILED(r.device->CreateTexture2D(&desc, nil, &td.tex)) { return 0 }
	if win.FAILED(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); return 0 }
	if win.FAILED(r.device->CreateRenderTargetView(td.tex, nil, &td.rtv)) { td.view->Release(); td.tex->Release(); return 0 }
	t := add_texture(r, td)
	append(&r.targets, Pooled_Target{tex = t, w = aw, h = ah, used = true})
	return t
}

// Ends the frame's use of the layer targets; releases the ones idle for long.
@(private)
recycle_targets :: proc(r: ^Renderer) {
	for i := len(r.targets) - 1; i >= 0; i -= 1 {
		p := &r.targets[i]
		if p.used { p.used, p.idle = false, 0; continue }
		p.idle += 1
		if p.idle > TARGET_IDLE_FRAMES {
			destroy_texture(r, p.tex)
			unordered_remove(&r.targets, i)
		}
	}
}

// Releases every pooled layer target (memory pressure, device teardown).
release_targets :: proc(r: ^Renderer) {
	for p in r.targets { destroy_texture(r, p.tex) }
	clear(&r.targets)
}

// GPU memory held by the pooled layer targets, in bytes.
targets_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for p in r.targets { n += p.w * p.h * 8 }
	return n
}

@(private) LINEAR_STEPS :: 4096
@(private) srgb_to_linear_table: [256]f32
@(private) linear_to_srgb_table: [LINEAR_STEPS]u8
@(private) srgb_tables_ready: bool

@(private)
srgb_tables_init :: proc() {
	if srgb_tables_ready { return }
	for i in 0 ..< 256 {
		c := f32(i) / 255
		srgb_to_linear_table[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4)
	}
	for i in 0 ..< LINEAR_STEPS {
		l := f32(i) / (LINEAR_STEPS - 1)
		s := l <= 0.0031308 ? l * 12.92 : 1.055 * math.pow(l, 1 / 2.4) - 0.055
		linear_to_srgb_table[i] = u8(clamp(s * 255 + 0.5, 0, 255))
	}
	srgb_tables_ready = true
}

// Corner shape for every rounded rect: 0 = circular arcs, 1 = squircle (superellipse corners, continuous curvature).
set_corner_smoothing :: proc(r: ^Renderer, smoothing: f32) { r.corner_smoothing = clamp(smoothing, 0, 1) }

// Blocks until the swap chain can take a new frame (returns at once when nothing is queued). Call it BEFORE
// polling input and building the UI: then the frame you build is the next one shown.
wait_for_frame :: proc(r: ^Renderer) {
	if r.latency_handle != nil { win.WaitForSingleObjectEx(r.latency_handle, 100, true) }
}

// RENDER_PROBE: call right after reading input; the next present is credited with this timestamp.
mark_input :: proc(r: ^Renderer) {
	when RENDER_PROBE {
		qpc: win.LARGE_INTEGER
		win.QueryPerformanceCounter(&qpc)
		r.probe_pending_qpc = i64(qpc)
	}
}

frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	c := clear
	r.ctx->ClearRenderTargetView(r.rtv, &c)
}

// GPU time of frame_submit (milliseconds) for a frame a few frames back; 0 without -define:GPU_TIMING=true.
gpu_ms :: proc(r: ^Renderer) -> f32 { return r.gpu_last_ms }

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
		}
	}
	r.ctx->Begin((^d3d11.IAsynchronous)(q[0]))
	r.ctx->End((^d3d11.IAsynchronous)(q[1]))
}

@(private)
gpu_timing_end :: proc(r: ^Renderer) {
	q := &r.gpu_queries[r.gpu_frame % GPU_QUERY_FRAMES]
	r.ctx->End((^d3d11.IAsynchronous)(q[2]))
	r.ctx->End((^d3d11.IAsynchronous)(q[0]))
	r.gpu_frame += 1
}

@(private)
texture_view :: proc(r: ^Renderer, t: Texture) -> ^d3d11.IShaderResourceView {
	return int(t) > 0 && int(t) < len(r.textures) ? r.textures[int(t)].view : nil
}

// (Re)creates a dynamic structured buffer and its view when `n` elements do not fit, then uploads `data`.
@(private)
upload_structured :: proc(r: ^Renderer, buf: ^^d3d11.IBuffer, view: ^^d3d11.IShaderResourceView, cap: ^int, data: rawptr, n, stride: int) {
	if buf^ == nil || n > cap^ {
		if view^ != nil { view^->Release(); view^ = nil }
		if buf^ != nil { buf^->Release(); buf^ = nil }
		cap^ = max(n, cap^ * 2, 64)
		r.device->CreateBuffer(&{ByteWidth = u32(cap^ * stride), Usage = .DYNAMIC, BindFlags = {.SHADER_RESOURCE},
			CPUAccessFlags = {.WRITE}, MiscFlags = {.BUFFER_STRUCTURED}, StructureByteStride = u32(stride)}, nil, buf)
		srv := d3d11.SHADER_RESOURCE_VIEW_DESC{Format = .UNKNOWN, ViewDimension = .BUFFER}
		srv.Buffer.FirstElement = 0
		srv.Buffer.NumElements = u32(cap^)
		r.device->CreateShaderResourceView(buf^, &srv, view)
	}
	if n == 0 { return }
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(buf^, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, data, n * stride)
	r.ctx->Unmap(buf^, 0)
}

// Draws all instances; each batch is a range with its own scissor rect, textures and target.
// `xforms` / `clips`: the tables that Rect_Inst.xform / Rect_Inst.clip index (entry 0 is never read; pass nil when
// no instance uses them). `layers`: the offscreen layers batches may target (see Layer); drawn first, in `done`
// order. The layer targets are handed back to the renderer's pool afterwards.
frame_submit :: proc(r: ^Renderer, insts: []Rect_Inst, batches: []Batch, xforms: []Xform_Data = nil, clips: []Clip_Data = nil, layers: []Layer = nil) {
	defer recycle_targets(r)
	if len(insts) == 0 { return }
	when GPU_TIMING {
		gpu_timing_begin(r)
		defer gpu_timing_end(r)
	}
	// images updated since their last draw: rebuild their mip chains first
	for &td in r.textures {
		if td.mips_dirty { r.ctx->GenerateMips(td.view); td.mips_dirty = false }
	}
	upload_structured(r, &r.xform_buf, &r.xform_view, &r.xform_cap, raw_data(xforms), len(xforms), size_of(Xform_Data))
	upload_structured(r, &r.clip_buf, &r.clip_view, &r.clip_cap, raw_data(clips), len(clips), size_of(Clip_Data))
	if len(insts) > r.inst_cap {
		if r.inst_buf != nil { r.inst_buf->Release() }
		r.inst_cap = max(len(insts), max(r.inst_cap * 2, 4096))
		r.device->CreateBuffer(&{ByteWidth = u32(r.inst_cap * size_of(Rect_Inst)), Usage = .DYNAMIC, BindFlags = {.VERTEX_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.inst_buf)
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.inst_buf, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, raw_data(insts), len(insts) * size_of(Rect_Inst))
	r.ctx->Unmap(r.inst_buf, 0)

	r.ctx->RSSetState(r.raster)
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	r.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	r.ctx->IASetInputLayout(r.layout)
	stride := u32(size_of(Rect_Inst))
	offset := u32(0)
	r.ctx->IASetVertexBuffers(0, 1, &r.inst_buf, &stride, &offset)
	r.ctx->VSSetShader(r.vs, nil, 0)
	r.ctx->VSSetConstantBuffers(0, 1, &r.globals)
	r.ctx->VSSetShaderResources(2, 1, &r.xform_view)
	r.ctx->PSSetShader(r.ps, nil, 0)
	r.ctx->PSSetConstantBuffers(0, 1, &r.globals)   // the pixel shader reads the corner shape
	samplers := [3]^d3d11.ISamplerState{r.sampler, r.sampler_img, r.sampler_wrap}
	r.ctx->PSSetSamplers(0, 3, &samplers[0])
	r.ctx->PSSetShaderResources(3, 1, &r.clip_view)

	// layers first, each complete before whatever composites it
	if len(layers) > 0 {
		order := make([]int, len(layers), context.temp_allocator)
		for i in 0 ..< len(layers) { order[i] = i }
		for i in 1 ..< len(order) {   // insertion sort by completion rank: few layers
			for j := i; j > 0 && layers[order[j]].done < layers[order[j - 1]].done; j -= 1 { order[j], order[j - 1] = order[j - 1], order[j] }
		}
		for li in order {
			ly := layers[li]
			if int(ly.tex) <= 0 || int(ly.tex) >= len(r.textures) || r.textures[int(ly.tex)].rtv == nil { continue }
			rtv := r.textures[int(ly.tex)].rtv
			unbind := [2]^d3d11.IShaderResourceView{}
			r.ctx->PSSetShaderResources(0, 2, &unbind[0])   // the target may still be bound as the image of an earlier pass
			clear := [4]f32{}
			r.ctx->ClearRenderTargetView(rtv, &clear)
			draw_target(r, batches, li + 1, rtv, ly.size, ly.origin)
		}
		unbind := [2]^d3d11.IShaderResourceView{}
		r.ctx->PSSetShaderResources(0, 2, &unbind[0])
	}
	draw_target(r, batches, 0, r.rtv, r.size, {0, 0})
}

// The batches of one target: the frame (target 0, the swap chain) or a layer's texture, whose texel (0, 0) is the
// screen pixel `origin` (the vertex shader and the clip shapes work in screen pixels and subtract it).
@(private)
draw_target :: proc(r: ^Renderer, batches: []Batch, target: int, rtv: ^d3d11.IRenderTargetView, size: [2]int, origin: [2]f32) {
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.globals, 0, .WRITE_DISCARD, {}, &mapped)
	sm := clamp(r.corner_smoothing, 0, 1)
	// n = 2.6 softens the arc-to-edge junction without turning capsules into rounded boxes; the radius is enlarged
	// a bit so the corners do not look tighter than circular ones
	(^[8]f32)(mapped.pData)^ = {f32(size.x), f32(size.y), 2 + 0.6 * sm, 1 + 0.25 * sm, origin.x, origin.y, 0, 0}
	r.ctx->Unmap(r.globals, 0)
	vp := d3d11.VIEWPORT{0, 0, f32(size.x), f32(size.y), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	target_rtv := rtv
	r.ctx->OMSetRenderTargets(1, &target_rtv, nil)

	// glyphs read t0 and images t1, so text and an image interleave in one batch; only a change of image (or of
	// scissor) costs a new draw call
	bound, bound_image: Texture = -1, -1
	for b in batches {
		if b.count == 0 || b.target != target { continue }
		if b.tex != bound || b.image != bound_image {
			views := [2]^d3d11.IShaderResourceView{texture_view(r, b.tex), texture_view(r, b.image)}
			r.ctx->PSSetShaderResources(0, 2, &views[0])
			bound, bound_image = b.tex, b.image
		}
		rc := d3d11.RECT{
			left   = i32(clamp(b.clip.x - origin.x, 0, f32(size.x))), top    = i32(clamp(b.clip.y - origin.y, 0, f32(size.y))),
			right  = i32(clamp(b.clip.z - origin.x, 0, f32(size.x))), bottom = i32(clamp(b.clip.w - origin.y, 0, f32(size.y))),
		}
		if rc.right <= rc.left || rc.bottom <= rc.top { continue }
		r.ctx->RSSetScissorRects(1, &rc)
		r.ctx->DrawInstanced(4, u32(b.count), 0, u32(b.first))
	}
}

frame_end :: proc(r: ^Renderer, vsync := true) {
	if r.swapchain == nil { r.ctx->Flush(); return }   // offscreen
	when RENDER_PROBE {
		before: u32
		r.swapchain->GetLastPresentCount(&before)
		r.probe_input_qpc[(before + 1) % 64] = r.probe_pending_qpc
	}
	r.swapchain->Present(vsync ? 1 : 0, {})
	when RENDER_PROBE {
		last: u32
		stats: dxgi.FRAME_STATISTICS
		r.probe_frames += 1
		hr := r.swapchain->GetFrameStatistics(&stats)
		if win.SUCCEEDED(r.swapchain->GetLastPresentCount(&last)) && win.SUCCEEDED(hr) {
			r.probe_sum += int(last) - int(stats.PresentCount)
			r.probe_n += 1
			// input -> scan-out latency of the frame that was most recently displayed
			if stats.PresentCount != r.probe_last_seen && last - stats.PresentCount < 60 {
				r.probe_last_seen = stats.PresentCount
				in_qpc := r.probe_input_qpc[stats.PresentCount % 64]
				freq: win.LARGE_INTEGER
				win.QueryPerformanceFrequency(&freq)
				if in_qpc > 0 && i64(stats.SyncQPCTime) > in_qpc {
					r.probe_lat_sum += f64(i64(stats.SyncQPCTime) - in_qpc) * 1000 / f64(freq)
					r.probe_lat_n += 1
				}
			}
		} else { r.probe_fail += 1; r.probe_hr = u32(hr) }
		now := u64(time.tick_now()._nsec)
		if r.probe_prev_ns != 0 { r.probe_worst_ms = max(r.probe_worst_ms, f64(now - r.probe_prev_ns) / 1e6) }
		r.probe_prev_ns = now
		if now - r.probe_tick > 1_000_000_000 {
			fmt.eprintf("render: %d presents | worst gap %.1f ms | input -> scan-out %.1f ms avg (%d samples) | LOW_LATENCY=%v\n", r.probe_frames, r.probe_worst_ms, r.probe_lat_n > 0 ? r.probe_lat_sum / f64(r.probe_lat_n) : 0, r.probe_lat_n, LOW_LATENCY)
			r.probe_worst_ms = 0
			r.probe_sum, r.probe_n, r.probe_fail, r.probe_frames, r.probe_tick = 0, 0, 0, 0, now
			r.probe_lat_sum, r.probe_lat_n = 0, 0
		}
	}
}
