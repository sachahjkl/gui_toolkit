package render

import "core:fmt"
import "core:mem"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

// 2D canvas drawing on the GPU, Direct3D 11 (canvas.wgsl has the shaders and the design; canvas_types.odin the data).
//
// A canvas is a render target texture (canvas_texture_create: RGBA8, premultiplied sRGB-encoded values, kept for as long as
// the canvas lives). The owner of the canvas records its drawing calls in a Canvas_List and canvas_submit replays it: the
// instances are uploaded once and drawn in as few draw calls as the state allows (a batch is a run of instances with the
// same operator, source texture, clip mask and scissor). Clip masks, layers (shadows, filters), copies of the backdrop (the
// blend modes) and read-backs live here, with the pools of the textures they need.

CANVAS_MIN_BUFFER :: 4096
CANVAS_POOL_IDLE :: 240        // submits an unused pooled texture survives
CANVAS_BLUR_DIRECT_SIGMA :: 24 // a blur above this runs on an image reduced by 2, 4, 8...

@(private)
Canvas_Buf :: struct {
	buf:  ^d3d11.IBuffer,
	view: ^d3d11.IShaderResourceView,
	cap:  int,   // bytes
}

@(private)
Canvas_Pool_Tex :: struct {
	tex:  Texture,
	w, h: int,
	r8:   bool,
	used: bool,
	idle: int,
}

// Per canvas texture: the live clip masks and what the canvas is.
@(private)
Canvas_State :: struct {
	masks:  map[i32]Texture,
	opaque: bool,
}

@(private)
Canvas_Layer :: struct {
	tex:  Texture,
	box:  [4]i32,
	live: bool,
}

@(private)
Canvas_Fx_Constants :: struct #packed {
	mode, ntaps, _p0, _p1: u32,
	dir:     [2]f32,
	src_dim: [2]f32,
	m:       [5][4]f32,
	taps:    [32][4]f32,
}
#assert(size_of(Canvas_Fx_Constants) == 624)

@(private)
Canvas_Globals :: struct #packed {
	viewport: [2]f32,
	origin:   [2]f32,
	back_dim: [2]f32,
	_:        [2]f32,
}
#assert(size_of(Canvas_Globals) == 32)

Canvas_Pipeline :: struct {
	vs, full_vs:  ^d3d11.IVertexShader,
	ps, fx_ps:    ^d3d11.IPixelShader,
	layout:       ^d3d11.IInputLayout,
	globals, fxcb: ^d3d11.IBuffer,
	raster:       ^d3d11.IRasterizerState,
	samplers:     [5]^d3d11.ISamplerState,
	blend:        [2][26]^d3d11.IBlendState,   // [rgb only (an opaque canvas)][Composite_Op]
	blend_mask:   ^d3d11.IBlendState,          // replace (clip masks, filter passes)
	blend_over:   ^d3d11.IBlendState,          // source-over on every channel (layers)
	insts, heap, paints, stops: Canvas_Buf,
	blank:        Texture,                     // a transparent 1 x 1 texture for the slots nothing is bound to
	pool:         [dynamic]Canvas_Pool_Tex,
	states:       map[Texture]^Canvas_State,
	layers:       map[i32]Canvas_Layer,
	staging:      ^d3d11.ITexture2D,
	staging_w, staging_h: int,
	submits:      int,
	failed:       bool,
	stats:        Canvas_Stats,
}

////////////////////////////////
// Textures

// Creates a texture of canvas pixels: `target` makes it a render target a canvas draws into (canvas_submit), else it is a source
// canvas_upload fills. `mips`: a full mip chain, rebuilt before the next draw that samples it after it changed. 0 when the
// size is out of range or the device refuses it.
canvas_texture_create :: proc(r: ^Renderer, w, h: int, target: bool, mips := true) -> Texture {
	when USE_WGPU { return 0 } else { return d3d_canvas_texture_create(r, w, h, target, mips) }
}

// Everything below is the Direct3D 11 implementation (the wgpu backend has no 2D canvas yet: the public procedures
// above answer "not supported"). It is built on Windows only, behind `when !USE_WGPU`.
when !USE_WGPU {

d3d_canvas_texture_create :: proc(r: ^Renderer, w, h: int, target, mips: bool) -> Texture {
	if r.device == nil || r.lost { return 0 }
	limit := max_texture_size(r)
	if w <= 0 || h <= 0 || w > limit || h > limit { return 0 }
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA, space = .Srgb, canvas = target ? 2 : 1}
	support: u32
	r.device->CheckFormatSupport(.R8G8B8A8_UNORM, &support)
	td.mips = mips && support & u32(d3d11.FORMAT_SUPPORT.MIP_AUTOGEN) != 0 && (w > 1 || h > 1)
	if !canvas_texture_objects(r, &td) { return 0 }
	return add_texture(r, td)
}

// The GPU objects of a canvas texture (also what recover recreates, empty).
@(private)
canvas_texture_objects :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	desc := d3d11.TEXTURE2D_DESC{
		Width = u32(td.w), Height = u32(td.h), MipLevels = td.mips ? 0 : 1, ArraySize = 1,
		Format = td.canvas == 3 ? .R8_UNORM : .R8G8B8A8_UNORM, SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE},
	}
	if td.canvas >= 2 || td.mips { desc.BindFlags += {.RENDER_TARGET} }
	if td.mips { desc.MiscFlags = {.GENERATE_MIPS} }
	td.tex, td.view, td.rtv = nil, nil, nil
	if hr_failed(r.device->CreateTexture2D(&desc, nil, &td.tex)) { td.tex = nil; return false }
	if hr_failed(r.device->CreateShaderResourceView(td.tex, nil, &td.view)) { td.tex->Release(); td.tex, td.view = nil, nil; return false }
	if .RENDER_TARGET in desc.BindFlags {
		rd := d3d11.RENDER_TARGET_VIEW_DESC{Format = desc.Format, ViewDimension = .TEXTURE2D}
		if hr_failed(r.device->CreateRenderTargetView(td.tex, &rd, &td.rtv)) {
			td.view->Release(); td.tex->Release()
			td.tex, td.view, td.rtv = nil, nil, nil
			return false
		}
		zero := [4]f32{}
		r.ctx->ClearRenderTargetView(td.rtv, &zero)
	}
	td.mips_dirty = td.mips
	return true
}

}   // when !USE_WGPU

canvas_texture_size :: proc(r: ^Renderer, t: Texture) -> [2]int { return texture_size(r, t) }

