#+build windows
package render

import "core:mem"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

when !USE_WGPU {

// Partial redraw on the Direct3D 11 / DXGI backend: clearing only the damaged region, and presenting it with
// Present1 + DXGI_PRESENT_PARAMETERS (dirty rectangles and a scroll rectangle). See damage.odin for the region.
//
// Flip swap chains (FLIP_SEQUENTIAL / FLIP_DISCARD) do NOT keep the back buffer's content from frame to frame: after a
// present the engine hands back a buffer that holds some earlier frame (how old depends on the buffer count and what
// the compositor did with it). Presenting only the dirty rectangles therefore leaves the rest of the buffer stale
// unless the renderer put the right pixels there itself. The buffer-age scheme (d3d_partial_begin) does exactly that:
// it learns how old the back buffer it just acquired is and redraws the union of the regions of the last `age` frames,
// not only this frame's. With two buffers the age is almost always 2 (this frame + the previous one). A buffer whose
// age is unknown, or older than the history kept, falls back to a full frame.

// How old the back buffer just acquired is, in frames, for the buffer-age scheme. A flip swap chain hands back the
// buffer presented `BufferCount` frames ago, so after a continuous run of partial presents the age equals the buffer
// count (2 by default). Until that many partial frames have been presented, or when an ordinary (full) present reset
// the content of every buffer, the history is short and damage_resolve falls back to a full frame. Offscreen or no
// swap chain: 1 (the single target keeps its content).
@(private)
d3d_buffer_age :: proc(r: ^Renderer) -> int {
	if r.swapchain == nil { return 1 }
	return clamp(r.swap_buffers, 2, 16) if r.swap_buffers > 0 else 2
}

// Clears every rectangle of the damaged region to the frame's clear colour, scissored. The frame target and the main
// pipeline are already bound (d3d_frame_submit). D3D11 has no scissored ClearRenderTargetView, so each rectangle is a
// solid quad drawn with replace blending; cheap (a handful of rectangles, four vertices each).
@(private)
d3d_clear_region :: proc(r: ^Renderer) {
	d := &r.damage
	if d.render_count == 0 { return }
	c := d.clear
	if r.space == .Srgb && c.a > 0 {
		for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a }
	}
	d3d_clear_quads_ensure(r)
	if r.damage_clear_vb == nil { return }
	insts := make([]Rect_Inst, d.render_count, context.temp_allocator)
	for i in 0 ..< d.render_count {
		rc := d.render_rects[i]
		insts[i] = Rect_Inst{
			dst = {f32(rc.x0), f32(rc.y0), f32(rc.x1), f32(rc.y1)},
			colors = {c, c, c, c},
			soft = 1, use_tex = KIND_SHAPE, tex_size = 1,
		}
	}
	if d.render_count > r.damage_clear_cap {
		if r.damage_clear_vb != nil { r.damage_clear_vb->Release() }
		r.damage_clear_cap = max(d.render_count, MAX_DAMAGE_RECTS)
		r.device->CreateBuffer(&{ByteWidth = u32(r.damage_clear_cap * size_of(Rect_Inst)), Usage = .DYNAMIC, BindFlags = {.VERTEX_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.damage_clear_vb)
		if r.damage_clear_vb == nil { return }
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	r.ctx->Map(r.damage_clear_vb, 0, .WRITE_DISCARD, {}, &mapped)
	mem.copy(mapped.pData, raw_data(insts), d.render_count * size_of(Rect_Inst))
	r.ctx->Unmap(r.damage_clear_vb, 0)

	rtv := r.rtv
	r.ctx->OMSetRenderTargets(1, &rtv, nil)
	vp := d3d11.VIEWPORT{0, 0, f32(r.size.x), f32(r.size.y), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	full := d3d11.RECT{0, 0, i32(r.size.x), i32(r.size.y)}
	r.ctx->RSSetScissorRects(1, &full)
	r.ctx->OMSetBlendState(r.blend_replace, nil, ~u32(0))
	stride, offset := u32(size_of(Rect_Inst)), u32(0)
	r.ctx->IASetVertexBuffers(0, 1, &r.damage_clear_vb, &stride, &offset)
	write_replay(r, nil, false)
	r.ctx->DrawInstanced(4, u32(d.render_count), 0, 0)
	// restore the frame's blend and vertex buffer for the batch loop that follows
	r.ctx->OMSetBlendState(r.blend, nil, ~u32(0))
	r.ctx->IASetVertexBuffers(0, 1, &r.inst_buf, &stride, &offset)
}

@(private)
d3d_clear_quads_ensure :: proc(r: ^Renderer) {
	if r.damage_clear_vb != nil { return }
	r.damage_clear_cap = MAX_DAMAGE_RECTS
	r.device->CreateBuffer(&{ByteWidth = u32(r.damage_clear_cap * size_of(Rect_Inst)), Usage = .DYNAMIC, BindFlags = {.VERTEX_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &r.damage_clear_vb)
}

// Presents the frame, telling DXGI which rectangles changed (Present1 pDirtyRects) and, if the content scrolled, the
// block that moved (pScrollRect / pScrollOffset). Falls back to a plain Present when the swap chain is not an
// ISwapChain1, when the whole frame is damaged, or when tearing is requested (ALLOW_TEARING forbids dirty rects).
// Returns the HRESULT.
@(private)
d3d_present_partial :: proc(r: ^Renderer, vsync: bool) -> win.HRESULT {
	d := &r.damage
	p := &r.present
	if p.interval == 0 { p.interval = 1 }
	tearing := p.mode == .Tearing && p.tearing_ok && .ALLOW_TEARING in r.swap_flags
	sync: u32 = vsync && !tearing ? p.interval : 0
	flags: dxgi.PRESENT
	if sync == 0 && .ALLOW_TEARING in r.swap_flags && p.tearing_ok { flags += {.ALLOW_TEARING} }

	// a full frame (no region, or tearing which forbids dirty rects): the ordinary path keeps the statistics logic
	if !d.have_region || tearing || r.swapchain == nil {
		return present_frame(r, vsync)
	}

	// dirty rectangles: this frame's region. (Present1 clamps them to the buffer; empty ones are dropped.)
	rects: [MAX_DAMAGE_RECTS]dxgi.RECT
	n := 0
	for i in 0 ..< d.count {
		rr := d.rects[i]
		if rr.x1 <= rr.x0 || rr.y1 <= rr.y0 { continue }
		rects[n] = {left = rr.x0, top = rr.y0, right = rr.x1, bottom = rr.y1}
		n += 1
	}
	params := dxgi.PRESENT_PARAMETERS{DirtyRectsCount = u32(n), pDirtyRects = n > 0 ? &rects[0] : nil}
	scroll_rect: dxgi.RECT
	scroll_off: win.POINT
	if d.have_scroll {
		s := d.scroll
		scroll_rect = {left = s.x0, top = s.y0, right = s.x1, bottom = s.y1}
		scroll_off = {x = d.scroll_dx, y = d.scroll_dy}
		params.pScrollRect = &scroll_rect
		params.pScrollOffset = &scroll_off
	}
	call := time.tick_now()
	ps := profile_present_begin(r)
	hr := r.swapchain->Present1(sync, flags, &params)
	profile_present_end(r, ps)
	now := time.tick_now()
	if win.FAILED(hr) { return hr }
	p.presents += 1
	id: u32
	if win.SUCCEEDED(r.swapchain->GetLastPresentCount(&id)) {
		p.last_id = id
		p.ring[id % PRESENT_RING] = Present_Slot{present = id, input = p.input, read = p.read, drawn = p.drawn, call = call, presented = now, continuous = p.continuous, interval = max(sync, 1), expected = p.expected > 0 ? p.expected : f64(max(sync, 1)), mode = .Vsync}
	}
	p.input, p.read = {}, {}
	present_collect(r)
	when RENDER_PROBE { present_probe(r, now) }
	// remember this frame's region for the buffer-age logic of the next partial frames
	damage_push_history(d)
	return hr
}

}   // when !USE_WGPU
