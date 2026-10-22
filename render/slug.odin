package render

import "core:fmt"
import win "core:sys/windows"
import "vendor:directx/d3d11"

// Slug text on the D3D11 renderer (the shaders are slug.hlsl, compiled after rect.hlsl; algorithm: Eric Lengyel's Slug,
// font/slug_ref/PINNED.md). Glyphs are ordinary Rect_Inst instances of KIND_SLUG in the frame's list, so order, clips,
// transforms, fades and pictures work as for every other primitive. Only the draw call differs: frame_submit cuts a batch
// into the pieces that are Slug instances (Frame_Data.slug_runs, Replay.slug_runs) and the others, and switches the
// vertex / pixel shaders and the input layout between them (the instance buffer, constant buffers and tables stay
// bound). Their data lives in two textures a draw context fills (font.slug_sync_page): one row per glyph page.

SLUG_TEXTURE_WIDTH :: 4096   // both textures; font.SLUG_TEXTURE_WIDTH

Slug_Pipeline :: struct {
	vs:     ^d3d11.IVertexShader,
	ps:     ^d3d11.IPixelShader,
	layout: ^d3d11.IInputLayout,
	on:     bool,   // frame_submit: the Slug shaders are the bound ones
	ready:  bool,   // the textures of the frame are bound
	failed: bool,   // the device refused the shaders: no Slug text this run (until the device is recreated)
}

// The Slug pipeline exists when the first frame that draws Slug text needs it, not at start-up: creating the shaders
// costs the device's compiler several milliseconds that a renderer that never draws Slug text should not pay.
@(private)
slug_pipeline_ensure :: proc(r: ^Renderer) -> bool {
	if r.slug.vs != nil { return true }
	if r.slug.failed { return false }
	if slug_pipeline_init(r) { return true }
	slug_destroy(r)
	r.slug.failed = true   // once: the message was printed, every frame would print it again
	return false
}

// The Slug shaders and their input layout (the same instance data as the main pipeline).
@(private)
slug_pipeline_init :: proc(r: ^Renderer) -> bool {
	vs_code, vs_blob := shader_code(.Slug_VS) or_return
	defer shader_code_done(vs_blob)
	ps_code, ps_blob := shader_code(.Slug_PS) or_return
	defer shader_code_done(ps_blob)
	r.device->CreateVertexShader(raw_data(vs_code), uint(len(vs_code)), nil, &r.slug.vs)
	r.device->CreatePixelShader(raw_data(ps_code), uint(len(ps_code)), nil, &r.slug.ps)
	if r.slug.vs == nil || r.slug.ps == nil {
		fmt.eprintln("render: the Slug text shaders were refused by the device")
		return false
	}
	inst :: proc(name: cstring, idx: u32, off: u32) -> d3d11.INPUT_ELEMENT_DESC {
		return {SemanticName = name, SemanticIndex = idx, Format = .R32G32B32A32_FLOAT, InputSlot = 0,
		        AlignedByteOffset = off, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1}
	}
	elems := [?]d3d11.INPUT_ELEMENT_DESC{
		inst("DST", 0, 0), inst("SRC", 0, 16), inst("C", 0, 32), inst("C", 1, 48), inst("C", 2, 64), inst("C", 3, 80),
		inst("RADII", 0, 96), inst("STYLE", 0, 112),
		{SemanticName = "EXTRA", Format = .R32G32B32A32_UINT, AlignedByteOffset = 128, InputSlotClass = .INSTANCE_DATA, InstanceDataStepRate = 1},
	}
	if hr := r.device->CreateInputLayout(&elems[0], len(elems), raw_data(vs_code), uint(len(vs_code)), &r.slug.layout); win.FAILED(hr) {
		fmt.eprintln("render: CreateInputLayout for the Slug text failed", hr)
		return false
	}
	return true
}

@(private)
slug_destroy :: proc(r: ^Renderer) {
	if r.slug.layout != nil { r.slug.layout->Release() }
	if r.slug.ps != nil { r.slug.ps->Release() }
	if r.slug.vs != nil { r.slug.vs->Release() }
	r.slug = {}
}

