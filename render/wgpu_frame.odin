package render

import "base:runtime"
import "core:fmt"
import "core:time"
import "vendor:wgpu"

// WebGPU backend: frames. See wgpu_core.odin for the overview.

@(private)
align_up :: proc(n, a: int) -> int { return (n + a - 1) / a * a }

// The frame target for this frame: the next texture of the swap chain (blocks until the presentation engine has one, which
// is what bounds the frame latency). false: there is none now (window hidden, surface lost); skip the frame.
@(private)
wgpu_ensure_frame :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	if g.frame_acquired { return true }
	if g.surface == nil { return false }
	if !g.configured { wgpu_configure_surface(r) }
	for _ in 0 ..< 2 {
		t_acq := time.tick_now()
		st := wgpu_acquire(r)
		if wgpu_trace() { fmt.eprintfln("wgpu: acquire %v after %.2f ms", st.status, time.duration_milliseconds(time.tick_since(t_acq))) }
		#partial switch st.status {
		case .SuccessOptimal, .SuccessSuboptimal:
			g.frame_tex = st.texture
			g.frame_rtv = wgpu.TextureCreateView(g.frame_tex, &{
				format = g.view_format, dimension = ._2D, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All,
			})
			g.frame_acquired = g.frame_rtv != nil
			if st.status == .SuccessSuboptimal { g.configured = false }
			return g.frame_acquired
		case .Outdated, .Lost:
			if st.texture != nil { wgpu.TextureRelease(st.texture) }
			wgpu_configure_surface(r)
		case .Error:
			if st.texture != nil { wgpu.TextureRelease(st.texture) }
			r.lost = true
			return false
		case:
			if st.texture != nil { wgpu.TextureRelease(st.texture) }
			return false
		}
	}
	return false
}

@(private)
wgpu_frame_begin :: proc(r: ^Renderer, clear: [4]f32) {
	g := &r.wg
	if g.shared != nil && g.shared.lost { r.lost = true }
	if r.lost && !recover(r) { return }
	c := clear
	if r.space == .Srgb && c.a > 0 {
		for k in 0 ..< 3 { c[k] = linear_to_srgb(c[k] / c.a) * c.a }
	}
	g.clear = {f64(c.r), f64(c.g), f64(c.b), f64(c.a)}
	g.clear_pending = true
	if g.surface != nil && wgpu_pick_present_mode(r) != g.present_mode { wgpu_configure_surface(r) }
	t0 := time.tick_now()
	wgpu_ensure_frame(r)
	g.cpu.begin += time.duration_milliseconds(time.tick_since(t0))
}

@(private)
wgpu_wait_for_frame :: proc(r: ^Renderer, timeout_ms := 100) -> bool {
	return wgpu_wait_frame(r, timeout_ms)
}

// A pass over the whole frame target that only clears it (a frame that drew nothing).
@(private)
wgpu_clear_frame :: proc(r: ^Renderer) {
	g := &r.wg
	g.clear_pending = false
	if g.frame_rtv == nil { return }
	enc := wgpu.DeviceCreateCommandEncoder(g.device)
	att := wgpu.RenderPassColorAttachment{view = g.frame_rtv, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store, clearValue = g.clear}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &{colorAttachmentCount = 1, colorAttachments = &att})
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	cb := wgpu.CommandEncoderFinish(enc)
	wgpu.QueueSubmit(g.queue, {cb})
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(enc)
}

////////////////////////////////
// frame_submit

// Per-submit scratch state shared by the helpers below.
@(private)
Submit :: struct {
	r:      ^Renderer,
	f:      ^Frame_Data,
	enc:    wgpu.CommandEncoder,
	pass:   wgpu.RenderPassEncoder,
	bg0:    wgpu.BindGroup,
	groups: [dynamic]wgpu.BindGroup,   // texture bind groups of this submit, released after it
	views:  [dynamic]wgpu.TextureView, // temporary views (mip levels)
	timed:  bool,                      // GPU time is measured (wgpu_profile.odin)
	pass_kind: Gpu_Step,               // what the open pass is, for the profile
	replay_off: [dynamic]u32,          // arena offset of each replay's constants (index 0: immediate instances); ~0 = not yet written
}

