package render

// Reading back what was drawn into an offscreen target (draw.offscreen_begin / offscreen_end): the frame's steps copy
// the target into a staging texture (Direct3D 11) or a mappable buffer (WebGPU) where they record it (an Op_Kind.Read),
// and readback_poll maps the copy once the GPU is done with it. The picture is straight RGBA8 with sRGB values and its
// alpha: what was drawn over nothing (an element painted alone for a drag image, a capture of one element). Nothing
// waits: poll after the frame, again later while it says Pending. Both backends give the same picture.

import "base:runtime"
import "core:sync"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "vendor:wgpu"

Readback_Id :: distinct u32

_ :: win       // (the D3D11 backend only)
_ :: runtime   // (the WebGPU backend only)

@(private)
Readback_Slot :: struct {
	id:      u32,
	renderer: u64,        // renderer_id of the one it is on
	phase:   Readback_Phase,
	staging: ^d3d11.ITexture2D,
	size:    [2]int,
	space:   Blend_Space, // what the target's texels are: premultiplied linear light, or premultiplied sRGB values
	format:  dxgi.FORMAT,
	// WebGPU: the buffer the target is copied into (rows of wrow bytes), mapped by readback_poll
	wbuf:    wgpu.Buffer,
	wrow:    int,
	wformat: wgpu.TextureFormat,
}

@(private)
Readback_Phase :: enum u8 {
	Asked,     // the Op is recorded, not run yet
	Copied,    // the copy is issued
	Mapping,   // WebGPU: readback_poll asked for the map
	Mapped,    // WebGPU: the buffer can be read
	Failed,    // readback_poll says so, and forgets it
}

@(private) readback_slots: map[u32]^Readback_Slot   // by id (unique in the process: every renderer of it shares the table)
@(private) readback_next: u32
@(private) readback_lock: sync.Mutex                // the table: renderers may live on several threads

@(private)
readback_slot :: proc(id: u32) -> ^Readback_Slot {
	sync.mutex_guard(&readback_lock)
	return readback_slots[id]
}

// A new readback for the frame being built (draw.offscreen_end records its Op).
readback_new :: proc(r: ^Renderer) -> Readback_Id {
	sync.mutex_guard(&readback_lock)
	readback_next += 1
	// (the process's heap: the table is the process's, and outlives whoever writes in it first. A thread's allocator could be gone by the time the table empties)
	if readback_slots == nil { readback_slots = make(map[u32]^Readback_Slot, runtime.heap_allocator()) }
	s := new(Readback_Slot, runtime.heap_allocator())
	s.id, s.renderer = readback_next, r.id
	readback_slots[s.id] = s
	return Readback_Id(s.id)
}

// Run by the frame's steps (frame.odin run_op): `src` (a target's texture), the box x0 y0 x1 y1 of it, its space.
@(private)
readback_copy :: proc(r: ^Renderer, id: u32, src: ^d3d11.ITexture2D, box: [4]i32, space: Blend_Space) {
	when !USE_WGPU {
		s := readback_slot(id)
		if s == nil || s.phase != .Asked { return }   // (the frame's steps run again, for verify)
		w, h := int(box[2] - box[0]), int(box[3] - box[1])
		if src == nil || w <= 0 || h <= 0 || r.lost { s.phase = .Failed; return }
		desc: d3d11.TEXTURE2D_DESC
		src->GetDesc(&desc)
		if win.FAILED(r.device->CreateTexture2D(&{
			Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1, Format = desc.Format,
			SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
		}, nil, &s.staging)) || s.staging == nil { s.phase = .Failed; return }
		b := d3d11.BOX{left = u32(box[0]), top = u32(box[1]), front = 0, right = u32(box[2]), bottom = u32(box[3]), back = 1}
		r.ctx->CopySubresourceRegion(s.staging, 0, 0, 0, 0, src, 0, &b)
		s.phase, s.size, s.space, s.format = .Copied, {w, h}, space, desc.Format
	}
}