// Replaces a w x h block at (x, y) of a canvas texture with premultiplied sRGB-encoded RGBA8 `pixels` (rows of `stride` bytes,
// 0: w * 4).
canvas_upload :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride := 0) -> bool {
	when USE_WGPU { return false } else { return d3d_canvas_upload(r, t, x, y, w, h, pixels, stride) }
}

when !USE_WGPU {
d3d_canvas_upload :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, pixels: []u8, stride: int) -> bool {
	if int(t) <= 0 || int(t) >= len(r.textures) || r.lost { return false }
	td := &r.textures[int(t)]
	if td.canvas == 0 || td.canvas == 3 || w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > td.w || y + h > td.h { return false }
	pitch := stride > 0 ? stride : w * 4
	if len(pixels) < pitch * (h - 1) + w * 4 { return false }
	box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pixels), u32(pitch), 0)
	if td.mips { td.mips_dirty = true }
	r.canvas.stats.uploads += 1
	r.canvas.stats.upload_bytes += w * h * 4
	return true
}
}   // when !USE_WGPU

// Marks a texture whose level 0 changed so its mip levels are rebuilt before it is sampled (a source filled by canvas_upload
// does it itself).
canvas_texture_changed :: proc(r: ^Renderer, t: Texture) {
	if int(t) > 0 && int(t) < len(r.textures) && r.textures[int(t)].mips { r.textures[int(t)].mips_dirty = true }
}

// Is the canvas renderer available on this backend (and has it not failed)?
canvas_supported :: proc(r: ^Renderer) -> bool {
	when USE_WGPU { return false } else { return r.device != nil && !r.lost && !r.canvas.failed }
}

// Declares that a canvas texture has no alpha channel (getContext("2d", { alpha: false })): draws leave alpha alone.
canvas_set_opaque :: proc(r: ^Renderer, t: Texture, opaque: bool) {
	when !USE_WGPU {
		if int(t) <= 0 || int(t) >= len(r.textures) { return }
		s := canvas_state(r, t)
		s.opaque = opaque
	}
}

