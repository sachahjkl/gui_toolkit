#+build windows
package render

@(require) import "core:mem"
@(require) import "vendor:directx/d3d11"

// Direct3D 11 frame submission (d3d_frame_submit) and the bind / target / op / pass helpers it uses. Built only for the
// Direct3D backend (`!USE_WGPU`, Windows); the shared filter data (Pass_Constants, blur_taps, the precision setters)
// lives in filter.odin and the wgpu frame submission in wgpu_frame.odin.
when !USE_WGPU {

// Draws one frame: every batch in the order it was recorded (draw calls into the frame or a layer, clears, copies,
// filter passes). Pooled targets are handed back to the pool afterwards.
d3d_frame_submit :: proc(r: ^Renderer, f: Frame_Data) {
	defer recycle_targets(r)
	// Resolve this frame's damage region (damage.odin). A partial frame keeps the back buffer's content outside the
	// region; the deferred clear (frame_begin) is done per rectangle below. A full frame clears the whole target now.
	partial := damage_resolve(r, d3d_buffer_age(r))
	if r.damage.have_clear && !partial {
		r.damage.have_clear = false
		c := r.damage.clear
		r.ctx->ClearRenderTargetView(r.rtv, &c)
	}
	if r.lost || len(f.batches) == 0 || (len(f.insts) == 0 && len(f.ops) == 0 && len(f.replays) == 0) {
		// a partial frame with a deferred clear and nothing to draw still clears its region (a caret turning off)
		if partial && r.damage.have_clear { d3d_clear_region(r); r.damage.have_clear = false }
		return
	}
	timed := GPU_TIMING || r.gpu_timing || r.prof.on
	if timed { gpu_timing_begin(r) }
	defer if timed { gpu_timing_end(r) }
	// images updated since their last draw: rebuild their mip chains first
	for &td in r.textures {
		if td.unfilled { zero_unfilled(r, &td) }
		if td.mips_dirty { r.ctx->GenerateMips(td.view); td.mips_dirty = false }
	}
	upload_structured(r, &r.xform_buf, &r.xform_view, &r.xform_cap, raw_data(f.xforms), len(f.xforms), size_of(Xform_Data))
	upload_structured(r, &r.clip_buf, &r.clip_view, &r.clip_cap, raw_data(f.clips), len(f.clips), size_of(Clip_Data))
	upload_structured(r, &r.points_buf, &r.points_view, &r.points_cap, raw_data(f.points), len(f.points), size_of([2]f32))
	upload_structured(r, &r.grads_buf, &r.grads_view, &r.grads_cap, raw_data(f.grads), len(f.grads), size_of([4]f32))
	if len(f.apps) > 0 { upload_structured(r, &r.app_params_buf, &r.app_params_view, &r.app_params_cap, raw_data(f.app_params), len(f.app_params), size_of([4]f32)) }
	if len(f.insts) > r.inst_cap {
		if r.inst_buf != nil { r.inst_buf->Release() }
		r.inst_cap = max(len(f.insts), max(r.inst_cap * 2, 4096))
		r.device->CreateBuffer(&{ByteWidth = u32(r.inst_cap * size_of(Rect_Inst)), Usage = .DYNAMIC, BindFlags = {.VERTEX_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.inst_buf)
	}
	if len(f.insts) > 0 {
		mapped: d3d11.MAPPED_SUBRESOURCE
		r.ctx->Map(r.inst_buf, 0, .WRITE_DISCARD, {}, &mapped)
		mem.copy(mapped.pData, raw_data(f.insts), len(f.insts) * size_of(Rect_Inst))
		r.ctx->Unmap(r.inst_buf, 0)
	}
	profile_step(r, .Upload, 0, 0, 0, len(f.insts) * size_of(Rect_Inst))

	bind_main(r)
	slug_frame := frame_has_slug(f)
	has_slug := slug_frame && slug_pipeline_ensure(r)
	if has_slug { slug_bind_inputs(r, f) }
	if slug_frame && !has_slug { r.slug.ready = false }   // no Slug shaders: its runs are skipped (draw_batch_split), the rest is drawn
	write_replay(r, nil, false)
	if r.prof.cur != nil && r.rtv != nil && r.swapchain != nil && !partial {
		// first use of the back buffer, alone: the compositor may still hold it, and the draw that touches it first
		// would otherwise carry that wait. Every full frame draws all of its pixels, so the clear changes nothing.
		// A partial frame keeps the back buffer's content, so this clear is skipped (it would erase it).
		zero := [4]f32{}
		r.ctx->ClearRenderTargetView(r.rtv, &zero)
		profile_step(r, .Acquire, r.size.x, r.size.y, r.size.x * r.size.y, r.size.x * r.size.y * 4)
	}
	// a partial frame clears only its region, now that the pipeline is bound (D3D11 has no scissored ClearRenderTargetView)
	if partial && r.damage.have_clear { r.damage.have_clear = false; d3d_clear_region(r) }
	cur, cur_ok := -1, false
	cur_size: [2]int
	cur_origin: [2]f32
	bound, bound_image, bound_backdrop: Texture = -1, -1, -1
	replacing := false
	bound_replay := 0      // the Replay in b2 (0: immediate instances, identity)
	retained_vb := false   // the retained instance heap is the bound vertex buffer
	drawing := false       // profile: a run of draw calls into `cur` is open
	for b, bi in f.batches {
		if b.op > 0 {
			if drawing { profile_step(r, cur == 0 ? .Draw_Frame : .Draw_Layer, 0, 0, 0, 0); drawing = false }
			op := &f.ops[b.op - 1]
			if run_op(r, f, op) {
				// a filter pass replaced the pipeline and the target
				bind_main(r)
				if has_slug { slug_bind_inputs(r, f) }
				retained_vb = false
				cur = -1
			}
			continue
		}
		if b.count == 0 { continue }
		if b.replay > len(f.replays) || (b.replay > 0 && r.heaps[.Insts].buf == nil) { continue }
		if b.target != cur {
			if drawing { profile_step(r, cur == 0 ? .Draw_Frame : .Draw_Layer, 0, 0, 0, 0); drawing = false }
			cur = b.target
			cur_ok, cur_size, cur_origin = bind_target(r, f, cur)
			bound, bound_image, bound_backdrop = -1, -1, -1
			profile_target_change(r)
		}
		if !cur_ok { continue }
		if (b.replay > 0) != retained_vb {
			retained_vb = b.replay > 0
			stride := u32(size_of(Rect_Inst))
			offset := u32(0)
			vb := retained_vb ? r.heaps[.Insts].buf : r.inst_buf
			r.ctx->IASetVertexBuffers(0, 1, &vb, &stride, &offset)
		}
		if b.replay != bound_replay {
			bound_replay = b.replay
			write_replay(r, b.replay > 0 ? &f.replays[b.replay - 1] : nil, b.replay > 0)
		}
		if b.tex != bound || b.image != bound_image || b.backdrop != bound_backdrop {
			views := [2]^d3d11.IShaderResourceView{texture_view(r, b.tex), texture_view(r, b.image)}
			r.ctx->PSSetShaderResources(0, 2, &views[0])
			bd := texture_view(r, b.backdrop)
			r.ctx->PSSetShaderResources(5, 1, &bd)
			bound, bound_image, bound_backdrop = b.tex, b.image, b.backdrop
		}
		if (b.backdrop != 0) != replacing {
			replacing = b.backdrop != 0
			r.ctx->OMSetBlendState(replacing ? r.blend_replace : r.blend, nil, ~u32(0))
		}
		clip := b.clip
		// partial redraw: a batch drawing into the frame target (cur == 0, screen pixels) is clipped to the damaged
		// region, and skipped when it touches none of it. Layers (cur > 0, their own space) are not touched: they are
		// intermediate images sampled back into the frame, and the composite that reads them is itself clipped.
		if partial && cur == 0 {
			dc, draw := damage_clip_batch(&r.damage, clip)
			if !draw { continue }
			clip = dc
		}
		rc := d3d11.RECT{
			left   = i32(clamp(clip.x - cur_origin.x, 0, f32(cur_size.x))), top    = i32(clamp(clip.y - cur_origin.y, 0, f32(cur_size.y))),
			right  = i32(clamp(clip.z - cur_origin.x, 0, f32(cur_size.x))), bottom = i32(clamp(clip.w - cur_origin.y, 0, f32(cur_size.y))),
		}
		if rc.right <= rc.left || rc.bottom <= rc.top { continue }
		r.ctx->RSSetScissorRects(1, &rc)
		if b.app > 0 {
			d3d_draw_app(r, f, b)
		} else if slug_frame {
			draw_batch_split(r, f, b)
		} else {
			r.ctx->DrawInstanced(4, u32(b.count), 0, u32(b.first))
		}
		drawing = true
		if r.prof.detail && r.prof.cur != nil {
			d := Gpu_Step_Rec{batch = i32(bi), insts = i32(b.count), scissor = {rc.left, rc.top, rc.right, rc.bottom}}
			if b.replay > 0 {
				d.kinds = 1 << 31
			} else if b.first + b.count <= len(f.insts) {
				for inst in f.insts[b.first:][:b.count] { d.kinds |= 1 << u32(inst.use_tex); d.flags |= inst.flags }
			}
			profile_step(r, cur == 0 ? .Draw_Frame : .Draw_Layer, 0, 0, 0, 0, d)
			drawing = false
		}
	}
	if drawing { profile_step(r, cur == 0 ? .Draw_Frame : .Draw_Layer, 0, 0, 0, 0) }
	unbind_inputs(r)
	if has_slug {
		slug_select(r, false)
		slug_unbind_inputs(r)
	}
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	// render.damage.verify: recompose the whole frame into the reference and compare, while the layers are still alive
	if partial && r.damage.have_region && r.damage.verify { d3d_damage_verify(r, f) }
}

// Fixed state of the instanced-quad pipeline (rect.wgsl).
@(private)
bind_main :: proc(r: ^Renderer) {
	r.ctx->RSSetState(r.raster)
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	r.ctx->IASetPrimitiveTopology(.TRIANGLESTRIP)
	r.ctx->IASetInputLayout(r.layout)
	stride := u32(size_of(Rect_Inst))
	offset := u32(0)
	r.ctx->IASetVertexBuffers(0, 1, &r.inst_buf, &stride, &offset)
	r.ctx->VSSetShader(r.vs, nil, 0)
	r.ctx->VSSetConstantBuffers(0, 1, &r.globals)
	r.ctx->VSSetConstantBuffers(2, 1, &r.replay_cb)
	r.ctx->VSSetShaderResources(2, 1, &r.xform_view)
	r.ctx->PSSetShader(r.ps, nil, 0)
	r.ctx->PSSetConstantBuffers(0, 1, &r.globals)   // the pixel shader reads the corner shape and the target origin
	r.ctx->PSSetConstantBuffers(2, 1, &r.replay_cb)
	samplers := [4]^d3d11.ISamplerState{r.sampler, r.sampler_img, r.sampler_wrap, r.sampler_border}
	r.ctx->PSSetSamplers(0, 4, &samplers[0])
	tables := [2]^d3d11.IShaderResourceView{r.clip_view, r.points_view}
	r.ctx->PSSetShaderResources(3, 2, &tables[0])
	// heaps no picture used yet are bound as a 1-element placeholder: the shader declares them, the debug layer reports
	// every draw with an unbound slot (costly), and reads of nothing return zeros anyway
	heap_view :: proc(r: ^Renderer, k: Heap_Kind) -> ^d3d11.IShaderResourceView {
		if r.heaps[k].view != nil { return r.heaps[k].view }
		if r.heaps[k].buf == nil { heap_grow(r, k, 1) }
		return r.heaps[k].view
	}
	slots := heap_view(r, .Slots)
	r.ctx->VSSetShaderResources(7, 1, &slots)
	retained := [5]^d3d11.IShaderResourceView{r.grads_view, slots, heap_view(r, .Clips), heap_view(r, .Points), heap_view(r, .Grads)}
	r.ctx->PSSetShaderResources(6, 5, &retained[0])
	r.slug.on = false
}

// Textures a step reads (t0, t1, t5) are unbound before another step writes one of them.
@(private)
unbind_inputs :: proc(r: ^Renderer) {
	none := [2]^d3d11.IShaderResourceView{}
	r.ctx->PSSetShaderResources(0, 2, &none[0])
	r.ctx->PSSetShaderResources(5, 1, &none[0])
}

// Makes `target` (0 = the frame, k = layers[k - 1]) the render target: viewport, origin in the constant buffer.
@(private)
bind_target :: proc(r: ^Renderer, f: Frame_Data, target: int) -> (ok: bool, size: [2]int, origin: [2]f32) {
	rtv := r.rtv
	size = r.size
	space := r.space
	if target > 0 {
		if target > len(f.layers) { return }
		ly := f.layers[target - 1]
		if int(ly.tex) <= 0 || int(ly.tex) >= len(r.textures) || r.textures[int(ly.tex)].rtv == nil { return }
		rtv, size, origin, space = r.textures[int(ly.tex)].rtv, ly.size, ly.origin, ly.space
	}
	unbind_inputs(r)
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.globals, 0, .WRITE_DISCARD, {}, &mapped)
	sm := clamp(r.corner_smoothing, 0, 1)
	// n = 2.6 softens the arc-to-edge junction without turning capsules into rounded boxes; the radius is enlarged
	// a bit so the corners do not look tighter than circular ones
	text_gamma: f32
	switch r.text.curve {
	case .None: text_gamma = 0
	case .Srgb: text_gamma = -1
	case .Power: text_gamma = max(r.text.gamma, 0.25)
	}
	(^Globals)(mapped.pData)^ = Globals{
		viewport_size = {f32(size.x), f32(size.y)}, corner_n = 2 + 0.6 * sm, corner_boost = 1 + 0.25 * sm,
		target_origin = origin, target_space = u32(space),
		text_gamma = text_gamma, text_contrast = r.text.contrast, text_exponent = max(r.text.coverage_exponent, 0.1),
	}
	r.ctx->Unmap(r.globals, 0)
	vp := d3d11.VIEWPORT{0, 0, f32(size.x), f32(size.y), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	target_rtv := rtv
	r.ctx->OMSetRenderTargets(1, &target_rtv, nil)
	return true, size, origin
}

// Runs a non-draw step. Returns true when it changed the pipeline (a filter pass).
@(private)
run_op :: proc(r: ^Renderer, f: Frame_Data, op: ^Op) -> bool {
	valid :: proc(r: ^Renderer, t: Texture) -> bool { return int(t) > 0 && int(t) < len(r.textures) && r.textures[int(t)].tex != nil }
	switch op.kind {
	case .Clear:
		if !valid(r, op.dst) || r.textures[int(op.dst)].rtv == nil { return false }
		zero := [4]f32{}
		r.ctx->ClearRenderTargetView(r.textures[int(op.dst)].rtv, &zero)
		td := r.textures[int(op.dst)]
		profile_step(r, .Clear, td.w, td.h, td.w * td.h, td.w * td.h * texture_bpp(r, op.dst))
	case .Copy:
		if !valid(r, op.dst) { return false }
		src := r.frame_tex
		lim := r.size
		if op.source > 0 {
			if op.source > len(f.layers) || !valid(r, f.layers[op.source - 1].tex) { return false }
			src = r.textures[int(f.layers[op.source - 1].tex)].tex
			lim = f.layers[op.source - 1].size
		}
		if src == nil { return false }
		d := r.textures[int(op.dst)]
		x0, y0 := clamp(op.box[0], 0, i32(lim.x)), clamp(op.box[1], 0, i32(lim.y))
		x1, y1 := clamp(op.box[2], x0, i32(lim.x)), clamp(op.box[3], y0, i32(lim.y))
		x1, y1 = min(x1, x0 + i32(d.w)), min(y1, y0 + i32(d.h))
		if x1 <= x0 || y1 <= y0 { return false }
		box := d3d11.BOX{left = u32(x0), top = u32(y0), front = 0, right = u32(x1), bottom = u32(y1), back = 1}
		r.ctx->CopySubresourceRegion(d.tex, 0, 0, 0, 0, src, 0, &box)
		px := int(x1 - x0) * int(y1 - y0)
		profile_step(r, .Copy, int(x1 - x0), int(y1 - y0), px, px * 2 * max(texture_bpp(r, op.dst), 4))
	case .Pass:
		run_pass(r, &op.pass)
		return true
	case .Mips:
		if !valid(r, op.dst) || r.textures[int(op.dst)].view == nil || !r.textures[int(op.dst)].mips { return false }
		r.ctx->GenerateMips(r.textures[int(op.dst)].view)
	case .Read:
		if op.source <= 0 || op.source > len(f.layers) || !valid(r, f.layers[op.source - 1].tex) { readback_copy(r, u32(op.readback), nil, {}, .Linear); return false }
		ly := f.layers[op.source - 1]
		readback_copy(r, u32(op.readback), r.textures[int(ly.tex)].tex, op.box, ly.space)
	}
	return false
}

// A filter pass writes its region and a ring of one transparent texel past its right and bottom edges, and reads its
// sources no further than that ring: no clear of the whole texture is needed (texels further away keep whatever an
// earlier user of the pooled texture left, and are never read).
@(private)
run_pass :: proc(r: ^Renderer, p: ^Pass) {
	t := int(p.dst.tex)
	if t <= 0 || t >= len(r.textures) || r.textures[t].rtv == nil || p.dst.size.x <= 0 || p.dst.size.y <= 0 { return }
	dtd := r.textures[t]
	unbind_inputs(r)
	rtv := dtd.rtv
	r.ctx->OMSetRenderTargets(1, &rtv, nil)
	profile_target_change(r)
	w, h := min(p.dst.size.x + 1, dtd.w), min(p.dst.size.y + 1, dtd.h)
	vp := d3d11.VIEWPORT{0, 0, f32(w), f32(h), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	rc := d3d11.RECT{0, 0, i32(w), i32(h)}
	r.ctx->RSSetScissorRects(1, &rc)

	dim :: proc(r: ^Renderer, t: Texture) -> [2]f32 {
		if int(t) <= 0 || int(t) >= len(r.textures) { return {1, 1} }
		return {f32(max(r.textures[int(t)].w, 1)), f32(max(r.textures[int(t)].h, 1))}
	}
	pc := Pass_Constants{
		src_origin = p.src.origin, src_scale = p.src.scale, mode = u32(p.mode),
		src_size = {f32(p.src.size.x), f32(p.src.size.y)}, src_dim = dim(r, p.src.tex),
		dst_origin = p.dst.origin, dst_scale = p.dst.scale, flags = p.flags,
		src2_origin = p.src2.origin, src2_scale = p.src2.scale,
		src2_size = {f32(p.src2.size.x), f32(p.src2.size.y)}, src2_dim = dim(r, p.src2.tex),
		dir = p.dir, offset = p.offset, color = p.color,
		matrix_count = u32(clamp(p.matrix_count, 0, MAX_COLOR_MATRICES)),
		dst_size = {f32(p.dst.size.x), f32(p.dst.size.y)}, factor = f32(clamp(p.factor, 2, 8)),
	}
	if p.mode == .Blur { pc.taps = u32(blur_taps(p.sigma, &pc.tap)) }
	for k in 0 ..< int(pc.matrix_count) {
		m := p.matrices[k]
		for row in 0 ..< 4 { pc.m[k * 5 + row] = {m[row * 5], m[row * 5 + 1], m[row * 5 + 2], m[row * 5 + 3]} }
		pc.m[k * 5 + 4] = {m[4], m[9], m[14], m[19]}
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.fx_constants, 0, .WRITE_DISCARD, {}, &mapped)
	(^Pass_Constants)(mapped.pData)^ = pc
	r.ctx->Unmap(r.fx_constants, 0)

	r.ctx->OMSetBlendState(r.blend_replace, nil, ~u32(0))
	r.ctx->IASetInputLayout(nil)
	r.ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	r.ctx->VSSetShader(r.fx_vs, nil, 0)
	r.ctx->PSSetShader(r.fx_ps, nil, 0)
	r.ctx->PSSetConstantBuffers(1, 1, &r.fx_constants)
	r.ctx->PSSetSamplers(0, 1, &r.sampler_border)
	views := [2]^d3d11.IShaderResourceView{texture_view(r, p.src.tex), texture_view(r, p.src2.tex)}
	r.ctx->PSSetShaderResources(0, 2, &views[0])
	r.ctx->Draw(3, 0)
	unbind_inputs(r)
	if r.prof.cur != nil {
		kind: Gpu_Step
		switch p.mode {
		case .Color: kind = .Color
		case .Blur: kind = .Blur
		case .Downsample: kind = .Downsample
		case .Shadow: kind = .Shadow
		case .Mask: kind = .Mask
		}
		px := w * h
		bytes := px * texture_bpp(r, p.dst.tex) + p.src.size.x * p.src.size.y * texture_bpp(r, p.src.tex)
		if p.src2.tex != 0 { bytes += p.src2.size.x * p.src2.size.y * texture_bpp(r, p.src2.tex) }
		profile_step(r, kind, w, h, px, bytes)
	}
}

}   // when !USE_WGPU