// The two glyph data textures with `rows` rows each (one per glyph page, SLUG_TEXTURE_WIDTH texels wide): curves
// (RGBA16F) and bands (RG16UI), contents zero. 0, 0 when the size is out of range or the device refuses.
create_slug_textures :: proc(r: ^Renderer, rows: int) -> (curves, bands: Texture) {
	if rows <= 0 || rows > max_texture_size(r) { return 0, 0 }
	cd := Texture_Data{w = SLUG_TEXTURE_WIDTH, h = rows, size = SLUG_TEXTURE_WIDTH, kind = .Slug_Curves}
	if !texture_objects(r, &cd) { return 0, 0 }
	bd := Texture_Data{w = SLUG_TEXTURE_WIDTH, h = rows, size = SLUG_TEXTURE_WIDTH, kind = .Slug_Bands}
	if !texture_objects(r, &bd) {
		cd.view->Release()
		cd.tex->Release()
		return 0, 0
	}
	return add_texture(r, cd), add_texture(r, bd)
}

// Writes the used texels of glyph page `page` (row `page` of both textures).
update_slug_page :: proc(r: ^Renderer, curves, bands: Texture, page: int, c: [][4]f16, b: [][2]u16) {
	put :: proc(r: ^Renderer, t: Texture, kind: Texture_Kind, page: int, data: rawptr, n: int) {
		if int(t) <= 0 || int(t) >= len(r.textures) || n <= 0 { return }
		td := r.textures[int(t)]
		if td.kind != kind || page < 0 || page >= td.h || n > td.w { return }
		box := d3d11.BOX{left = 0, top = u32(page), front = 0, right = u32(n), bottom = u32(page + 1), back = 1}
		r.ctx->UpdateSubresource(td.tex, 0, &box, data, 0, 0)
	}
	put(r, curves, .Slug_Curves, page, raw_data(c), len(c))
	put(r, bands, .Slug_Bands, page, raw_data(b), len(b))
}

// Whether the frame draws any Slug instance (immediate or in a replayed picture).
@(private)
frame_has_slug :: proc(f: Frame_Data) -> bool {
	if len(f.slug_runs) > 0 { return true }
	for rp in f.replays { if len(rp.slug_runs) > 0 { return true } }
	return false
}

// Binds the glyph data textures of the frame for the pixel shader (t11, t12).
@(private)
slug_bind_inputs :: proc(r: ^Renderer, f: Frame_Data) {
	r.slug.on = false
	views := [2]^d3d11.IShaderResourceView{texture_view(r, f.slug_curves), texture_view(r, f.slug_bands)}
	r.slug.ready = views[0] != nil && views[1] != nil
	r.ctx->PSSetShaderResources(11, 2, &views[0])
}

@(private)
slug_unbind_inputs :: proc(r: ^Renderer) {
	none := [2]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(11, 2, &none[0])
}

// Switches the shaders between the main pipeline and Slug's.
@(private)
slug_select :: proc(r: ^Renderer, on: bool) {
	if on == r.slug.on { return }
	r.slug.on = on
	r.ctx->IASetInputLayout(on ? r.slug.layout : r.layout)
	r.ctx->VSSetShader(on ? r.slug.vs : r.vs, nil, 0)
	r.ctx->PSSetShader(on ? r.slug.ps : r.ps, nil, 0)
}

// Draws the instances [b.first, b.first + b.count) of the bound instance buffer: the Slug runs with the Slug shaders,
// the rest with the main ones, in order. `rp` is the replay the batch belongs to, nil for the frame's own instances.
@(private)
draw_batch_split :: proc(r: ^Renderer, f: Frame_Data, b: Batch) {
	runs := f.slug_runs
	base := 0
	if b.replay > 0 {
		rp := f.replays[b.replay - 1]
		runs, base = rp.slug_runs, int(rp.insts)
	}
	pos, end := b.first, b.first + b.count
	// the first run that ends after pos (runs are ascending)
	lo, hi := 0, len(runs)
	for lo < hi {
		mid := (lo + hi) / 2
		if base + runs[mid][0] + runs[mid][1] <= pos { lo = mid + 1 } else { hi = mid }
	}
	draw :: proc(r: ^Renderer, slug: bool, first, count: int) {
		if count <= 0 || (slug && !r.slug.ready) { return }
		slug_select(r, slug)
		r.ctx->DrawInstanced(4, u32(count), 0, u32(first))
	}
	for i := lo; i < len(runs) && pos < end; i += 1 {
		rs := base + runs[i][0]
		re := rs + runs[i][1]
		if rs >= end { break }
		if rs > pos { draw(r, false, pos, rs - pos); pos = rs }
		e := min(re, end)
		draw(r, true, pos, e - pos)
		pos = e
	}
	draw(r, false, pos, end - pos)
}