when !USE_WGPU {
@(private)
canvas_state :: proc(r: ^Renderer, t: Texture) -> ^Canvas_State {
	cp := &r.canvas
	if s, ok := cp.states[t]; ok { return s }
	s := new(Canvas_State)
	cp.states[t] = s
	return s
}

@(private)
canvas_state_free :: proc(r: ^Renderer, t: Texture) {
	cp := &r.canvas
	s, ok := cp.states[t]
	if !ok { return }
	for _, m in s.masks { pool_release(r, m) }
	delete(s.masks)
	free(s)
	delete_key(&cp.states, t)
}

////////////////////////////////
// Pipeline

@(private)
canvas_pipeline_ensure :: proc(r: ^Renderer) -> bool {
	cp := &r.canvas
	if cp.vs != nil { return true }
	if cp.failed { return false }
	if canvas_pipeline_init(r) { return true }
	canvas_pipeline_release(r)
	cp.failed = true
	return false
}

@(private)
canvas_pipeline_init :: proc(r: ^Renderer) -> bool {
	cp := &r.canvas
	vs_code, vs_blob, ok1 := shader_code(.Canvas_VS)
	defer shader_code_done(vs_blob)
	ps_code, ps_blob, ok2 := shader_code(.Canvas_PS)
	defer shader_code_done(ps_blob)
	fvs_code, fvs_blob, ok3 := shader_code(.Canvas_Full_VS)
	defer shader_code_done(fvs_blob)
	fps_code, fps_blob, ok4 := shader_code(.Canvas_Fx_PS)
	defer shader_code_done(fps_blob)
	if !(ok1 && ok2 && ok3 && ok4) { return false }
	r.device->CreateVertexShader(raw_data(vs_code), uint(len(vs_code)), nil, &cp.vs)
	r.device->CreatePixelShader(raw_data(ps_code), uint(len(ps_code)), nil, &cp.ps)
	r.device->CreateVertexShader(raw_data(fvs_code), uint(len(fvs_code)), nil, &cp.full_vs)
	r.device->CreatePixelShader(raw_data(fps_code), uint(len(fps_code)), nil, &cp.fx_ps)
	if cp.vs == nil || cp.ps == nil || cp.full_vs == nil || cp.fx_ps == nil {
		fmt.eprintln("render: the canvas shaders were refused by the device")
		return false
	}
	elem :: proc(loc: u32, format: dxgi.FORMAT) -> d3d11.INPUT_ELEMENT_DESC {
		return {SemanticName = "LOC", SemanticIndex = loc, Format = format, InputSlot = 0, AlignedByteOffset = loc * 16,
		        InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1}
	}
	elems: [6]d3d11.INPUT_ELEMENT_DESC
	for i in 0 ..< 5 { elems[i] = elem(u32(i), .R32G32B32A32_FLOAT) }
	elems[5] = elem(5, .R32G32B32A32_UINT)
	if hr_failed(r.device->CreateInputLayout(&elems[0], len(elems), raw_data(vs_code), uint(len(vs_code)), &cp.layout)) {
		fmt.eprintln("render: CreateInputLayout failed (canvas)")
		return false
	}
	r.device->CreateBuffer(&{ByteWidth = size_of(Canvas_Globals), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &cp.globals)
	r.device->CreateBuffer(&{ByteWidth = size_of(Canvas_Fx_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &cp.fxcb)
	r.device->CreateRasterizerState(&{FillMode = .SOLID, CullMode = .NONE, ScissorEnable = true}, &cp.raster)
	if cp.globals == nil || cp.fxcb == nil || cp.raster == nil { return false }

	sd := d3d11.SAMPLER_DESC{AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = max(f32), MaxAnisotropy = 16, ComparisonFunc = .NEVER}
	sd.Filter = .MIN_MAG_MIP_POINT
	r.device->CreateSamplerState(&sd, &cp.samplers[0])
	sd.Filter = .MIN_MAG_MIP_LINEAR
	r.device->CreateSamplerState(&sd, &cp.samplers[1])
	sd.Filter = .ANISOTROPIC
	r.device->CreateSamplerState(&sd, &cp.samplers[2])
	sd.Filter, sd.AddressU, sd.AddressV = .MIN_MAG_MIP_LINEAR, .WRAP, .WRAP
	r.device->CreateSamplerState(&sd, &cp.samplers[3])
	sd.Filter = .MIN_MAG_MIP_POINT
	r.device->CreateSamplerState(&sd, &cp.samplers[4])
	for s in cp.samplers { if s == nil { return false } }

	// the Porter-Duff operators as blend states: color and alpha take the same factors (the formulas are on premultiplied values)
	Factors :: struct { src, dst: d3d11.BLEND }
	f := [26]Factors{}
	f[0] = {.ONE, .INV_SRC_ALPHA}                // source-over
	f[1] = {.DEST_ALPHA, .ZERO}                  // source-in
	f[2] = {.INV_DEST_ALPHA, .ZERO}              // source-out
	f[3] = {.DEST_ALPHA, .INV_SRC_ALPHA}         // source-atop
	f[4] = {.INV_DEST_ALPHA, .ONE}               // destination-over
	f[5] = {.ZERO, .SRC_ALPHA}                   // destination-in
	f[6] = {.ZERO, .INV_SRC_ALPHA}               // destination-out
	f[7] = {.INV_DEST_ALPHA, .SRC_ALPHA}         // destination-atop
	f[8] = {.ONE, .ONE}                          // lighter
	f[9] = {.ONE, .ZERO}                         // copy
	f[10] = {.INV_DEST_ALPHA, .INV_SRC_ALPHA}    // xor
	for rgb_only in 0 ..< 2 {
		for op in 0 ..< 26 {
			bd := d3d11.BLEND_DESC{}
			mask := rgb_only == 1 ? d3d11.COLOR_WRITE_ENABLE_MASK{.RED, .GREEN, .BLUE} : d3d11.COLOR_WRITE_ENABLE_ALL
			if op <= 10 {
				bd.RenderTarget[0] = {BlendEnable = true, SrcBlend = f[op].src, DestBlend = f[op].dst, BlendOp = .ADD,
					SrcBlendAlpha = f[op].src, DestBlendAlpha = f[op].dst, BlendOpAlpha = .ADD, RenderTargetWriteMask = u8(transmute(u32)mask)}
			} else {
				bd.RenderTarget[0] = {BlendEnable = false, RenderTargetWriteMask = u8(transmute(u32)mask)}   // the shader writes the result
			}
			r.device->CreateBlendState(&bd, &cp.blend[rgb_only][op])
			if cp.blend[rgb_only][op] == nil { return false }
		}
	}
	bd := d3d11.BLEND_DESC{}
	bd.RenderTarget[0] = {BlendEnable = false, RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL)}
	r.device->CreateBlendState(&bd, &cp.blend_mask)
	bd.RenderTarget[0] = {BlendEnable = true, SrcBlend = .ONE, DestBlend = .INV_SRC_ALPHA, BlendOp = .ADD,
		SrcBlendAlpha = .ONE, DestBlendAlpha = .INV_SRC_ALPHA, BlendOpAlpha = .ADD, RenderTargetWriteMask = u8(d3d11.COLOR_WRITE_ENABLE_ALL)}
	r.device->CreateBlendState(&bd, &cp.blend_over)
	if cp.blend_mask == nil || cp.blend_over == nil { return false }

	cp.blank = d3d_canvas_texture_create(r, 1, 1, true, false)
	return cp.blank != 0
}

// Releases what the device holds for the canvas renderer (the device was lost, or the renderer is destroyed). Textures and
// their bookkeeping stay: recover recreates the textures, empty; masks and layers are dropped.
@(private)
canvas_pipeline_release :: proc(r: ^Renderer) {
	cp := &r.canvas
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	rel(&cp.vs); rel(&cp.ps); rel(&cp.full_vs); rel(&cp.fx_ps); rel(&cp.layout)
	rel(&cp.globals); rel(&cp.fxcb); rel(&cp.raster)
	for &s in cp.samplers { rel(&s) }
	for &row in cp.blend { for &b in row { rel(&b) } }
	rel(&cp.blend_mask); rel(&cp.blend_over)
	for b in ([?]^Canvas_Buf{&cp.insts, &cp.heap, &cp.paints, &cp.stops}) {
		rel(&b.view); rel(&b.buf)
		b.cap = 0
	}
	rel(&cp.staging)
	cp.staging_w, cp.staging_h = 0, 0
	// masks, layers and pooled textures belong to the device that is going: their slots are freed (recover has nothing to recreate)
	for _, s in cp.states {
		for _, m in s.masks { destroy_texture(r, m) }
		clear(&s.masks)
	}
	for p in cp.pool { destroy_texture(r, p.tex) }
	clear(&cp.pool)
	clear(&cp.layers)
	if cp.blank != 0 { destroy_texture(r, cp.blank) }
	cp.blank = 0
	cp.failed = false
}

// Frees the CPU side of the canvas renderer (renderer teardown, after release_device_objects).
@(private)
canvas_pipeline_free :: proc(r: ^Renderer) {
	cp := &r.canvas
	for _, s in cp.states { delete(s.masks); free(s) }
	delete(cp.states)
	delete(cp.pool)
	delete(cp.layers)
	cp^ = {}
}

////////////////////////////////
// Buffers and pools

@(private)
canvas_buf_upload :: proc(r: ^Renderer, b: ^Canvas_Buf, data: rawptr, bytes: int, vertex: bool) -> bool {
	need := max(bytes, 16)
	if b.buf == nil || need > b.cap {
		if b.view != nil { b.view->Release(); b.view = nil }
		if b.buf != nil { b.buf->Release(); b.buf = nil }
		b.cap = max(need, b.cap * 2, CANVAS_MIN_BUFFER)
		b.cap = (b.cap + 15) / 16 * 16
		desc := d3d11.BUFFER_DESC{ByteWidth = u32(b.cap), Usage = .DYNAMIC, CPUAccessFlags = {.WRITE}}
		if vertex { desc.BindFlags = {.VERTEX_BUFFER} } else { desc.BindFlags, desc.MiscFlags = {.SHADER_RESOURCE}, {.BUFFER_ALLOW_RAW_VIEWS} }
		if hr_failed(r.device->CreateBuffer(&desc, nil, &b.buf)) { b.buf, b.cap = nil, 0; return false }
		if !vertex { b.view = raw_buffer_view(r, b.buf, b.cap) }
	}
	if bytes <= 0 { return true }
	mapped: d3d11.MAPPED_SUBRESOURCE
	if hr_failed(r.ctx->Map(b.buf, 0, .WRITE_DISCARD, {}, &mapped)) { return false }
	mem.copy(mapped.pData, data, bytes)
	r.ctx->Unmap(b.buf, 0)
	return true
}

// A texture of exactly w x h (R8 or RGBA8, a render target) from the pool, empty and not yet cleared.
@(private)
pool_acquire :: proc(r: ^Renderer, w, h: int, r8: bool) -> Texture {
	cp := &r.canvas
	for &p in cp.pool {
		if !p.used && p.w == w && p.h == h && p.r8 == r8 { p.used, p.idle = true, 0; return p.tex }
	}
	td := Texture_Data{w = w, h = h, size = max(w, h), kind = .RGBA, space = .Srgb, canvas = r8 ? 3 : 2 + 0}
	if !r8 { td.canvas = 3 + 1 }   // 4: an RGBA scratch target (not a canvas: no state)
	if !canvas_texture_objects(r, &td) { return 0 }
	t := add_texture(r, td)
	append(&cp.pool, Canvas_Pool_Tex{tex = t, w = w, h = h, r8 = r8, used = true})
	return t
}

@(private)
pool_release :: proc(r: ^Renderer, t: Texture) {
	for &p in r.canvas.pool { if p.tex == t { p.used, p.idle = false, 0; return } }
}

@(private)
pool_recycle :: proc(r: ^Renderer) {
	cp := &r.canvas
	for i := len(cp.pool) - 1; i >= 0; i -= 1 {
		p := &cp.pool[i]
		if p.used { continue }
		p.idle += 1
		if p.idle > CANVAS_POOL_IDLE {
			destroy_texture(r, p.tex)
			unordered_remove(&cp.pool, i)
		}
	}
}
}   // when !USE_WGPU

// Bytes the canvas renderer's pooled textures hold.
canvas_pool_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for p in r.canvas.pool { n += p.w * p.h * (p.r8 ? 1 : 4) }
	return n
}

canvas_stats :: proc(r: ^Renderer) -> Canvas_Stats { return r.canvas.stats }
canvas_stats_reset :: proc(r: ^Renderer) { r.canvas.stats = {} }

////////////////////////////////
// Submit

// Replays `list` into the canvas texture `target`. false: nothing was drawn (not a canvas, or the device is lost).
canvas_submit :: proc(r: ^Renderer, target: Texture, list: ^Canvas_List) -> bool {
	when USE_WGPU { return false } else { return d3d_canvas_submit(r, target, list) }
}

// The Direct3D 11 canvas execution (Canvas_Exec, d3d_canvas_submit and its exec_* helpers, the staging read) is built
// on Windows only. The public read / clear / mask procedures that follow it keep their own `when USE_WGPU` guards.
when !USE_WGPU {

@(private)
Canvas_Exec :: struct {
	r:        ^Renderer,
	cp:       ^Canvas_Pipeline,
	list:     ^Canvas_List,
	target:   Texture,
	state:    ^Canvas_State,
	cur:      Texture,        // the render target bound (0: none)
	cur_origin: [2]i32,
	cur_size: [2]i32,
	cur_main: bool,           // the canvas itself is the target (else a layer or a mask)
	bound_src, bound_clip: Texture,
	bound_blend: ^d3d11.IBlendState,
	main_bound: bool,         // the instanced-quad pipeline is bound
	back, snap: Texture,
	snap_size: [2]int,
}

@(private)
d3d_canvas_submit :: proc(r: ^Renderer, target: Texture, list: ^Canvas_List) -> bool {
	if int(target) <= 0 || int(target) >= len(r.textures) || r.lost || r.device == nil { return false }
	if r.textures[int(target)].canvas != 2 || r.textures[int(target)].rtv == nil { return false }
	if !canvas_pipeline_ensure(r) { return false }
	cp := &r.canvas
	cp.submits += 1
	cp.stats.submits += 1
	x := Canvas_Exec{r = r, cp = cp, list = list, target = target, state = canvas_state(r, target), bound_src = -1, bound_clip = -1, cur_main = true}
	if len(list.cmds) == 0 { return true }
	canvas_buf_upload(r, &cp.insts, raw_data(list.insts), len(list.insts) * size_of(Canvas_Inst), true)
	canvas_buf_upload(r, &cp.heap, raw_data(list.heap), len(list.heap) * 16, false)
	canvas_buf_upload(r, &cp.paints, raw_data(list.paints), len(list.paints) * size_of(Canvas_Paint), false)
	canvas_buf_upload(r, &cp.stops, raw_data(list.stops), len(list.stops) * 16, false)
	if cp.insts.buf == nil || cp.heap.view == nil || cp.paints.view == nil || cp.stops.view == nil { return false }
	cp.stats.insts += len(list.insts)

	for cmd in list.cmds {
		switch cmd.kind {
		case .Draw: exec_draw(&x, cmd)
		case .Clip_Make: exec_clip_make(&x, cmd)
		case .Clip_Free:
			if m, ok := x.state.masks[cmd.id]; ok {
				pool_release(r, m)
				delete_key(&x.state.masks, cmd.id)
				if x.bound_clip == m { x.bound_clip = -1 }
			}
		case .Put: exec_put(&x, cmd)
		case .Snapshot: exec_snapshot(&x, cmd)
		case .Layer_Begin: exec_layer_begin(&x, cmd)
		case .Layer_End: exec_bind_target(&x, target, {0, 0}, true)
		case .Layer_Fx: exec_layer_fx(&x, cmd)
		case .Layer_Free:
			if l, ok := cp.layers[cmd.id]; ok {
				pool_release(r, l.tex)
				if x.bound_src == l.tex { x.bound_src = -1 }
				delete_key(&cp.layers, cmd.id)
			}
		case .Clear:
			td := &r.textures[int(target)]
			c := cmd.color
			r.ctx->ClearRenderTargetView(td.rtv, &c)
		}
	}
	// leave nothing bound that the next user of the device (the frame, a video conversion) would trip over
	none := [3]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(3, 3, &none[0])
	r.ctx->OMSetRenderTargets(0, nil, nil)
	for id, l in cp.layers { pool_release(r, l.tex); delete_key(&cp.layers, id) }   // (a list that did not free its layers)
	if x.back != 0 { pool_release(r, x.back) }
	if x.snap != 0 { pool_release(r, x.snap) }
	pool_recycle(r)
	td := &r.textures[int(target)]
	if td.mips { td.mips_dirty = true }
	return true
}

@(private)
exec_main_bind :: proc(x: ^Canvas_Exec) {
	if x.main_bound { return }
	r, cp := x.r, x.cp
	x.main_bound = true
	r.ctx->RSSetState(cp.raster)
	r.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	r.ctx->IASetInputLayout(cp.layout)
	stride := u32(size_of(Canvas_Inst))
	offset := u32(0)
	vb := cp.insts.buf
	r.ctx->IASetVertexBuffers(0, 1, &vb, &stride, &offset)
	r.ctx->VSSetShader(cp.vs, nil, 0)
	r.ctx->PSSetShader(cp.ps, nil, 0)
	r.ctx->VSSetConstantBuffers(0, 1, &cp.globals)
	r.ctx->PSSetConstantBuffers(0, 1, &cp.globals)
	views := [3]^d3d11.IShaderResourceView{cp.heap.view, cp.paints.view, cp.stops.view}
	r.ctx->PSSetShaderResources(0, 3, &views[0])
	samplers := [5]^d3d11.ISamplerState{cp.samplers[0], cp.samplers[1], cp.samplers[2], cp.samplers[3], cp.samplers[4]}
	r.ctx->PSSetSamplers(0, 5, &samplers[0])
	x.bound_blend = nil
}

// Makes `tex` the render target (viewport and constants for a canvas pixel origin `origin`).
@(private)
exec_bind_target :: proc(x: ^Canvas_Exec, tex: Texture, origin: [2]i32, main: bool) {
	r, cp := x.r, x.cp
	td := &r.textures[int(tex)]
	size := [2]int{td.w, td.h}
	if x.cur == tex && x.cur_origin == origin && x.cur_main == main && x.cur_size == {i32(size.x), i32(size.y)} && x.main_bound { return }
	none := [3]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(3, 3, &none[0])
	x.bound_src, x.bound_clip = -1, -1
	rtv := td.rtv
	r.ctx->OMSetRenderTargets(1, &rtv, nil)
	vp := d3d11.VIEWPORT{0, 0, f32(size.x), f32(size.y), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	mapped: d3d11.MAPPED_SUBRESOURCE
	if hr_ok(r.ctx->Map(cp.globals, 0, .WRITE_DISCARD, {}, &mapped)) {
		bd := [2]f32{f32(r.textures[int(x.target)].w), f32(r.textures[int(x.target)].h)}
		(^Canvas_Globals)(mapped.pData)^ = Canvas_Globals{viewport = {f32(size.x), f32(size.y)}, origin = {f32(origin.x), f32(origin.y)}, back_dim = bd}
		r.ctx->Unmap(cp.globals, 0)
	}
	x.cur, x.cur_origin, x.cur_main, x.cur_size = tex, origin, main, {i32(size.x), i32(size.y)}
	exec_main_bind(x)
}

@(private)
exec_srv :: proc(x: ^Canvas_Exec, t: Texture) -> ^d3d11.IShaderResourceView {
	r := x.r
	if int(t) <= 0 || int(t) >= len(r.textures) { t_ := x.cp.blank; return r.textures[int(t_)].view }
	td := &r.textures[int(t)]
	if td.mips && td.mips_dirty && td.view != nil && x.cur != t {
		r.ctx->GenerateMips(td.view)
		td.mips_dirty = false
	}
	return td.view
}

// The texture a Canvas_Cmd.source names (0: none).
@(private)
exec_source :: proc(x: ^Canvas_Exec, source: i32) -> Texture {
	switch {
	case source == CANVAS_SRC_NONE: return 0
	case source == CANVAS_SRC_SNAPSHOT: return x.snap
	case source <= CANVAS_SRC_LAYER0:
		if l, ok := x.cp.layers[CANVAS_SRC_LAYER0 - source]; ok { return l.tex }
		return 0
	case source >= 0 && int(source) < len(x.list.sources): return x.list.sources[source]
	}
	return 0
}

@(private)
exec_bind_inputs :: proc(x: ^Canvas_Exec, src, clip: Texture) {
	r := x.r
	if src != x.bound_src {
		v := exec_srv(x, src)
		r.ctx->PSSetShaderResources(3, 1, &v)
		x.bound_src = src
	}
	if clip != x.bound_clip {
		v := exec_srv(x, clip)
		r.ctx->PSSetShaderResources(4, 1, &v)
		x.bound_clip = clip
	}
}

@(private)
exec_scissor :: proc(x: ^Canvas_Exec, box: [4]i32) -> (rc: d3d11.RECT, ok: bool) {
	rc = d3d11.RECT{
		left = clamp(box[0] - x.cur_origin.x, 0, x.cur_size.x), top = clamp(box[1] - x.cur_origin.y, 0, x.cur_size.y),
		right = clamp(box[2] - x.cur_origin.x, 0, x.cur_size.x), bottom = clamp(box[3] - x.cur_origin.y, 0, x.cur_size.y),
	}
	return rc, rc.right > rc.left && rc.bottom > rc.top
}

// A scratch texture the size of the canvas (the backdrop of the blend modes, the snapshot of drawImage(itself)).
@(private)
exec_scratch :: proc(x: ^Canvas_Exec, t: ^Texture) -> bool {
	if t^ != 0 { return true }
	td := &x.r.textures[int(x.target)]
	t^ = pool_acquire(x.r, td.w, td.h, false)
	return t^ != 0
}

@(private)
exec_copy_region :: proc(x: ^Canvas_Exec, dst: Texture, box: [4]i32) {
	r := x.r
	td := &r.textures[int(x.target)]
	x0, y0 := clamp(box[0], 0, i32(td.w)), clamp(box[1], 0, i32(td.h))
	x1, y1 := clamp(box[2], x0, i32(td.w)), clamp(box[3], y0, i32(td.h))
	if x1 <= x0 || y1 <= y0 { return }
	b := d3d11.BOX{left = u32(x0), top = u32(y0), front = 0, right = u32(x1), bottom = u32(y1), back = 1}
	r.ctx->CopySubresourceRegion(r.textures[int(dst)].tex, 0, u32(x0), u32(y0), 0, td.tex, 0, &b)
	x.cp.stats.copies += 1
}

// One group of a blend-mode batch: the backdrop copied once for all of `ub`, then the instances [from, to) drawn.
@(private)
exec_back_draw :: proc(x: ^Canvas_Exec, from, to: int, ub: [4]i32) {
	if to <= from || ub[2] <= ub[0] || ub[3] <= ub[1] { return }
	exec_copy_region(x, x.back, ub)
	x.r.ctx->DrawInstanced(4, u32(to - from), 0, u32(from))
	x.cp.stats.draws += 1
}

@(private)
exec_draw :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	r, cp := x.r, x.cp
	if cmd.count <= 0 { return }
	if x.cur_main && x.cur != x.target { exec_bind_target(x, x.target, {0, 0}, true) }
	rc, ok := exec_scissor(x, cmd.box)
	if !ok { return }
	r.ctx->RSSetScissorRects(1, &rc)
	src := exec_source(x, cmd.source)
	clip: Texture
	if cmd.clip != 0 { clip = x.state.masks[cmd.clip] }
	op := min(int(cmd.op), 25)
	bs := cp.blend[x.cur_main && x.state.opaque ? 1 : 0][op]
	if !x.cur_main && op == 0 { bs = cp.blend_over }
	if bs != x.bound_blend { r.ctx->OMSetBlendState(bs, nil, ~u32(0)); x.bound_blend = bs }
	if op >= 11 && x.cur_main {
		// a blend mode reads the backdrop: a copy of what the draw covers, taken again when an instance overlaps an earlier
		// one of the group (the later one must see the earlier one's result)
		if !exec_scratch(x, &x.back) { return }
		backv := r.textures[int(x.back)].view
		r.ctx->PSSetShaderResources(5, 1, &backv)
		exec_bind_inputs(x, src, clip)
		insts := x.list.insts
		end := cmd.first + cmd.count
		from := cmd.first
		empty := [4]i32{max(i32), max(i32), min(i32), min(i32)}
		ub := empty
		for k in cmd.first ..< end {
			b := insts[k].box
			ib := [4]i32{i32(b[0]), i32(b[1]), i32(b[2]) + 1, i32(b[3]) + 1}
			ib = {max(ib[0], rc.left + x.cur_origin.x), max(ib[1], rc.top + x.cur_origin.y), min(ib[2], rc.right + x.cur_origin.x), min(ib[3], rc.bottom + x.cur_origin.y)}
			overlap := false
			for m in max(from, k - 32) ..< k {
				mb := insts[m].box
				if mb[0] < b[2] + 1 && b[0] < mb[2] + 1 && mb[1] < b[3] + 1 && b[1] < mb[3] + 1 { overlap = true; break }
			}
			if overlap || k - from >= 32 {
				exec_back_draw(x, from, k, ub)
				from, ub = k, empty
			}
			ub = {min(ub[0], ib[0]), min(ub[1], ib[1]), max(ub[2], ib[2]), max(ub[3], ib[3])}
		}
		exec_back_draw(x, from, end, ub)
		none := [1]^d3d11.IShaderResourceView{}
		r.ctx->PSSetShaderResources(5, 1, &none[0])
		return
	}
	exec_bind_inputs(x, src, clip)
	r.ctx->DrawInstanced(4, u32(cmd.count), 0, u32(cmd.first))
	cp.stats.draws += 1
}

@(private)
exec_clip_make :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	r, cp := x.r, x.cp
	td := &r.textures[int(x.target)]
	m := pool_acquire(r, td.w, td.h, true)
	if m == 0 { return }
	if old, ok := x.state.masks[cmd.id]; ok { pool_release(r, old) }
	x.state.masks[cmd.id] = m
	cp.stats.clip_masks += 1
	zero := [4]f32{}
	r.ctx->ClearRenderTargetView(r.textures[int(m)].rtv, &zero)
	if cmd.count <= 0 { return }
	exec_bind_target(x, m, {0, 0}, false)
	rc, ok := exec_scissor(x, cmd.box)
	if !ok { return }
	r.ctx->RSSetScissorRects(1, &rc)
	if x.bound_blend != cp.blend_mask { r.ctx->OMSetBlendState(cp.blend_mask, nil, ~u32(0)); x.bound_blend = cp.blend_mask }
	parent: Texture
	if cmd.clip != 0 { parent = x.state.masks[cmd.clip] }
	exec_bind_inputs(x, 0, parent)
	r.ctx->DrawInstanced(4, u32(cmd.count), 0, u32(cmd.first))
	cp.stats.draws += 1
	// the canvas is the target again for what follows
	x.cur, x.cur_main = 0, true
}

@(private)
exec_put :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	r := x.r
	b := cmd.box
	w, h := int(b[2]), int(b[3])
	pix := x.list.pixels
	if cmd.pix < 0 || cmd.pix + w * h * 4 > len(pix) || w <= 0 || h <= 0 { return }
	td := &r.textures[int(x.target)]
	x0, y0 := int(b[0]), int(b[1])
	if x0 < 0 || y0 < 0 || x0 + w > td.w || y0 + h > td.h { return }
	box := d3d11.BOX{left = u32(x0), top = u32(y0), front = 0, right = u32(x0 + w), bottom = u32(y0 + h), back = 1}
	// not while the texture is the bound target of a later draw: a draw state is re-made by the next command
	r.ctx->UpdateSubresource(td.tex, 0, &box, raw_data(pix[cmd.pix:]), u32(w * 4), 0)
	x.cp.stats.uploads += 1
	x.cp.stats.upload_bytes += w * h * 4
}

