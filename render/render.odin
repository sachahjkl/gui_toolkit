// Package render: Direct3D 11 backend. One instanced-quad pipeline draws everything (see rect.hlsl).
package render

import "core:fmt"
import "core:mem"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/d3d_compiler"
import "vendor:directx/dxgi"

SHADER_SOURCE :: #load("rect.hlsl", string)

// One primitive. 128 bytes, laid out exactly as the vertex shader's per-instance input.
Rect_Inst :: struct #packed {
	dst:    [4]f32,       // x0 y0 x1 y1 (pixels)
	src:    [4]f32,       // u0 v0 u1 v1 (texels)
	colors: [4][4]f32,    // top-left, bottom-left, top-right, bottom-right (linear rgba)
	radii:  [4]f32,       // same corner order
	border: f32,          // > 0: draw only a ring of this thickness
	soft:   f32,          // <= 1: crisp antialiased edge; > 1: soft shape (shadows)
	use_tex: f32,         // 1: multiply alpha with the atlas coverage
	tex_size: f32,        // atlas width/height in texels (square)
}
#assert(size_of(Rect_Inst) == 128)

Texture :: distinct int

Batch :: struct {
	clip:  [4]f32,        // scissor x0 y0 x1 y1 (pixels)
	tex:   Texture,       // 0 = none
	first: int,
	count: int,
}

Texture_Data :: struct {
	tex:  ^d3d11.ITexture2D,
	view: ^d3d11.IShaderResourceView,
	size: int,
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
	sampler:     ^d3d11.ISamplerState,
	textures:    [dynamic]Texture_Data,   // index 0 is a dummy so Texture(0) means "none"
	size:        [2]int,
	hwnd:        win.HWND,
}

init :: proc(r: ^Renderer, hwnd: win.HWND, size: [2]int) -> bool {
	r.hwnd = hwnd
	r.size = size
	feature_levels := [?]d3d11.FEATURE_LEVEL{._11_0}
	base_device: ^d3d11.IDevice
	base_ctx: ^d3d11.IDeviceContext
	flags := d3d11.CREATE_DEVICE_FLAGS{.BGRA_SUPPORT}
	when ODIN_DEBUG { flags += {.DEBUG} }
	if hr := d3d11.CreateDevice(nil, .HARDWARE, nil, flags, &feature_levels[0], len(feature_levels), d3d11.SDK_VERSION, &base_device, nil, &base_ctx); win.FAILED(hr) {
		fmt.eprintln("render: CreateDevice failed", hr)
		return false
	}
	base_device->QueryInterface(d3d11.IDevice_UUID, (^rawptr)(&r.device))
	base_ctx->QueryInterface(d3d11.IDeviceContext_UUID, (^rawptr)(&r.ctx))
	base_device->Release()
	base_ctx->Release()

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
	if hr := factory->CreateSwapChainForHwnd(r.device, hwnd, &desc, nil, nil, &r.swapchain); win.FAILED(hr) {
		fmt.eprintln("render: CreateSwapChainForHwnd failed", hr)
		return false
	}
	factory->MakeWindowAssociation(hwnd, {.NO_ALT_ENTER})
	create_target(r)

	// shaders
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
	}
	// semantic names in the shader are C0..C3: D3D matches "C" + index, so the HLSL semantics C0..C3 are "C" 0..3
	if hr := r.device->CreateInputLayout(&elems[0], len(elems), vs_blob->GetBufferPointer(), vs_blob->GetBufferSize(), &r.layout); win.FAILED(hr) {
		fmt.eprintln("render: CreateInputLayout failed", hr)
		return false
	}

	r.device->CreateBuffer(&{ByteWidth = 16, Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.globals)

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

	append(&r.textures, Texture_Data{})   // dummy slot 0
	return true
}

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
	r.device->CreateRenderTargetView(backbuffer, &{Format = .B8G8R8A8_UNORM_SRGB, ViewDimension = .TEXTURE2D}, &r.rtv)
	backbuffer->Release()
}

