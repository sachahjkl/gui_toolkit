package render

import "core:fmt"
import "core:mem"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:wgpu"

// Retained data: the instances and tables of pictures (draw.Picture) live in five GPU heaps that persist from frame
// to frame. A picture owns a range of each; it is written once when recorded (or again when re-recorded), its
// transform slots are rewritten by range when they change, and replaying it only binds the range (Batch.replay).
// Ranges are allocated first-fit from a free list (coalesced on free); a heap that is full grows by doubling, its
// contents copied on the GPU (offsets stay valid). Policies (budget, eviction) belong to the caller: see draw.

Heap_Kind :: enum u8 {
	Insts,    // Rect_Inst (vertex buffer)
	Slots,    // Slot_Data (t7)
	Clips,    // Clip_Data (t8)
	Points,   // [2]f32 (t9)
	Grads,    // [4]f32 (t10)
}

HEAP_STRIDE := [Heap_Kind]int{.Insts = size_of(Rect_Inst), .Slots = size_of(Slot_Data), .Clips = size_of(Clip_Data), .Points = 8, .Grads = 16}

// A transform slot of a picture: its matrix from its own space to the picture's space, and the inverse.
Slot_Data :: struct {
	m:   [6]f32,
	_:   [2]f32,
	inv: [6]f32,
	_:   [2]f32,
}
#assert(size_of(Slot_Data) == 64)

Heap :: struct {
	wbuf: wgpu.Buffer,                   // TOOLKIT_RENDER=wgpu: the buffer (vertex or storage)
	buf:  ^d3d11.IBuffer,
	view: ^d3d11.IShaderResourceView,   // structured heaps
	cap:  int,                           // elements
	used: int,                           // elements allocated
	free: [dynamic][2]int,               // [offset, count], sorted by offset, never adjacent
}

// Smallest heap created (elements); heaps grow by doubling from it.
@(private) HEAP_MIN :: 1024

// The constant buffer b2 of rect.wgsl.
@(private)
Replay_Constants :: struct #packed {
	m0:   [4]f32,    // a b c d
	m1:   [4]f32,    // e f alpha 0
	i0:   [4]f32,
	i1:   [4]f32,
	base: [4]u32,    // slots, clips, points, grads
	misc: [4]u32,    // retained, outer clip, 0, 0
}
#assert(size_of(Replay_Constants) == 96)

// Allocates `n` elements of heap `kind`; the offset (elements) of the range. Grows the heap when no free range fits.
heap_alloc :: proc(r: ^Renderer, kind: Heap_Kind, n: int) -> (offset: int, ok: bool) {
	if n <= 0 { return 0, true }
	h := &r.heaps[kind]
	for i in 0 ..< len(h.free) {
		f := h.free[i]
		if f[1] < n { continue }
		offset = f[0]
		if f[1] == n { ordered_remove(&h.free, i) } else { h.free[i] = {f[0] + n, f[1] - n} }
		h.used += n
		return offset, true
	}
	heap_grow(r, kind, n) or_return
	return heap_alloc(r, kind, n)
}

// Gives a range back.
heap_free :: proc(r: ^Renderer, kind: Heap_Kind, offset, n: int) {
	if n <= 0 { return }
	h := &r.heaps[kind]
	h.used -= n
	insert_free(h, offset, n)
}

@(private)
insert_free :: proc(h: ^Heap, offset, n: int) {
	i := 0
	for i < len(h.free) && h.free[i][0] < offset { i += 1 }
	inject_at(&h.free, i, [2]int{offset, n})
	// merge with the next, then with the previous
	if i + 1 < len(h.free) && h.free[i][0] + h.free[i][1] == h.free[i + 1][0] {
		h.free[i][1] += h.free[i + 1][1]
		ordered_remove(&h.free, i + 1)
	}
	if i > 0 && h.free[i - 1][0] + h.free[i - 1][1] == h.free[i][0] {
		h.free[i - 1][1] += h.free[i][1]
		ordered_remove(&h.free, i)
	}
}

// Writes `n` elements at `offset` (elements) of heap `kind`.
d3d_heap_write :: proc(r: ^Renderer, kind: Heap_Kind, offset: int, data: rawptr, n: int) {
	h := &r.heaps[kind]
	if n <= 0 || h.buf == nil || offset < 0 || offset + n > h.cap { return }
	stride := HEAP_STRIDE[kind]
	box := d3d11.BOX{left = u32(offset * stride), right = u32((offset + n) * stride), top = 0, bottom = 1, front = 0, back = 1}
	r.ctx->UpdateSubresource(h.buf, 0, &box, data, 0, 0)
}