@(private)
exec_snapshot :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	if !exec_scratch(x, &x.snap) { return }
	exec_copy_region(x, x.snap, cmd.box)
	x.bound_src = -1
}

@(private)
exec_layer_begin :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	r, cp := x.r, x.cp
	w, h := int(cmd.box[2] - cmd.box[0]), int(cmd.box[3] - cmd.box[1])
	if w <= 0 || h <= 0 { return }
	if old, ok := cp.layers[cmd.id]; ok { pool_release(r, old.tex) }
	t := pool_acquire(r, w, h, false)
	if t == 0 { return }
	cp.layers[cmd.id] = Canvas_Layer{tex = t, box = cmd.box, live = true}
	cp.stats.layers += 1
	zero := [4]f32{}
	r.ctx->ClearRenderTargetView(r.textures[int(t)].rtv, &zero)
	exec_bind_target(x, t, {cmd.box[0], cmd.box[1]}, false)
	x.cur_main = false
}

// One full-screen pass of a layer's filter chain: `src` through the shader into `dst` (both of the layer's size, except the
// reductions of a big blur).
@(private)
exec_fx_pass :: proc(x: ^Canvas_Exec, src, dst: Texture, mode: u32, dir: [2]f32, taps: ^[MAX_BLUR_TAPS / 2][4]f32, ntaps: int, m: ^[20]f32) {
	r, cp := x.r, x.cp
	sd, dd := &r.textures[int(src)], &r.textures[int(dst)]
	fc := Canvas_Fx_Constants{mode = mode, ntaps = u32(ntaps), dir = dir, src_dim = {f32(sd.w), f32(sd.h)}}
	if taps != nil { for i in 0 ..< min(32, MAX_BLUR_TAPS / 2) { fc.taps[i] = taps[i] } }
	if m != nil {
		for row in 0 ..< 4 { fc.m[row] = {m[row * 5], m[row * 5 + 1], m[row * 5 + 2], m[row * 5 + 3]} }
		fc.m[4] = {m[4], m[9], m[14], m[19]}
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	if hr_failed(r.ctx->Map(cp.fxcb, 0, .WRITE_DISCARD, {}, &mapped)) { return }
	(^Canvas_Fx_Constants)(mapped.pData)^ = fc
	r.ctx->Unmap(cp.fxcb, 0)
	none := [3]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(3, 3, &none[0])
	rtv := dd.rtv
	r.ctx->OMSetRenderTargets(1, &rtv, nil)
	vp := d3d11.VIEWPORT{0, 0, f32(dd.w), f32(dd.h), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	rc := d3d11.RECT{0, 0, i32(dd.w), i32(dd.h)}
	r.ctx->RSSetScissorRects(1, &rc)
	mapped2: d3d11.MAPPED_SUBRESOURCE
	if hr_ok(r.ctx->Map(cp.globals, 0, .WRITE_DISCARD, {}, &mapped2)) {
		(^Canvas_Globals)(mapped2.pData)^ = Canvas_Globals{viewport = {f32(dd.w), f32(dd.h)}}
		r.ctx->Unmap(cp.globals, 0)
	}
	r.ctx->OMSetBlendState(cp.blend_mask, nil, ~u32(0))
	r.ctx->IASetInputLayout(nil)
	r.ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	r.ctx->VSSetShader(cp.full_vs, nil, 0)
	r.ctx->PSSetShader(cp.fx_ps, nil, 0)
	r.ctx->PSSetConstantBuffers(1, 1, &cp.fxcb)
	v := sd.view
	r.ctx->PSSetShaderResources(3, 1, &v)
	r.ctx->Draw(3, 0)
	none1 := [1]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(3, 1, &none1[0])
	cp.stats.draws += 1
	// the instanced pipeline is bound again by the next draw
	x.main_bound, x.cur, x.cur_main, x.bound_src, x.bound_clip, x.bound_blend = false, 0, true, -1, -1, nil
}

@(private)
exec_layer_fx :: proc(x: ^Canvas_Exec, cmd: Canvas_Cmd) {
	r, cp := x.r, x.cp
	src, ok := cp.layers[cmd.id2]
	if !ok { return }
	w, h := r.textures[int(src.tex)].w, r.textures[int(src.tex)].h
	dst_tex := pool_acquire(r, w, h, false)
	if dst_tex == 0 { return }
	switch cmd.fx {
	case .Copy:
		m: [20]f32
		exec_fx_pass(x, src.tex, dst_tex, 2, {}, nil, 0, &m)
	case .Matrix:
		m := cmd.color_matrix
		exec_fx_pass(x, src.tex, dst_tex, 0, {}, nil, 0, &m)
	case .Blur:
		exec_blur(x, src.tex, dst_tex, cmd.sigma)
	}
	if cmd.id == cmd.id2 {
		pool_release(r, src.tex)
		if x.bound_src == src.tex { x.bound_src = -1 }
	}
	cp.layers[cmd.id] = Canvas_Layer{tex = dst_tex, box = src.box, live = true}
}

// A gaussian blur of `src` into `dst` (same size), both directions. A big one runs on an image reduced by 2, 4, 8...: the cost
// of a pass does not grow with the radius.
@(private)
exec_blur :: proc(x: ^Canvas_Exec, src, dst: Texture, sigma: f32) {
	r := x.r
	w, h := r.textures[int(src)].w, r.textures[int(src)].h
	m: [20]f32
	if sigma <= 0.01 { exec_fx_pass(x, src, dst, 2, {}, nil, 0, &m); return }
	levels := 0
	s := sigma
	for s > CANVAS_BLUR_DIRECT_SIGMA && levels < 4 { s *= 0.5; levels += 1 }
	chain: [5]Texture   // chain[l]: the image reduced l times (chain[0] is the source)
	sizes: [5][2]int
	chain[0], sizes[0] = src, {w, h}
	for l in 1 ..= levels {
		sizes[l] = {max((sizes[l - 1].x + 1) / 2, 1), max((sizes[l - 1].y + 1) / 2, 1)}
		chain[l] = pool_acquire(r, sizes[l].x, sizes[l].y, false)
		if chain[l] == 0 {
			for k in 1 ..< l { pool_release(r, chain[k]) }
			exec_fx_pass(x, src, dst, 2, {}, nil, 0, &m)
			return
		}
		exec_fx_pass(x, chain[l - 1], chain[l], 2, {}, nil, 0, &m)
	}
	cw, ch := sizes[levels].x, sizes[levels].y
	taps: [MAX_BLUR_TAPS / 2][4]f32
	n := blur_taps(s, &taps)
	tmp := pool_acquire(r, cw, ch, false)
	if tmp == 0 {
		for k in 1 ..= levels { pool_release(r, chain[k]) }
		exec_fx_pass(x, src, dst, 2, {}, nil, 0, &m)
		return
	}
	last := levels == 0 ? dst : chain[levels]
	exec_fx_pass(x, chain[levels], tmp, 1, {1 / f32(cw), 0}, &taps, n, nil)
	exec_fx_pass(x, tmp, last, 1, {0, 1 / f32(ch)}, &taps, n, nil)
	pool_release(r, tmp)
	for l := levels; l >= 1; l -= 1 {
		next := l > 1 ? chain[l - 1] : dst
		exec_fx_pass(x, chain[l], next, 2, {}, nil, 0, &m)
	}
	for l in 1 ..= levels { pool_release(r, chain[l]) }
}

}   // when !USE_WGPU

// The whole canvas to one premultiplied color (a new canvas that is opaque black, reset()).
canvas_clear :: proc(r: ^Renderer, t: Texture, color: [4]f32) {
	when USE_WGPU { return } else {
		if int(t) <= 0 || int(t) >= len(r.textures) || r.lost { return }
		td := &r.textures[int(t)]
		if td.canvas != 2 || td.rtv == nil { return }
		c := color
		r.ctx->ClearRenderTargetView(td.rtv, &c)
		if td.mips { td.mips_dirty = true }
	}
}

////////////////////////////////
// Read-back

// The coverage (0..255, canvas size, rows packed) of clip mask `id` of a canvas, from the last submit that made it and not yet
// freed. false: there is no such mask.
canvas_read_mask :: proc(r: ^Renderer, t: Texture, id: i32, out: []u8) -> bool {
	when USE_WGPU { return false } else {
		if int(t) <= 0 || int(t) >= len(r.textures) || r.lost { return false }
		s, ok := r.canvas.states[t]
		if !ok { return false }
		m, mok := s.masks[id]
		if !mok { return false }
		td := &r.textures[int(m)]
		if len(out) < td.w * td.h { return false }
		desc := d3d11.TEXTURE2D_DESC{Width = u32(td.w), Height = u32(td.h), MipLevels = 1, ArraySize = 1, Format = .R8_UNORM,
			SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ}}
		st: ^d3d11.ITexture2D
		if hr_failed(r.device->CreateTexture2D(&desc, nil, &st)) { return false }
		defer st->Release()
		r.ctx->CopyResource(st, td.tex)
		mapped: d3d11.MAPPED_SUBRESOURCE
		if hr_failed(r.ctx->Map(st, 0, .READ, {}, &mapped)) { return false }
		defer r.ctx->Unmap(st, 0)
		for row in 0 ..< td.h {
			src := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(row) * uintptr(mapped.RowPitch)), td.w)
			copy(out[row * td.w:][:td.w], src)
		}
		return true
	}
}