@(private)
arena_write :: proc(g: ^Wgpu_State, data: rawptr, size: int) -> u32 {
	off := g.arena_used
	wgpu.QueueWriteBuffer(g.queue, g.arena, u64(off), data, uint(size))
	g.arena_used = off + align_up(size, ARENA_ALIGN)
	return u32(off)
}

@(private)
upload_table :: proc(g: ^Wgpu_State, t: ^Wgpu_Table, data: rawptr, n, stride: int) {
	if t.buf == nil || n > t.cap {
		if t.buf != nil { wgpu.BufferRelease(t.buf) }
		t.cap = max(n, t.cap * 2, 64)
		t.buf = wgpu.DeviceCreateBuffer(g.device, &{label = "table", usage = {.Storage, .CopyDst}, size = u64(t.cap * stride)})
	}
	if n > 0 { wgpu.QueueWriteBuffer(g.queue, t.buf, 0, data, uint(n * stride)) }
}

@(private)
heap_buffer :: proc(r: ^Renderer, k: Heap_Kind) -> wgpu.Buffer {
	// heaps no picture used yet are bound as a small placeholder: the shader declares them
	if r.heaps[k].wbuf == nil { wgpu_heap_grow(r, k, 1) }
	return r.heaps[k].wbuf
}

@(private)
tex_view :: proc(r: ^Renderer, t: Texture, dummy: wgpu.TextureView) -> wgpu.TextureView {
	if int(t) > 0 && int(t) < len(r.textures) && r.textures[int(t)].wview != nil { return r.textures[int(t)].wview }
	return dummy
}

@(private)
wgpu_generate_mips :: proc(r: ^Renderer, s: ^Submit) {
	for &td in r.textures {
		if !td.mips_dirty || td.wtex == nil { continue }
		td.mips_dirty = false
		wgpu_fill_mips(r, s, &td)
	}
}