@(private)
d3d_heap_grow :: proc(r: ^Renderer, kind: Heap_Kind, need: int) -> bool {
	h := &r.heaps[kind]
	stride := HEAP_STRIDE[kind]
	ncap := max(h.cap * 2, h.cap + need, HEAP_MIN)
	desc := d3d11.BUFFER_DESC{ByteWidth = u32(ncap * stride), Usage = .DEFAULT}
	if kind == .Insts {
		desc.BindFlags = {.VERTEX_BUFFER}
	} else {
		desc.BindFlags = {.SHADER_RESOURCE}
		desc.MiscFlags = {.BUFFER_ALLOW_RAW_VIEWS}
	}
	buf: ^d3d11.IBuffer
	if win.FAILED(r.device->CreateBuffer(&desc, nil, &buf)) || buf == nil {
		fmt.eprintln("render: cannot grow the retained heap", kind, "to", ncap * stride, "bytes")
		return false
	}
	view: ^d3d11.IShaderResourceView
	if kind != .Insts {
		view = raw_buffer_view(r, buf, ncap * stride)
		if view == nil { buf->Release(); return false }
	}
	if h.buf != nil {
		box := d3d11.BOX{left = 0, right = u32(h.cap * stride), top = 0, bottom = 1, front = 0, back = 1}
		r.ctx->CopySubresourceRegion(buf, 0, 0, 0, 0, h.buf, 0, &box)
		h.buf->Release()
	}
	if h.view != nil { h.view->Release() }
	old := h.cap
	h.buf, h.view, h.cap = buf, view, ncap
	insert_free(h, old, ncap - old)
	return true
}

// Bytes allocated in the heaps (what pictures hold), and their total capacity.
heap_bytes :: proc(r: ^Renderer) -> (used, capacity: int) {
	for h, k in r.heaps {
		used += h.used * HEAP_STRIDE[k]
		capacity += h.cap * HEAP_STRIDE[k]
	}
	return
}

// Empties the heaps and frees their GPU memory: every picture uploads its data again at its next replay
// (`heap_generation` changes).
heaps_reset :: proc(r: ^Renderer) {
	heaps_destroy(r)
	r.heap_generation += 1
}

@(private)
d3d_heaps_destroy :: proc(r: ^Renderer) {
	for &h in r.heaps {
		if h.view != nil { h.view->Release() }
		if h.buf != nil { h.buf->Release() }
		delete(h.free)
		h = {}
	}
}

////////////////////////////////
// Device loss

DXGI_ERROR_DEVICE_REMOVED :: win.HRESULT(-2005270523)   // 0x887A0005
DXGI_ERROR_DEVICE_HUNG :: win.HRESULT(-2005270522)      // 0x887A0006
DXGI_ERROR_DEVICE_RESET :: win.HRESULT(-2005270521)     // 0x887A0007
DXGI_ERROR_DRIVER_INTERNAL_ERROR :: win.HRESULT(-2005270496) // 0x887A0020

@(private)
is_device_loss :: proc(hr: win.HRESULT) -> bool {
	return hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_HUNG || hr == DXGI_ERROR_DEVICE_RESET || hr == DXGI_ERROR_DRIVER_INTERNAL_ERROR
}

// The device was lost (driver update, GPU reset, adapter removed): frame_begin recovers on its own; call it yourself
// to know when it is done.
device_lost :: proc(r: ^Renderer) -> bool { return r.lost }