// Premultiplied sRGB-encoded RGBA8 of a w x h block at (x, y) of a canvas texture into `out` (w * h * 4 bytes, rows packed);
// what lies outside the texture reads as transparent. Waits for the GPU (a staging copy): the caller reads as late and as
// rarely as it can. false: the device is lost or the texture is not a canvas.
canvas_read :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, out: []u8) -> bool {
	when USE_WGPU { return false } else { return d3d_canvas_read(r, t, x, y, w, h, out) }
}

when !USE_WGPU {
@(private)
canvas_staging :: proc(r: ^Renderer, w, h: int) -> ^d3d11.ITexture2D {
	cp := &r.canvas
	if cp.staging != nil && cp.staging_w >= w && cp.staging_h >= h { return cp.staging }
	if cp.staging != nil { cp.staging->Release(); cp.staging = nil }
	nw, nh := max(w, cp.staging_w), max(h, cp.staging_h)
	desc := d3d11.TEXTURE2D_DESC{Width = u32(nw), Height = u32(nh), MipLevels = 1, ArraySize = 1, Format = .R8G8B8A8_UNORM,
		SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ}}
	if hr_failed(r.device->CreateTexture2D(&desc, nil, &cp.staging)) { cp.staging = nil; return nil }
	cp.staging_w, cp.staging_h = nw, nh
	return cp.staging
}