resize :: proc(r: ^Renderer, size: [2]int) {
	if size.x <= 0 || size.y <= 0 || size == r.size { return }
	r.size = size
	r.ctx->OMSetRenderTargets(0, nil, nil)
	if r.rtv != nil { r.rtv->Release(); r.rtv = nil }
	r.swapchain->ResizeBuffers(0, u32(size.x), u32(size.y), .UNKNOWN, {})
	create_target(r)
}

// A single-channel (coverage) texture, used for the glyph atlas.
create_texture_r8 :: proc(r: ^Renderer, size: int) -> Texture {
	td := Texture_Data{size = size}
	r.device->CreateTexture2D(&{
		Width = u32(size), Height = u32(size), MipLevels = 1, ArraySize = 1, Format = .R8_UNORM,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}, nil, &td.tex)
	r.device->CreateShaderResourceView(td.tex, nil, &td.view)
	append(&r.textures, td)
	return Texture(len(r.textures) - 1)
}

update_texture_r8 :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, pitch: int) {
	td := r.textures[int(t)]
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
}

frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	c := clear
	r.ctx->ClearRenderTargetView(r.rtv, &c)
}

// Draws all instances; each batch is a range with its own scissor rect and texture.
frame_submit :: proc(r: ^Renderer, insts: []Rect_Inst, batches: []Batch) {
	if len(insts) == 0 { return }
	if len(insts) > r.inst_cap {
		if r.inst_buf != nil { r.inst_buf->Release() }
		r.inst_cap = max(len(insts), max(r.inst_cap * 2, 4096))
		r.device->CreateBuffer(&{ByteWidth = u32(r.inst_cap * size_of(Rect_Inst)), Usage = .DYNAMIC, BindFlags = {.VERTEX_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.inst_buf)
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.inst_buf, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, raw_data(insts), len(insts) * size_of(Rect_Inst))
	r.ctx->Unmap(r.inst_buf, 0)

	r.ctx->Map(r.globals, 0, .WRITE_DISCARD, {}, &mapped)
	(^[2]f32)(mapped.pData)^ = {f32(r.size.x), f32(r.size.y)}
	r.ctx->Unmap(r.globals, 0)

	vp := d3d11.VIEWPORT{0, 0, f32(r.size.x), f32(r.size.y), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	r.ctx->RSSetState(r.raster)
	r.ctx->OMSetRenderTargets(1, &r.rtv, nil)
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	r.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	r.ctx->IASetInputLayout(r.layout)
	stride := u32(size_of(Rect_Inst))
	offset := u32(0)
	r.ctx->IASetVertexBuffers(0, 1, &r.inst_buf, &stride, &offset)
	r.ctx->VSSetShader(r.vs, nil, 0)
	r.ctx->VSSetConstantBuffers(0, 1, &r.globals)
	r.ctx->PSSetShader(r.ps, nil, 0)
	r.ctx->PSSetSamplers(0, 1, &r.sampler)

	bound: Texture = -1
	for b in batches {
		if b.count == 0 { continue }
		if b.tex != bound {
			view := r.textures[int(b.tex)].view
			r.ctx->PSSetShaderResources(0, 1, &view)
			bound = b.tex
		}
		rc := d3d11.RECT{
			left   = i32(clamp(b.clip.x, 0, f32(r.size.x))), top    = i32(clamp(b.clip.y, 0, f32(r.size.y))),
			right  = i32(clamp(b.clip.z, 0, f32(r.size.x))), bottom = i32(clamp(b.clip.w, 0, f32(r.size.y))),
		}
		if rc.right <= rc.left || rc.bottom <= rc.top { continue }
		r.ctx->RSSetScissorRects(1, &rc)
		r.ctx->DrawInstanced(4, u32(b.count), 0, u32(b.first))
	}
}

frame_end :: proc(r: ^Renderer, vsync := true) {
	r.swapchain->Present(vsync ? 1 : 0, {})
}