// Draws level k of a texture from level k - 1, for every level.
@(private)
wgpu_fill_mips :: proc(r: ^Renderer, s: ^Submit, td: ^Texture_Data) {
	g := &r.wg
	pipe := wgpu_mip_pipeline(r, td.wformat)
	for lvl in 1 ..< td.mip_count {
		src := wgpu.TextureCreateView(td.wtex, &{format = td.wformat, dimension = ._2D, baseMipLevel = u32(lvl - 1), mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
		dst := wgpu.TextureCreateView(td.wtex, &{format = td.wformat, dimension = ._2D, baseMipLevel = u32(lvl), mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
		append(&s.views, src, dst)
		e := [2]wgpu.BindGroupEntry{{binding = 0, textureView = src}, {binding = 1, sampler = g.s_mip}}
		bg := wgpu.DeviceCreateBindGroup(g.device, &{layout = g.bgl_mip, entryCount = 2, entries = raw_data(e[:])})
		append(&s.groups, bg)
		att := wgpu.RenderPassColorAttachment{view = dst, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
		p := wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
		wgpu.RenderPassEncoderSetPipeline(p, pipe)
		wgpu.RenderPassEncoderSetBindGroup(p, 0, bg)
		wgpu.RenderPassEncoderDraw(p, 3, 1, 0, 0)
		wgpu.RenderPassEncoderEnd(p)
		wgpu.RenderPassEncoderRelease(p)
	}
}

@(private)
end_pass :: proc(s: ^Submit) {
	if s.pass == nil { return }
	wgpu.RenderPassEncoderEnd(s.pass)
	wgpu.RenderPassEncoderRelease(s.pass)
	s.pass = nil
	if s.timed { wprof_step(s.r, s.enc, s.pass_kind, 0, 0, 0, 0) }
}

@(private)
wgpu_frame_submit :: proc(r: ^Renderer, f: Frame_Data) {
	defer recycle_targets(r)
	g := &r.wg
	if g.shared.lost { r.lost = true }
	if r.lost || len(f.batches) == 0 || (len(f.insts) == 0 && len(f.ops) == 0 && len(f.replays) == 0) { return }
	if !wgpu_ensure_frame(r) { return }
	frame := f
	s := Submit{r = r, f = &frame}
	defer {
		delete(s.groups); delete(s.views); delete(s.replay_off)
	}
	t_enter := time.tick_now()
	s.enc = wgpu.DeviceCreateCommandEncoder(g.device)
	if GPU_TIMING || r.gpu_timing || r.prof.on { wprof_begin(r, s.enc); s.timed = g.pf.slot >= 0 }
	wgpu_generate_mips(r, &s)
	if s.timed { wprof_step(r, s.enc, .Upload, 0, 0, 0, len(f.insts) * size_of(Rect_Inst)) }

	upload_table(g, &g.xforms, raw_data(f.xforms), len(f.xforms), size_of(Xform_Data))
	upload_table(g, &g.clips, raw_data(f.clips), len(f.clips), size_of(Clip_Data))
	upload_table(g, &g.points, raw_data(f.points), len(f.points), size_of([2]f32))
	upload_table(g, &g.grads, raw_data(f.grads), len(f.grads), size_of([4]f32))
	if len(f.apps) > 0 { upload_table(g, &g.app_params, raw_data(f.app_params), len(f.app_params), size_of([4]f32)) }
	if g.inst.buf == nil || len(f.insts) > g.inst.cap {
		if g.inst.buf != nil { wgpu.BufferRelease(g.inst.buf) }
		g.inst.cap = max(len(f.insts), g.inst.cap * 2, 4096)
		g.inst.buf = wgpu.DeviceCreateBuffer(g.device, &{label = "instances", usage = {.Vertex, .CopyDst}, size = u64(g.inst.cap * size_of(Rect_Inst))})
	}
	if len(f.insts) > 0 { wgpu.QueueWriteBuffer(g.queue, g.inst.buf, 0, raw_data(f.insts), uint(len(f.insts) * size_of(Rect_Inst))) }

	t_uploaded := time.tick_now()
	// uniform arena: the constants of every target bound, replay and filter pass of this submit, at their own offsets
	passes := 0
	for op in f.ops { if op.kind == .Pass { passes += 1 } }
	need := (len(f.batches) + len(f.replays) + 4) * ARENA_ALIGN + passes * PASS_CONSTANTS_SIZE
	if g.arena == nil || need > g.arena_cap {
		if g.arena != nil { wgpu.BufferRelease(g.arena) }
		g.arena_cap = max(need, g.arena_cap * 2, 64 << 10)
		g.arena = wgpu.DeviceCreateBuffer(g.device, &{label = "constants", usage = {.Uniform, .CopyDst}, size = u64(g.arena_cap)})
	}
	g.arena_used = 0
	runtime.resize(&s.replay_off, len(f.replays) + 1)
	for &o in s.replay_off { o = ~u32(0) }

	slots_buf := heap_buffer(r, .Slots)
	rclips_buf := heap_buffer(r, .Clips)
	rpoints_buf := heap_buffer(r, .Points)
	rgrads_buf := heap_buffer(r, .Grads)
	e0 := [13]wgpu.BindGroupEntry{
		{binding = 0, buffer = g.arena, offset = 0, size = size_of(Globals)},
		{binding = 1, buffer = g.arena, offset = 0, size = size_of(Replay_Constants)},
		{binding = 2, buffer = g.xforms.buf, size = wgpu.WHOLE_SIZE},
		{binding = 3, buffer = g.clips.buf, size = wgpu.WHOLE_SIZE},
		{binding = 4, buffer = g.points.buf, size = wgpu.WHOLE_SIZE},
		{binding = 5, buffer = g.grads.buf, size = wgpu.WHOLE_SIZE},
		{binding = 6, buffer = slots_buf, size = wgpu.WHOLE_SIZE},
		{binding = 7, buffer = rclips_buf, size = wgpu.WHOLE_SIZE},
		{binding = 8, buffer = rpoints_buf, size = wgpu.WHOLE_SIZE},
		{binding = 9, buffer = rgrads_buf, size = wgpu.WHOLE_SIZE},
		{binding = 10, sampler = g.s_atlas},
		{binding = 11, sampler = g.s_img},
		{binding = 12, sampler = g.s_wrap},
	}
	s.bg0 = wgpu.DeviceCreateBindGroup(g.device, &{label = "tables", layout = g.bgl0, entryCount = len(e0), entries = raw_data(e0[:])})
	defer wgpu.BindGroupRelease(s.bg0)

	has_slug := frame_has_slug(f)
	cur := -1                       // the target of the open pass
	cur_ok := false
	cur_size: [2]int
	cur_origin: [2]f32
	cur_format: wgpu.TextureFormat
	g_off: u32                      // Globals of the current target
	rp_off: u32                     // Replay constants in use
	bound_replay := -1
	bound_pipe: wgpu.RenderPipeline
	bound_tex, bound_image, bound_backdrop: Texture = -1, -1, -1
	vb_retained := false
	vb_set := false

	for b in f.batches {
		if b.op > 0 {
			end_pass(&s)
			wgpu_run_op(r, &s, &f.ops[b.op - 1])
			cur = -1
			continue
		}
		if b.count == 0 { continue }
		if b.replay > len(f.replays) || (b.replay > 0 && r.heaps[.Insts].wbuf == nil) { continue }
		if b.target != cur {
			end_pass(&s)
			cur = b.target
			cur_ok, cur_size, cur_origin, cur_format, g_off = wgpu_begin_target(r, &s, &frame, cur)
			bound_pipe = nil
			bound_replay, bound_tex, bound_image, bound_backdrop = -1, -1, -1, -1
			vb_set = false
		}
		if !cur_ok { continue }
		rc := [4]u32{
			u32(clamp(b.clip.x - cur_origin.x, 0, f32(cur_size.x))), u32(clamp(b.clip.y - cur_origin.y, 0, f32(cur_size.y))),
			u32(clamp(b.clip.z - cur_origin.x, 0, f32(cur_size.x))), u32(clamp(b.clip.w - cur_origin.y, 0, f32(cur_size.y))),
		}
		if rc[2] <= rc[0] || rc[3] <= rc[1] { continue }
		if (b.replay > 0) != vb_retained || !vb_set {
			vb_retained, vb_set = b.replay > 0, true
			buf := vb_retained ? r.heaps[.Insts].wbuf : g.inst.buf
			wgpu.RenderPassEncoderSetVertexBuffer(s.pass, 0, buf, 0, wgpu.WHOLE_SIZE)
		}
		if b.replay != bound_replay {
			bound_replay = b.replay
			if s.replay_off[b.replay] == ~u32(0) {
				s.replay_off[b.replay] = wgpu_write_replay(g, b.replay > 0 ? &f.replays[b.replay - 1] : nil, b.replay > 0)
			}
			rp_off = s.replay_off[b.replay]
			offs := [2]u32{g_off, rp_off}
			wgpu.RenderPassEncoderSetBindGroup(s.pass, 0, s.bg0, offs[:])
		}
		replace := b.backdrop != 0
		if b.tex != bound_tex || b.image != bound_image || b.backdrop != bound_backdrop {
			e1 := [5]wgpu.BindGroupEntry{
				{binding = 0, textureView = tex_view(r, b.tex, g.dummy_r8_view)},
				{binding = 1, textureView = tex_view(r, b.image, g.dummy_rgba_view)},
				{binding = 2, textureView = tex_view(r, b.backdrop, g.dummy_rgba_view)},
				{binding = 3, textureView = tex_view(r, f.slug_curves, g.dummy_curves_view)},
				{binding = 4, textureView = tex_view(r, f.slug_bands, g.dummy_bands_view)},
			}
			bg := wgpu.DeviceCreateBindGroup(g.device, &{label = "textures", layout = g.bgl1, entryCount = 5, entries = raw_data(e1[:])})
			append(&s.groups, bg)
			wgpu.RenderPassEncoderSetBindGroup(s.pass, 1, bg)
			bound_tex, bound_image, bound_backdrop = b.tex, b.image, b.backdrop
		}
		wgpu.RenderPassEncoderSetScissorRect(s.pass, rc[0], rc[1], rc[2] - rc[0], rc[3] - rc[1])
		if b.app > 0 {
			wgpu_draw_app(r, &s, b, cur_format, &bound_pipe)
			continue
		}
		if !has_slug {
			pipe := wgpu_pipeline(r, cur_format, replace)
			if pipe != bound_pipe {
				bound_pipe = pipe
				wgpu.RenderPassEncoderSetPipeline(s.pass, pipe)
			}
			wgpu.RenderPassEncoderDraw(s.pass, 4, u32(b.count), 0, u32(b.first))
			continue
		}
		// a batch with Slug text is drawn in pieces, in order: the Slug instances (slug_runs) by their pipeline, the others by the main one
		runs := f.slug_runs
		base := 0
		if b.replay > 0 { rp := f.replays[b.replay - 1]; runs, base = rp.slug_runs, int(rp.insts) }
		pos, end := b.first, b.first + b.count
		lo, hi := 0, len(runs)
		for lo < hi {
			mid := (lo + hi) / 2
			if base + runs[mid][0] + runs[mid][1] <= pos { lo = mid + 1 } else { hi = mid }
		}
		draw := proc(r: ^Renderer, s: ^Submit, bound: ^wgpu.RenderPipeline, format: wgpu.TextureFormat, replace, slug_ok, slug: bool, first, count: int) {
			if count <= 0 || (slug && !slug_ok) { return }
			pipe := slug ? wgpu_slug_pipeline(r, format, replace) : wgpu_pipeline(r, format, replace)
			if pipe == nil { return }
			if pipe != bound^ { bound^ = pipe; wgpu.RenderPassEncoderSetPipeline(s.pass, pipe) }
			wgpu.RenderPassEncoderDraw(s.pass, 4, u32(count), 0, u32(first))
		}
		slug_ok := int(f.slug_curves) > 0 && int(f.slug_bands) > 0 && !r.slug.failed
		for i := lo; i < len(runs) && pos < end; i += 1 {
			rs := base + runs[i][0]
			re := rs + runs[i][1]
			if rs >= end { break }
			if rs > pos { draw(r, &s, &bound_pipe, cur_format, replace, slug_ok, false, pos, rs - pos); pos = rs }
			e := min(re, end)
			draw(r, &s, &bound_pipe, cur_format, replace, slug_ok, true, pos, e - pos)
			pos = e
		}
		draw(r, &s, &bound_pipe, cur_format, replace, slug_ok, false, pos, end - pos)
	}
	end_pass(&s)
	if s.timed { wprof_end(r, s.enc) }
	t_encoded := time.tick_now()
	cb := wgpu.CommandEncoderFinish(s.enc)
	wgpu.QueueSubmit(g.queue, {cb})
	t_submitted := time.tick_now()
	g.cpu.upload += time.duration_milliseconds(time.tick_diff(t_enter, t_uploaded))
	g.cpu.encode += time.duration_milliseconds(time.tick_diff(t_uploaded, t_encoded))
	g.cpu.submit += time.duration_milliseconds(time.tick_diff(t_encoded, t_submitted))
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(s.enc)
	if s.timed { wprof_submitted(r) }
	for bg in s.groups { wgpu.BindGroupRelease(bg) }
	for v in s.views { wgpu.TextureViewRelease(v) }
}

@(private)
wgpu_write_replay :: proc(g: ^Wgpu_State, rp: ^Replay, retained: bool) -> u32 {
	c := Replay_Constants{m0 = {1, 0, 0, 1}, m1 = {0, 0, 1, 0}, i0 = {1, 0, 0, 1}}
	if rp != nil {
		c.m0 = {rp.m[0], rp.m[1], rp.m[2], rp.m[3]}
		c.m1 = {rp.m[4], rp.m[5], rp.alpha, 0}
		c.i0 = {rp.inv[0], rp.inv[1], rp.inv[2], rp.inv[3]}
		c.i1 = {rp.inv[4], rp.inv[5], 0, 0}
		c.base = {rp.slots, rp.clips, rp.points, rp.grads}
		c.misc = {retained ? 1 : 0, rp.outer, 0, 0}
	}
	return arena_write(g, &c, size_of(c))
}

// Opens a render pass on `target` (0 = the frame, k = layers[k - 1]): viewport, the Globals of the target in the arena.
@(private)
wgpu_begin_target :: proc(r: ^Renderer, s: ^Submit, f: ^Frame_Data, target: int) -> (ok: bool, size: [2]int, origin: [2]f32, format: wgpu.TextureFormat, g_off: u32) {
	g := &r.wg
	view := g.frame_rtv
	size = r.size
	space := r.space
	format = g.view_format
	if target > 0 {
		if target > len(f.layers) { return }
		ly := f.layers[target - 1]
		if int(ly.tex) <= 0 || int(ly.tex) >= len(r.textures) || r.textures[int(ly.tex)].wrtv == nil { return }
		td := &r.textures[int(ly.tex)]
		view, size, origin, space, format = td.wrtv, ly.size, ly.origin, ly.space, td.wformat
	}
	sm := clamp(r.corner_smoothing, 0, 1)
	text_gamma: f32
	switch r.text.curve {
	case .None: text_gamma = 0
	case .Srgb: text_gamma = -1
	case .Power: text_gamma = max(r.text.gamma, 0.25)
	}
	gl := Globals{
		viewport_size = {f32(size.x), f32(size.y)}, corner_n = 2 + 0.6 * sm, corner_boost = 1 + 0.25 * sm,
		target_origin = origin, target_space = u32(space),
		text_gamma = text_gamma, text_contrast = r.text.contrast, text_exponent = max(r.text.coverage_exponent, 0.1),
	}
	g_off = arena_write(g, &gl, size_of(gl))
	att := wgpu.RenderPassColorAttachment{view = view, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Load, storeOp = .Store}
	if target == 0 && g.clear_pending {
		att.loadOp, att.clearValue = .Clear, g.clear
		g.clear_pending = false
	}
	s.pass = wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
	s.pass_kind = target == 0 ? .Draw_Frame : .Draw_Layer
	wgpu.RenderPassEncoderSetViewport(s.pass, 0, 0, f32(size.x), f32(size.y), 0, 1)
	return true, size, origin, format, g_off
}

// A non-draw step: clear a layer, copy what a target holds, run a filter pass. No pass is open when it is called.
@(private)
wgpu_run_op :: proc(r: ^Renderer, s: ^Submit, op: ^Op) {
	g := &r.wg
	f := s.f
	valid :: proc(r: ^Renderer, t: Texture) -> bool { return int(t) > 0 && int(t) < len(r.textures) && r.textures[int(t)].wtex != nil }
	switch op.kind {
	case .Clear:
		if !valid(r, op.dst) || r.textures[int(op.dst)].wrtv == nil { return }
		att := wgpu.RenderPassColorAttachment{view = r.textures[int(op.dst)].wrtv, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
		p := wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
		wgpu.RenderPassEncoderEnd(p)
		wgpu.RenderPassEncoderRelease(p)
		if s.timed { td := r.textures[int(op.dst)]; wprof_step(r, s.enc, .Clear, td.w, td.h, td.w * td.h, td.w * td.h * texture_bpp(r, op.dst)) }
	case .Copy:
		if !valid(r, op.dst) { return }
		src := g.frame_tex
		lim := r.size
		if op.source > 0 {
			if op.source > len(f.layers) || !valid(r, f.layers[op.source - 1].tex) { return }
			src = r.textures[int(f.layers[op.source - 1].tex)].wtex
			lim = f.layers[op.source - 1].size
		}
		if src == nil { return }
		d := r.textures[int(op.dst)]
		x0, y0 := clamp(op.box[0], 0, i32(lim.x)), clamp(op.box[1], 0, i32(lim.y))
		x1, y1 := clamp(op.box[2], x0, i32(lim.x)), clamp(op.box[3], y0, i32(lim.y))
		x1, y1 = min(x1, x0 + i32(d.w)), min(y1, y0 + i32(d.h))
		if x1 <= x0 || y1 <= y0 { return }
		wgpu.CommandEncoderCopyTextureToTexture(s.enc,
			&{texture = src, mipLevel = 0, origin = {u32(x0), u32(y0), 0}, aspect = .All},
			&{texture = d.wtex, mipLevel = 0, origin = {0, 0, 0}, aspect = .All},
			&{u32(x1 - x0), u32(y1 - y0), 1})
		if s.timed { px := int(x1 - x0) * int(y1 - y0); wprof_step(r, s.enc, .Copy, int(x1 - x0), int(y1 - y0), px, px * 2 * max(texture_bpp(r, op.dst), 4)) }
	case .Pass:
		wgpu_run_pass(r, s, &op.pass)
	case .Mips:
		if !valid(r, op.dst) || !r.textures[int(op.dst)].mips { return }
		wgpu_fill_mips(r, s, &r.textures[int(op.dst)])
	case .Read:   // (no readback on this backend: readback_new gives 0, readback_poll says Failed)
	}
}

// A filter pass writes its region and a ring of one transparent texel past its right and bottom edges, and reads its
// sources no further than that ring: the destination is not cleared (texels further away keep whatever an earlier user
// of the pooled texture left, and are never read).
@(private)
wgpu_run_pass :: proc(r: ^Renderer, s: ^Submit, p: ^Pass) {
	g := &r.wg
	t := int(p.dst.tex)
	if t <= 0 || t >= len(r.textures) || r.textures[t].wrtv == nil || p.dst.size.x <= 0 || p.dst.size.y <= 0 { return }
	dtd := &r.textures[t]
	w, h := min(p.dst.size.x + 1, dtd.w), min(p.dst.size.y + 1, dtd.h)

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
	off := arena_write(g, &pc, size_of(pc))

	e := [4]wgpu.BindGroupEntry{
		{binding = 0, buffer = g.arena, offset = 0, size = PASS_CONSTANTS_SIZE},
		{binding = 1, textureView = tex_view(r, p.src.tex, g.dummy_rgba_view)},
		{binding = 2, textureView = tex_view(r, p.src2.tex, g.dummy_rgba_view)},
		{binding = 3, sampler = g.s_fx},
	}
	bg := wgpu.DeviceCreateBindGroup(g.device, &{label = "filter", layout = g.bgl_fx, entryCount = 4, entries = raw_data(e[:])})
	append(&s.groups, bg)
	att := wgpu.RenderPassColorAttachment{view = dtd.wrtv, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Load, storeOp = .Store}
	pass := wgpu.CommandEncoderBeginRenderPass(s.enc, &{colorAttachmentCount = 1, colorAttachments = &att})
	wgpu.RenderPassEncoderSetViewport(pass, 0, 0, f32(w), f32(h), 0, 1)
	wgpu.RenderPassEncoderSetScissorRect(pass, 0, 0, u32(w), u32(h))
	wgpu.RenderPassEncoderSetPipeline(pass, wgpu_fx_pipeline(r, dtd.wformat))
	offs := [1]u32{off}
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, bg, offs[:])
	wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	if s.timed {
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
		wprof_step(r, s.enc, kind, w, h, px, bytes)
	}
}

////////////////////////////////
// Readback

@(private)
wgpu_read_pixels :: proc(r: ^Renderer, allocator := context.allocator) -> []u8 {
	g := &r.wg
	if g.surface != nil || g.frame_tex == nil { return nil }
	w, h := r.size.x, r.size.y
	row := align_up(w * 4, 256)
	buf := wgpu.DeviceCreateBuffer(g.device, &{label = "readback", usage = {.CopyDst, .MapRead}, size = u64(row * h)})
	if buf == nil { return nil }
	defer wgpu.BufferRelease(buf)
	enc := wgpu.DeviceCreateCommandEncoder(g.device)
	wgpu.CommandEncoderCopyTextureToBuffer(enc,
		&{texture = g.frame_tex, mipLevel = 0, aspect = .All},
		&{buffer = buf, layout = {offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(h)}},
		&{u32(w), u32(h), 1})
	cb := wgpu.CommandEncoderFinish(enc)
	wgpu.QueueSubmit(g.queue, {cb})
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(enc)
	done := false
	ok := false
	Map :: struct { done, ok: ^bool }
	m := Map{&done, &ok}
	cb_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
		m := (^Map)(u1)
		m.done^, m.ok^ = true, status == .Success
	}
	wgpu.BufferMapAsync(buf, {.Read}, 0, uint(row * h), {mode = .AllowSpontaneos, callback = cb_map, userdata1 = &m})
	for tries := 0; !done && tries < 10000; tries += 1 {
		wgpu.DevicePoll(g.device, true)
		if !done { wgpu.InstanceProcessEvents(g.instance) }
	}
	if !ok { return nil }
	src := wgpu.BufferGetConstMappedRange(buf, 0, uint(row * h))
	out := make([]u8, w * h * 4, allocator)
	for y in 0 ..< h {
		line := src[y * row:][:w * 4]
		for x in 0 ..< w {
			o := (y * w + x) * 4
			// the storage is B8G8R8A8 (or R16G16B16A16 float for a translucent linear target, not supported here)
			out[o], out[o + 1], out[o + 2], out[o + 3] = line[x * 4 + 2], line[x * 4 + 1], line[x * 4], line[x * 4 + 3]
		}
	}
	wgpu.BufferUnmap(buf)
	return out
}
