package render

import "vendor:wgpu"

// Partial redraw on the WebGPU backend. wgpu-native (the pinned version in this repository) exposes only
// SurfacePresent, not a present-with-damage entry point, and a surface texture does not keep its content from frame to
// frame (the same flip model as DXGI). So a partial frame cannot simply draw a few rectangles into the surface and
// present: the rest of the surface texture is undefined.
//
// Instead the renderer keeps a persistent target the size of the frame (damage_target). Every frame composes into it:
// a full frame clears it and draws everything; a partial frame loads it (LoadOp::Load, so the kept content survives)
// and draws only the damaged rectangles, scissored. The whole target is then copied to the current surface texture and
// presented in full. The rasterization is partial (the win: fewer pixels shaded, fewer pictures replayed); the present
// is full (the documented limit of this backend until wgpu-native gains present-with-damage).
//
// While the persistent target holds the last frame, a partial frame is exact: the pixels it does not touch are the ones the
// previous frame left, which is what a lossless partial frame must show. A frame without a region goes straight to the surface:
// the target is behind it then, and the next region composes a whole frame.

// Makes or resizes the persistent damage target for the current size and view format. Returns false when it could not
// be made (then the frame is drawn in full straight into the surface, as without partial redraw).
@(private)
wgpu_damage_ensure_target :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	if g.damage_target != nil && g.damage_size == r.size {
		return true
	}
	wgpu_damage_release_target(r)
	if r.size.x <= 0 || r.size.y <= 0 { return false }
	vf := [1]wgpu.TextureFormat{g.view_format}
	g.damage_target = wgpu.DeviceCreateTexture(g.device, &{
		label = "damage target", usage = {.RenderAttachment, .CopySrc, .CopyDst, .TextureBinding}, dimension = ._2D,
		size = {u32(r.size.x), u32(r.size.y), 1}, format = g.surface_format, mipLevelCount = 1, sampleCount = 1,
		viewFormatCount = g.view_format != g.surface_format ? 1 : 0, viewFormats = raw_data(vf[:]),
	})
	if g.damage_target == nil { return false }
	g.damage_view = wgpu.TextureCreateView(g.damage_target, &{format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
	g.damage_sample = wgpu.TextureCreateView(g.damage_target, &{format = g.surface_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
	g.damage_size = r.size
	g.damage_ready = false   // nothing composed into it yet: the first frame using it must be full
	return g.damage_view != nil && g.damage_sample != nil
}

@(private)
wgpu_damage_release_target :: proc(r: ^Renderer) {
	g := &r.wg
	if g.damage_sample != nil { wgpu.TextureViewRelease(g.damage_sample); g.damage_sample = nil }
	if g.damage_view != nil { wgpu.TextureViewRelease(g.damage_view); g.damage_view = nil }
	if g.damage_target != nil { wgpu.TextureRelease(g.damage_target); g.damage_target = nil }
	if g.damage_ref_view != nil { wgpu.TextureViewRelease(g.damage_ref_view); g.damage_ref_view = nil }
	if g.damage_ref != nil { wgpu.TextureRelease(g.damage_ref); g.damage_ref = nil }
	if g.damage_clear_view != nil { wgpu.TextureViewRelease(g.damage_clear_view); g.damage_clear_view = nil }
	if g.damage_clear != nil { wgpu.TextureRelease(g.damage_clear); g.damage_clear = nil }
	g.damage_clear_size = {}
	g.damage_size = {}
	g.damage_ready = false
}

// Whether this frame is drawn into the persistent target (a partial frame, or a full frame that makes it current for
// the partial frames to come). Sets up the target and, when nothing valid is kept yet, forces a full composite.
// Returns (use_target, partial): use_target true to render target 0 into damage_view, partial true to load and
// scissor (else clear and draw whole). Called at the top of wgpu_frame_submit after damage_resolve.
@(private)
wgpu_damage_setup :: proc(r: ^Renderer, region: bool) -> (use_target, do_partial: bool) {
	g := &r.wg
	// only when a region is in effect this frame (the app called damage_begin for this window and mode is On): a frame
	// with no region is drawn straight to the surface, exactly as without partial redraw. This also keeps a second
	// window that does not track damage off the persistent target entirely.
	use_target = region && wgpu_damage_ensure_target(r)
	if !use_target { g.damage_ready = false }   // what is drawn goes past it
	// a partial frame is only safe when the target already holds the last frame; otherwise compose a full one now
	do_partial = use_target && g.damage_ready
	r.damage.have_region = do_partial
	r.damage.skip_present = do_partial && r.damage.count == 0
	return
}

// Clears every rectangle of the region to the frame's clear color: to the byte what a pass's clear does to a whole frame (WebGPU
// has no scissored clear): a texture of that color, copied.
@(private)
wgpu_damage_clear_region :: proc(r: ^Renderer, s: ^Submit) {
	g := &r.wg
	d := &r.damage
	g.clear_pending = false
	if d.count == 0 { return }
	need := g.damage_clear_size
	for rc in d.rects[:d.count] { need = {max(need.x, int(rc.x1 - rc.x0)), max(need.y, int(rc.y1 - rc.y0))} }
	if g.damage_clear == nil || need != g.damage_clear_size {
		if g.damage_clear_view != nil { wgpu.TextureViewRelease(g.damage_clear_view); g.damage_clear_view = nil }
		if g.damage_clear != nil { wgpu.TextureRelease(g.damage_clear); g.damage_clear = nil }
		g.damage_clear_size = {}
		vf := [1]wgpu.TextureFormat{g.view_format}
		g.damage_clear = wgpu.DeviceCreateTexture(g.device, &{
			label = "damage clear", usage = {.RenderAttachment, .CopySrc}, dimension = ._2D,
			size = {u32(need.x), u32(need.y), 1}, format = g.surface_format, mipLevelCount = 1, sampleCount = 1,
			viewFormatCount = g.view_format != g.surface_format ? 1 : 0, viewFormats = raw_data(vf[:]),
		})
		if g.damage_clear == nil { return }
		g.damage_clear_view = wgpu.TextureCreateView(g.damage_clear, &{format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
		if g.damage_clear_view == nil { return }
		g.damage_clear_size = need
	}
	att := wgpu.RenderPassColorAttachment{view = g.damage_clear_view, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store, clearValue = g.clear}
	pass := wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	for rc in d.rects[:d.count] {
		wgpu.CommandEncoderCopyTextureToTexture(s.enc,
			&{texture = g.damage_clear, mipLevel = 0, origin = {0, 0, 0}, aspect = .All},
			&{texture = g.damage_target, mipLevel = 0, origin = {u32(rc.x0), u32(rc.y0), 0}, aspect = .All},
			&{u32(rc.x1 - rc.x0), u32(rc.y1 - rc.y0), 1})
	}
}

// render.damage.verify on WebGPU: makes (or resizes) the reference texture, a full composite is drawn into it and
// compared with the persistent target (which holds the partial result). Returns false when the reference is missing.
@(private)
wgpu_damage_verify_ensure :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	if g.damage_ref != nil { return g.damage_ref_view != nil }
	if r.size.x <= 0 || r.size.y <= 0 { return false }
	vf := [1]wgpu.TextureFormat{g.view_format}
	g.damage_ref = wgpu.DeviceCreateTexture(g.device, &{
		label = "damage verify", usage = {.RenderAttachment, .CopySrc}, dimension = ._2D,
		size = {u32(r.size.x), u32(r.size.y), 1}, format = g.surface_format, mipLevelCount = 1, sampleCount = 1,
		viewFormatCount = g.view_format != g.surface_format ? 1 : 0, viewFormats = raw_data(vf[:]),
	})
	if g.damage_ref == nil { return false }
	g.damage_ref_view = wgpu.TextureCreateView(g.damage_ref, &{format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
	return g.damage_ref_view != nil
}

// Reads a whole BGRA8 texture back to CPU memory, tightly packed. nil on failure. (The partial verify path only; the
// hot path never reads back.)
@(private)
wgpu_damage_readback :: proc(r: ^Renderer, tex: wgpu.Texture) -> []u8 {
	g := &r.wg
	w, h := r.size.x, r.size.y
	row := align_up(w * 4, COPY_ROW_ALIGN_BYTES)
	buf := wgpu.DeviceCreateBuffer(g.device, &{label = "verify readback", usage = {.CopyDst, .MapRead}, size = u64(row * h)})
	if buf == nil { return nil }
	defer wgpu.BufferRelease(buf)
	enc := wgpu.DeviceCreateCommandEncoder(g.device)
	wgpu.CommandEncoderCopyTextureToBuffer(enc,
		&{texture = tex, mipLevel = 0, aspect = .All},
		&{buffer = buf, layout = {offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(h)}},
		&{u32(w), u32(h), 1})
	cb := wgpu.CommandEncoderFinish(enc)
	wgpu.QueueSubmit(g.queue, {cb})
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(enc)
	done, ok := false, false
	M :: struct { done, ok: ^bool }
	m := M{&done, &ok}
	cb_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
		m := (^M)(u1); m.done^, m.ok^ = true, status == .Success
	}
	wgpu.BufferMapAsync(buf, {.Read}, 0, uint(row * h), {mode = .AllowSpontaneos, callback = cb_map, userdata1 = &m})
	for tries := 0; !done && tries < READBACK_WAIT_MAX_TRIES; tries += 1 {
		wgpu.DevicePoll(g.device, true)
		if !done { wgpu.InstanceProcessEvents(g.instance) }
	}
	if !ok { return nil }
	src := wgpu.BufferGetConstMappedRange(buf, 0, uint(row * h))
	out := make([]u8, w * h * 4)
	for y in 0 ..< h { copy(out[y * w * 4:], src[y * row:][:w * 4]) }
	wgpu.BufferUnmap(buf)
	return out
}

// Compares the persistent target (the partial result) against the reference (the full composite drawn by the verify
// pass) and reports the first differing pixel. Called after both have been composed and submitted.
@(private)
wgpu_damage_compare :: proc(r: ^Renderer) {
	g := &r.wg
	if g.damage_ref == nil || g.damage_target == nil { return }
	full := wgpu_damage_readback(r, g.damage_ref)
	got := wgpu_damage_readback(r, g.damage_target)
	defer { delete(full); delete(got) }
	if full == nil || got == nil { return }
	damage_compare(&r.damage, full, got, r.size)
}

// Copies the whole persistent target to the current surface texture, so SurfacePresent shows the full composite: by a draw, a
// surface usually takes no CopyDst. Both views are of the storage format: the bytes go across as they are. Called after the
// batch loop, before SurfacePresent.
@(private)
wgpu_damage_blit_to_surface :: proc(r: ^Renderer, s: ^Submit) {
	g := &r.wg
	if g.damage_sample == nil || g.frame_tex == nil { return }
	dst := wgpu.TextureCreateView(g.frame_tex, &{format = g.surface_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
	append(&s.views, dst)
	e := [2]wgpu.BindGroupEntry{{binding = 0, textureView = g.damage_sample}, {binding = 1, sampler = g.s_mip}}
	bg := wgpu.DeviceCreateBindGroup(g.device, &{layout = g.bgl_mip, entryCount = 2, entries = raw_data(e[:])})
	append(&s.groups, bg)
	att := wgpu.RenderPassColorAttachment{view = dst, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
	p := wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
	wgpu.RenderPassEncoderSetPipeline(p, wgpu_mip_pipeline(r, g.surface_format, true))
	wgpu.RenderPassEncoderSetBindGroup(p, 0, bg)
	wgpu.RenderPassEncoderDraw(p, FULLSCREEN_VERTICES, 1, 0, 0)
	wgpu.RenderPassEncoderEnd(p)
	wgpu.RenderPassEncoderRelease(p)
	g.damage_ready = true
}