@(private)
d3d_canvas_read :: proc(r: ^Renderer, t: Texture, x, y, w, h: int, out: []u8) -> bool {
	if int(t) <= 0 || int(t) >= len(r.textures) || r.lost || w <= 0 || h <= 0 || len(out) < w * h * 4 { return false }
	td := &r.textures[int(t)]
	if td.canvas == 0 || td.canvas == 3 { return false }
	for i in 0 ..< w * h * 4 { out[i] = 0 }
	x0, y0 := max(x, 0), max(y, 0)
	x1, y1 := min(x + w, td.w), min(y + h, td.h)
	if x1 <= x0 || y1 <= y0 { return true }
	st := canvas_staging(r, x1 - x0, y1 - y0)
	if st == nil { return false }
	box := d3d11.BOX{left = u32(x0), top = u32(y0), front = 0, right = u32(x1), bottom = u32(y1), back = 1}
	r.ctx->CopySubresourceRegion(st, 0, 0, 0, 0, td.tex, 0, &box)
	mapped: d3d11.MAPPED_SUBRESOURCE
	if hr_failed(r.ctx->Map(st, 0, .READ, {}, &mapped)) { return false }
	defer r.ctx->Unmap(st, 0)
	bw := (x1 - x0) * 4
	for row in y0 ..< y1 {
		src := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(row - y0) * uintptr(mapped.RowPitch)), bw)
		copy(out[((row - y) * w + (x0 - x)) * 4:][:bw], src)
	}
	r.canvas.stats.reads += 1
	r.canvas.stats.read_bytes += (x1 - x0) * (y1 - y0) * 4
	return true
}
}   // when !USE_WGPU

