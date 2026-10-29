#+build windows
package render

@(require) import "core:mem"
@(require) import win "core:sys/windows"
@(require) import "vendor:directx/d3d11"
@(require) import "vendor:directx/dxgi"

// render.damage.verify (set_damage_verify, or the environment variable TOOLKIT_DAMAGE_VERIFY): a development check that
// a partial frame is byte-for-byte identical to a full render of the same frame. On each verified frame the renderer
// draws the whole frame a second time into a persistent reference texture, reads the reference and the partial back
// buffer back, and reports the first pixel that differs and the damage rectangle it is in (or that it is outside the
// region, which means a rectangle is missing). It costs a full extra frame and two read-backs: for development only.
// Direct3D only; the backend-independent comparison (damage_compare) lives in damage.odin, shared with the wgpu path.
when !USE_WGPU {

@(private)
d3d_verify_ensure_ref :: proc(r: ^Renderer) -> bool {
	if r.damage_verify_ref != nil {
		desc: d3d11.TEXTURE2D_DESC
		r.damage_verify_ref->GetDesc(&desc)
		if int(desc.Width) == r.size.x && int(desc.Height) == r.size.y { return true }
		r.damage_verify_ref->Release(); r.damage_verify_ref = nil
		if r.damage_verify_rtv != nil { r.damage_verify_rtv->Release(); r.damage_verify_rtv = nil }
	}
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
	}, nil, &r.damage_verify_ref)
	if r.damage_verify_ref == nil { return false }
	view := r.space == .Srgb ? dxgi.FORMAT.B8G8R8A8_UNORM : dxgi.FORMAT.B8G8R8A8_UNORM_SRGB
	r.device->CreateRenderTargetView(r.damage_verify_ref, &{Format = view, ViewDimension = .TEXTURE2D}, &r.damage_verify_rtv)
	return r.damage_verify_rtv != nil
}

// Renders the whole frame once more into the reference texture and compares it with the partial back buffer. Called at
// the end of d3d_frame_submit, while the layer textures the frame used are still alive (before recycle_targets) and the
// back buffer holds the partial result. Only the frame-target batches are replayed: the offscreen layers and the ops
// (filter passes, copies) already ran in the partial pass and their results are still bound, so the composite into the
// reference reproduces the full frame exactly, without running the ops a second time.
@(private)
d3d_damage_verify :: proc(r: ^Renderer, f: Frame_Data) {
	if r.swapchain == nil || r.frame_tex == nil { return }
	if !d3d_verify_ensure_ref(r) { return }

	// full composite into the reference, with no damage region (every frame-target batch drawn whole)
	saved_rtv := r.rtv
	saved_have := r.damage.have_region
	r.rtv = r.damage_verify_rtv
	r.damage.have_region = false
	defer { r.rtv = saved_rtv; r.damage.have_region = saved_have }
	c := r.damage.clear
	if r.space == .Srgb && c.a > 0 { for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a } }
	r.ctx->ClearRenderTargetView(r.damage_verify_rtv, &c)
	bind_main(r)
	slug_frame := frame_has_slug(f)
	has_slug := slug_frame && r.slug.ready
	if has_slug { slug_bind_inputs(r, f) }
	d3d_draw_frame_batches(r, f, slug_frame, has_slug)

	ref := d3d_read_texture(r, r.damage_verify_ref)
	got := d3d_read_texture(r, r.frame_tex)
	defer { delete(ref); delete(got) }
	if ref == nil || got == nil { return }
	damage_compare(&r.damage, ref, got, r.size)
}

// Replays the frame-target batches (target 0) into the currently bound render target, whole (no damage clipping, no
// ops, no layers): the verify pass uses it to recompose the full frame from the layers already drawn.
@(private)
d3d_draw_frame_batches :: proc(r: ^Renderer, f: Frame_Data, slug_frame, has_slug: bool) {
	ok, _, _ := bind_target(r, f, 0)
	if !ok { return }
	write_replay(r, nil, false)
	bound, bound_image, bound_backdrop: Texture = -1, -1, -1
	replacing := false
	bound_replay := 0
	retained_vb := false
	for b in f.batches {
		if b.op > 0 || b.target != 0 || b.count == 0 { continue }
		if b.replay > len(f.replays) || (b.replay > 0 && r.heaps[.Insts].buf == nil) { continue }
		if (b.replay > 0) != retained_vb {
			retained_vb = b.replay > 0
			stride, offset := u32(size_of(Rect_Inst)), u32(0)
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
		rc := d3d11.RECT{
			left = i32(clamp(b.clip.x, 0, f32(r.size.x))), top = i32(clamp(b.clip.y, 0, f32(r.size.y))),
			right = i32(clamp(b.clip.z, 0, f32(r.size.x))), bottom = i32(clamp(b.clip.w, 0, f32(r.size.y))),
		}
		if rc.right <= rc.left || rc.bottom <= rc.top { continue }
		r.ctx->RSSetScissorRects(1, &rc)
		if b.app > 0 { d3d_draw_app(r, f, b) }
		else if slug_frame { draw_batch_split(r, f, b) }
		else { r.ctx->DrawInstanced(4, u32(b.count), 0, u32(b.first)) }
	}
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	unbind_inputs(r)
	if has_slug { slug_select(r, false); slug_unbind_inputs(r) }
}

// A BGRA8 read-back of a whole texture, tightly packed (size.x * size.y * 4 bytes). nil on failure.
@(private)
d3d_read_texture :: proc(r: ^Renderer, tex: ^d3d11.ITexture2D) -> []u8 {
	staging: ^d3d11.ITexture2D
	r.device->CreateTexture2D(&{
		Width = u32(r.size.x), Height = u32(r.size.y), MipLevels = 1, ArraySize = 1, Format = .B8G8R8A8_TYPELESS,
		SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
	}, nil, &staging)
	if staging == nil { return nil }
	defer staging->Release()
	r.ctx->CopyResource(staging, tex)
	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.FAILED(r.ctx->Map(staging, 0, .READ, {}, &mapped)) { return nil }
	defer r.ctx->Unmap(staging, 0)
	out := make([]u8, r.size.x * r.size.y * 4)
	for y in 0 ..< r.size.y {
		row := mem.slice_ptr((^u8)(uintptr(mapped.pData) + uintptr(y * int(mapped.RowPitch))), r.size.x * 4)
		copy(out[y * r.size.x * 4:], row)
	}
	return out
}

}   // when !USE_WGPU