// The WebGPU step of a Read: the box of `src` (a target texture of `format`) into a buffer, in the frame's encoder.
@(private)
readback_copy_wgpu :: proc(r: ^Renderer, enc: wgpu.CommandEncoder, id: u32, src: wgpu.Texture, format: wgpu.TextureFormat, box: [4]i32, space: Blend_Space) {
	s := readback_slot(id)
	if s == nil || s.phase != .Asked { return }   // (the frame's steps run again, for verify)
	w, h := int(box[2] - box[0]), int(box[3] - box[1])
	bpp := 0
	#partial switch format {
	case .RGBA8Unorm, .BGRA8Unorm, .RGBA8UnormSrgb, .BGRA8UnormSrgb: bpp = 4
	case .RGBA16Float: bpp = TEXEL_BYTES_FP16
	}
	if src == nil || enc == nil || w <= 0 || h <= 0 || bpp == 0 || r.lost { s.phase = .Failed; return }
	row := align_up(w * bpp, COPY_ROW_ALIGN_BYTES)
	s.wbuf = wgpu.DeviceCreateBuffer(r.wg.device, &{label = "offscreen readback", usage = {.CopyDst, .MapRead}, size = u64(row * h)})
	if s.wbuf == nil { s.phase = .Failed; return }
	wgpu.CommandEncoderCopyTextureToBuffer(enc,
		&{texture = src, mipLevel = 0, origin = {u32(box[0]), u32(box[1]), 0}, aspect = .All},
		&{buffer = s.wbuf, layout = {offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(h)}},
		&{u32(w), u32(h), 1})
	s.phase, s.size, s.space, s.wformat, s.wrow = .Copied, {w, h}, space, format, row
}

// After frame_submit: a Read its frame did not run (no target to draw on, a failure halfway) never will.
@(private)
readback_frame_done :: proc(f: Frame_Data) {
	for &op in f.ops {
		if op.kind != .Read { continue }
		if s := readback_slot(u32(op.readback)); s != nil && s.phase == .Asked { s.phase = .Failed }
	}
}

// The picture of a readback: straight RGBA8, sRGB values, alpha kept. Pending until the frame ran and the GPU copied;
// Ready once (the readback is then forgotten); Failed when its frame did not run, the device was lost, or the id is unknown or another
// renderer's.
readback_poll :: proc(r: ^Renderer, id: Readback_Id, allocator := context.allocator) -> (pixels: []u8, size: [2]int, status: Capture_Status) {
	s := readback_slot(u32(id))
	if s == nil || s.renderer != r.id { return nil, {}, .Failed }
	if s.phase == .Failed { readback_release(r, id); return nil, {}, .Failed }
	if s.phase == .Asked { return nil, {}, .Pending }
	when USE_WGPU {
		if s.phase == .Copied {
			// (the copy was submitted with its frame; the id, not the slot, goes to the callback: a slot released before
			// the map finishes is then simply not found)
			on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
				context = runtime.default_context()
				if s := readback_slot(u32(uintptr(u1))); s != nil && s.phase == .Mapping { s.phase = status == .Success ? .Mapped : .Failed }
			}
			s.phase = .Mapping
			wgpu.BufferMapAsync(s.wbuf, {.Read}, 0, uint(s.wrow * s.size.y), {mode = .AllowProcessEvents, callback = on_map, userdata1 = rawptr(uintptr(s.id))})
		}
		if s.phase == .Mapping { wgpu_poll(r, false, events = true) }
		#partial switch s.phase {
		case .Mapping: return nil, {}, .Pending
		case .Failed: readback_release(r, id); return nil, {}, .Failed
		}
		size = s.size
		src := wgpu.BufferGetConstMappedRange(s.wbuf, 0, uint(s.wrow * size.y))
		if src == nil { readback_release(r, id); return nil, {}, .Failed }
		pixels = make([]u8, size.x * size.y * 4, allocator)
		layout := Texel_Layout.RGBA8
		#partial switch s.wformat {
		case .RGBA16Float: layout = .Half
		case .BGRA8Unorm, .BGRA8UnormSrgb: layout = .BGRA8
		}
		straight_srgb_rows(raw_data(pixels), raw_data(src), s.wrow, size, layout, s.space)
		readback_release(r, id)
		return pixels, size, .Ready
	} else {
		mapped: d3d11.MAPPED_SUBRESOURCE
		hr := r.ctx->Map(s.staging, 0, .READ, {.DO_NOT_WAIT}, &mapped)
		if hr == dxgi.ERROR_WAS_STILL_DRAWING { return nil, {}, .Pending }
		if win.FAILED(hr) { readback_release(r, id); return nil, {}, .Failed }
		size = s.size
		pixels = make([]u8, size.x * size.y * 4, allocator)
		layout := Texel_Layout.RGBA8
		#partial switch s.format {
		case .R16G16B16A16_FLOAT: layout = .Half
		case .B8G8R8A8_UNORM, .B8G8R8A8_UNORM_SRGB: layout = .BGRA8
		}
		straight_srgb_rows(raw_data(pixels), ([^]u8)(mapped.pData), int(mapped.RowPitch), size, layout, s.space)
		r.ctx->Unmap(s.staging, 0)
		readback_release(r, id)
		return pixels, size, .Ready
	}
}