// An asynchronous read-back (toBlob and the like): canvas_read_begin copies the block into a staging texture of its own and
// returns at once; canvas_read_ready says whether the GPU is done; canvas_read_finish copies the pixels out and frees it.
Canvas_Read :: struct {
	tex:   ^d3d11.ITexture2D,
	query: ^d3d11.IQuery,
	w, h:  int,
}

canvas_read_begin :: proc(r: ^Renderer, t: Texture, x, y, w, h: int) -> (rd: Canvas_Read, ok: bool) {
	when USE_WGPU { return {}, false } else {
		if int(t) <= 0 || int(t) >= len(r.textures) || r.lost || w <= 0 || h <= 0 { return }
		td := &r.textures[int(t)]
		if td.canvas == 0 || td.canvas == 3 { return }
		if x < 0 || y < 0 || x + w > td.w || y + h > td.h { return }
		desc := d3d11.TEXTURE2D_DESC{Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1, Format = .R8G8B8A8_UNORM,
			SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ}}
		if hr_failed(r.device->CreateTexture2D(&desc, nil, &rd.tex)) { return {}, false }
		box := d3d11.BOX{left = u32(x), top = u32(y), front = 0, right = u32(x + w), bottom = u32(y + h), back = 1}
		r.ctx->CopySubresourceRegion(rd.tex, 0, 0, 0, 0, td.tex, 0, &box)
		if hr_failed(r.device->CreateQuery(&{Query = .EVENT}, &rd.query)) { rd.query = nil }
		else { r.ctx->End((^d3d11.IAsynchronous)(rd.query)) }
		rd.w, rd.h = w, h
		return rd, true
	}
}

