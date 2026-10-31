#+build windows
package render

@(require) import "vendor:directx/d3d11"
@(require) import "vendor:directx/dxgi"

when !USE_WGPU {

// Partial redraw on the Direct3D 11 backend. See damage.odin for the region.
//
// The swap chain is FLIP_DISCARD: its buffers do not keep what was drawn from one frame to the next, and it takes no dirty
// rectangles (that swap effect does not allow partial presentation). So, as on WebGPU (damage_wgpu.odin), a frame with a
// region composes into a target kept across frames: the first one whole, the next ones only inside their regions. The target
// is then copied whole to the back buffer and presented. The rasterization is partial (the win: fewer pixels shaded, fewer
// pictures replayed); the present is full. A frame without a region is drawn straight to the back buffer, as without partial
// redraw, and the next region starts over from a whole frame.

// What partial redraw holds on the device, for the window whose Damage_State it is.
@(private)
d3d_damage_release :: proc(d: ^Damage_State) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	rel(&d.target_rtv); rel(&d.target)
	rel(&d.clear_rtv); rel(&d.clear_tex)
	d.target_size, d.clear_size = {}, {}
	d.target_ready = false
}

// A texture the frame's pixels can be copied to and from, drawn into through the frame's view.
@(private)
d3d_damage_texture :: proc(r: ^Renderer, size: [2]int, tex: ^^d3d11.ITexture2D, rtv: ^^d3d11.IRenderTargetView) -> bool {
	format: dxgi.FORMAT = r.frame_format == .R16G16B16A16_FLOAT ? .R16G16B16A16_FLOAT : .B8G8R8A8_TYPELESS
	r.device->CreateTexture2D(&{
		Width = u32(size.x), Height = u32(size.y), MipLevels = 1, ArraySize = 1, Format = format,
		SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
	}, nil, tex)
	if tex^ == nil { return false }
	r.device->CreateRenderTargetView(tex^, &{Format = r.frame_view, ViewDimension = .TEXTURE2D}, rtv)
	if rtv^ == nil { tex^->Release(); tex^ = nil; return false }
	return true
}

// Makes or remakes the kept target for the current size. False: there is none (the frame is drawn whole, straight to the buffer).
@(private)
d3d_damage_ensure_target :: proc(r: ^Renderer) -> bool {
	d := &r.damage
	if d.target != nil && d.target_size == r.size { return true }
	if d.target_rtv != nil { d.target_rtv->Release(); d.target_rtv = nil }
	if d.target != nil { d.target->Release(); d.target = nil }
	d.target_ready = false
	if !d3d_damage_texture(r, r.size, &d.target, &d.target_rtv) { return false }
	d.target_size = r.size
	return true
}

// Clears every rectangle of the region to the frame's clear color: to the byte what ClearRenderTargetView does to a whole frame
// (D3D11 has no scissored clear): a texture of that color, copied.
@(private)
d3d_clear_region :: proc(r: ^Renderer) {
	d := &r.damage
	if d.count == 0 { return }
	need := d.clear_size
	for rc in d.rects[:d.count] { need = {max(need.x, int(rc.x1 - rc.x0)), max(need.y, int(rc.y1 - rc.y0))} }
	if d.clear_tex == nil || need != d.clear_size {
		if d.clear_rtv != nil { d.clear_rtv->Release(); d.clear_rtv = nil }
		if d.clear_tex != nil { d.clear_tex->Release(); d.clear_tex = nil }
		d.clear_size = {}
		if !d3d_damage_texture(r, need, &d.clear_tex, &d.clear_rtv) { return }
		d.clear_size = need
	}
	r.ctx->ClearRenderTargetView(d.clear_rtv, &d.clear)
	for rc in d.rects[:d.count] {
		box := d3d11.BOX{left = 0, top = 0, front = 0, right = u32(rc.x1 - rc.x0), bottom = u32(rc.y1 - rc.y0), back = 1}
		r.ctx->CopySubresourceRegion(r.frame_tex, 0, u32(rc.x0), u32(rc.y0), 0, d.clear_tex, 0, &box)
	}
}

// The target, composed: copied whole to what `frame_tex` is (the back buffer, or the offscreen image).
@(private)
d3d_damage_show :: proc(r: ^Renderer, frame_tex: ^d3d11.ITexture2D) {
	if frame_tex == nil { return }
	size := r.size
	if r.swapchain != nil { size = {min(size.x, r.buffer_size.x), min(size.y, r.buffer_size.y)} }
	box := d3d11.BOX{left = 0, top = 0, front = 0, right = u32(size.x), bottom = u32(size.y), back = 1}
	r.ctx->CopySubresourceRegion(frame_tex, 0, 0, 0, 0, r.damage.target, 0, &box)
}

// A frame nothing was submitted for: the clear frame_begin deferred, and what the next region starts from is behind.
@(private)
d3d_damage_finish_clear :: proc(r: ^Renderer) {
	d := &r.damage
	if !d.have_clear { return }
	d.have_clear = false
	d.target_ready = false
	if r.rtv != nil { r.ctx->ClearRenderTargetView(r.rtv, &d.clear) }
}

}   // when !USE_WGPU