// A premultiplied texel of a target (in `space`) as a straight sRGB byte quadruple. Pure.
straight_srgb :: proc(px: [4]f32, space: Blend_Space) -> (u8, u8, u8, u8) {
	a := clamp(px[3], 0, 1)
	if a <= 0 { return 0, 0, 0, 0 }
	byte_of :: proc(v: f32) -> u8 { return u8(clamp(v, 0, 1) * 255 + 0.5) }
	c: [3]f32
	for k in 0 ..< 3 {
		v := clamp(px[k] / a, 0, 1)
		if space == .Linear { v = linear_to_srgb(v) }
		c[k] = v
	}
	return byte_of(c[0]), byte_of(c[1]), byte_of(c[2]), byte_of(a)
}

// Forgets a readback (its picture is no longer wanted, or was taken).
readback_release :: proc(r: ^Renderer, id: Readback_Id) {
	sync.mutex_lock(&readback_lock)
	s := readback_slots[u32(id)]
	if s != nil {
		delete_key(&readback_slots, u32(id))
		if len(readback_slots) == 0 { delete(readback_slots); readback_slots = nil }
	}
	sync.mutex_unlock(&readback_lock)
	if s == nil { return }
	// (outside the lock: releasing a buffer may call its map callback, which takes it)
	readback_free_objects(s)
	free(s, runtime.heap_allocator())
}

@(private)
readback_free_objects :: proc(s: ^Readback_Slot) {
	when USE_WGPU {
		if s.wbuf != nil {
			if s.phase == .Mapped { wgpu.BufferUnmap(s.wbuf) }
			wgpu.BufferRelease(s.wbuf)
			s.wbuf = nil
		}
	} else {
		if s.staging != nil { s.staging->Release(); s.staging = nil }
	}
}

// The device of `r` is gone: its copies waiting to be read are lost (their poll says Failed).
@(private)
readback_device_lost :: proc(r: ^Renderer) {
	gone := make([dynamic]Readback_Slot, context.temp_allocator)
	sync.mutex_lock(&readback_lock)
	for _, s in readback_slots {
		if s.renderer != r.id { continue }
		append(&gone, s^)
		when USE_WGPU { s.wbuf = nil } else { s.staging = nil }
		s.phase = .Failed
	}
	sync.mutex_unlock(&readback_lock)
	for &s in gone { readback_free_objects(&s) }   // (outside the lock: see readback_release)
}

// `r` is destroyed: nobody can read what it had. Its slots go, and their poll says Failed (an unknown id).
@(private)
readback_renderer_gone :: proc(r: ^Renderer) {
	gone := make([dynamic]^Readback_Slot, context.temp_allocator)
	sync.mutex_lock(&readback_lock)
	for _, s in readback_slots { if s.renderer == r.id { append(&gone, s) } }
	for s in gone { delete_key(&readback_slots, s.id) }
	if readback_slots != nil && len(readback_slots) == 0 { delete(readback_slots); readback_slots = nil }
	sync.mutex_unlock(&readback_lock)
	for s in gone {   // (outside the lock: see readback_release)
		readback_free_objects(s)
		free(s, runtime.heap_allocator())
	}
}