canvas_read_ready :: proc(r: ^Renderer, rd: Canvas_Read) -> bool {
	when USE_WGPU { return true } else {
		if rd.query == nil { return true }
		done: win.BOOL
		return r.ctx->GetData((^d3d11.IAsynchronous)(rd.query), &done, size_of(win.BOOL), u32(d3d11.ASYNC_GETDATA_FLAG.DONOTFLUSH)) == 0 && bool(done)
	}
}

canvas_read_finish :: proc(r: ^Renderer, rd: ^Canvas_Read, out: []u8) -> bool {
	when USE_WGPU { return false } else {
		defer {
			if rd.query != nil { rd.query->Release() }
			if rd.tex != nil { rd.tex->Release() }
			rd^ = {}
		}
		if rd.tex == nil || len(out) < rd.w * rd.h * 4 { return false }
		mapped: d3d11.MAPPED_SUBRESOURCE
		if hr_failed(r.ctx->Map(rd.tex, 0, .READ, {}, &mapped)) { return false }
		defer r.ctx->Unmap(rd.tex, 0)
		for row in 0 ..< rd.h {
			src := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(row) * uintptr(mapped.RowPitch)), rd.w * 4)
			copy(out[row * rd.w * 4:][:rd.w * 4], src)
		}
		r.canvas.stats.reads += 1
		r.canvas.stats.read_bytes += rd.w * rd.h * 4
		return true
	}
}

canvas_read_cancel :: proc(rd: ^Canvas_Read) {
	if rd.query != nil { rd.query->Release() }
	if rd.tex != nil { rd.tex->Release() }
	rd^ = {}
}