// Recreates the device and everything on it after a loss. Texture handles stay valid (same size and format) but
// their contents are gone: `device_generation` changes, owners upload their images again (draw.begin_frame resets
// the glyph atlas). Pooled targets are dropped; the retained heaps are emptied (pictures upload again). Returns false
// when no device can be had yet (try again later; until then frames draw nothing).
d3d_recover :: proc(r: ^Renderer) -> bool {
	// the new device first: if there is none, the old (removed) one stays, its calls are harmless no-ops
	old_device, old_ctx := r.device, r.ctx
	r.device, r.ctx = nil, nil
	driver: d3d11.DRIVER_TYPE = r.warp ? .WARP : .HARDWARE
	if !create_device(r, driver) {
		r.device, r.ctx = old_device, old_ctx
		return false
	}
	new_device, new_ctx := r.device, r.ctx
	r.device, r.ctx = old_device, old_ctx
	release_device_objects(r)
	// (the views and buffers released above are only destroyed when the context runs its queue: until then the old swap chain
	// still owns the window, and a new one cannot be made for it)
	if r.ctx != nil { r.ctx->ClearState(); r.ctx->Flush(); r.ctx->Release() }
	if r.device != nil { r.device->Release() }
	r.device, r.ctx = new_device, new_ctx
	ok := r.hwnd == nil ? create_offscreen_target(r) : create_swapchain(r)
	ok = ok && init_pipeline(r)
	d3d_app_shaders_recreate(r)
	for i in 1 ..< len(r.textures) {
		td := &r.textures[i]
		#partial switch td.kind {
		case .R8, .RGBA, .Slug_Curves, .Slug_Bands, .Data:
			if !texture_objects(r, td) { fmt.eprintln("render: texture", i, "could not be recreated"); td.kind = .None }
		case:
			if td.kind != .None { td^ = {}; append(&r.free_textures, Texture(i)) }
		}
	}
	r.heap_generation += 1
	r.device_generation += 1
	r.swap_gen, r.swap_space = r.device_generation, r.space_epoch   // (the window held now; the others of surface_use are remade when taken)
	r.gpu_frame = 0
	r.lost = !ok
	return ok
}

// For tests: behaves as if the device had just been lost (the next frame_begin recovers).
simulate_device_loss :: proc(r: ^Renderer) { r.lost = true }

// Every object made on the device (not the device and context): what destroy releases, minus the CPU state.
@(private)
release_device_objects :: proc(r: ^Renderer) {
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	for &td in r.textures {
		if td.rtv != nil { td.rtv->Release() }
		if td.view != nil { td.view->Release() }
		if td.tex != nil { td.tex->Release() }
		td.rtv, td.view, td.tex = nil, nil, nil
	}
	clear(&r.targets)
	r.targets_gen += 1
	for &q in r.gpu_queries { for &x in q { rel(&x) } }
	profile_destroy(r)
	video_pipeline_destroy(r)
	d3d_app_objects_release(r)
	canvas_pipeline_release(r)
	rel(&r.xform_view); rel(&r.xform_buf); rel(&r.clip_view); rel(&r.clip_buf); rel(&r.inst_buf); rel(&r.globals)
	rel(&r.points_view); rel(&r.points_buf); rel(&r.blend_replace); rel(&r.fx_vs); rel(&r.fx_ps); rel(&r.fx_constants)
	rel(&r.sampler_border); rel(&r.frame_tex); rel(&r.grads_view); rel(&r.grads_buf); rel(&r.replay_cb)
	rel(&r.sampler); rel(&r.sampler_img); rel(&r.sampler_wrap); rel(&r.raster); rel(&r.blend)
	rel(&r.layout); rel(&r.ps); rel(&r.vs); rel(&r.rtv); rel(&r.offscreen)
	slug_destroy(r)
	rel(&r.dcomp_visual); rel(&r.dcomp_target); rel(&r.dcomp); rel(&r.swapchain)
	capture_release_device_objects(&r.capture)
	heaps_destroy(r)
	if r.latency_handle != nil { win.CloseHandle(r.latency_handle); r.latency_handle = nil }
	r.inst_cap, r.xform_cap, r.clip_cap, r.points_cap, r.grads_cap = 0, 0, 0, 0, 0
}

@(private)
write_replay :: proc(r: ^Renderer, rp: ^Replay, retained: bool) {
	c := Replay_Constants{m0 = {1, 0, 0, 1}, m1 = {0, 0, 1, 0}, i0 = {1, 0, 0, 1}}
	if rp != nil {
		c.m0 = {rp.m[0], rp.m[1], rp.m[2], rp.m[3]}
		c.m1 = {rp.m[4], rp.m[5], rp.alpha, 0}
		c.i0 = {rp.inv[0], rp.inv[1], rp.inv[2], rp.inv[3]}
		c.i1 = {rp.inv[4], rp.inv[5], 0, 0}
		c.base = {rp.slots, rp.clips, rp.points, rp.grads}
		c.misc = {retained ? 1 : 0, rp.outer, 0, 0}
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.FAILED(r.ctx->Map(r.replay_cb, 0, .WRITE_DISCARD, {}, &mapped)) { return }
	mem.copy(mapped.pData, &c, size_of(c))
	r.ctx->Unmap(r.replay_cb, 0)
}
