package render

// Reading back what was drawn into an offscreen target (draw.offscreen_begin / offscreen_end): the frame's steps copy
// the target into a staging texture (Direct3D 11) or a mappable buffer (WebGPU) where they record it (an Op_Kind.Read),
// and readback_poll maps the copy once the GPU is done with it. The picture is straight RGBA8 with sRGB values and its
// alpha: what was drawn over nothing (an element painted alone for a drag image, a capture of one element). Nothing
// waits: poll after the frame, again later while it says Pending. Both backends give the same picture.

import "base:runtime"
import "core:math"
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
	asked:   bool,        // the Op is recorded, not run yet
	copied:  bool,        // the copy is issued
	failed:  bool,
	staging: ^d3d11.ITexture2D,
	size:    [2]int,
	space:   Blend_Space, // what the target's texels are: premultiplied linear light, or premultiplied sRGB values
	format:  dxgi.FORMAT,
	// WebGPU: the buffer the target is copied into (rows of wrow bytes), mapped by readback_poll
	wbuf:    wgpu.Buffer,
	wrow:    int,
	wformat: wgpu.TextureFormat,
	wmap:    Readback_Map,
}

@(private)
Readback_Map :: enum u8 { None, Asked, Mapped, Failed }

@(private) readback_slots: map[u32]^Readback_Slot   // by id (unique in the process: every renderer of it shares the table)
@(private) readback_next: u32

// A new readback for the frame being built (draw.offscreen_end records its Op).
readback_new :: proc(r: ^Renderer) -> Readback_Id {
	readback_next += 1
	s := new(Readback_Slot)
	s.id, s.asked = readback_next, true
	readback_slots[s.id] = s
	return Readback_Id(s.id)
}

// Run by the frame's steps (frame.odin run_op): `src` (a target's texture), the box x0 y0 x1 y1 of it, its space.
@(private)
readback_copy :: proc(r: ^Renderer, id: u32, src: ^d3d11.ITexture2D, box: [4]i32, space: Blend_Space) {
	when !USE_WGPU {
		s := readback_slots[id]
		if s == nil { return }
		s.asked = false
		w, h := int(box[2] - box[0]), int(box[3] - box[1])
		if src == nil || w <= 0 || h <= 0 || r.lost { s.failed = true; return }
		desc: d3d11.TEXTURE2D_DESC
		src->GetDesc(&desc)
		if win.FAILED(r.device->CreateTexture2D(&{
			Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1, Format = desc.Format,
			SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
		}, nil, &s.staging)) || s.staging == nil { s.failed = true; return }
		b := d3d11.BOX{left = u32(box[0]), top = u32(box[1]), front = 0, right = u32(box[2]), bottom = u32(box[3]), back = 1}
		r.ctx->CopySubresourceRegion(s.staging, 0, 0, 0, 0, src, 0, &b)
		s.copied, s.size, s.space, s.format = true, {w, h}, space, desc.Format
	}
}

// The WebGPU step of a Read: the box of `src` (a target texture of `format`) into a buffer, in the frame's encoder.
@(private)
readback_copy_wgpu :: proc(r: ^Renderer, enc: wgpu.CommandEncoder, id: u32, src: wgpu.Texture, format: wgpu.TextureFormat, box: [4]i32, space: Blend_Space) {
	s := readback_slots[id]
	if s == nil { return }
	s.asked = false
	w, h := int(box[2] - box[0]), int(box[3] - box[1])
	bpp := 0
	#partial switch format {
	case .RGBA8Unorm, .BGRA8Unorm, .RGBA8UnormSrgb, .BGRA8UnormSrgb: bpp = 4
	case .RGBA16Float: bpp = 8
	}
	if src == nil || enc == nil || w <= 0 || h <= 0 || bpp == 0 || r.lost { s.failed = true; return }
	row := align_up(w * bpp, 256)   // (bytesPerRow of a texture to buffer copy: a multiple of 256)
	s.wbuf = wgpu.DeviceCreateBuffer(r.wg.device, &{label = "offscreen readback", usage = {.CopyDst, .MapRead}, size = u64(row * h)})
	if s.wbuf == nil { s.failed = true; return }
	wgpu.CommandEncoderCopyTextureToBuffer(enc,
		&{texture = src, mipLevel = 0, origin = {u32(box[0]), u32(box[1]), 0}, aspect = .All},
		&{buffer = s.wbuf, layout = {offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(h)}},
		&{u32(w), u32(h), 1})
	s.copied, s.size, s.space, s.wformat, s.wrow = true, {w, h}, space, format, row
}

// The picture of a readback: straight RGBA8, sRGB values, alpha kept. Pending until the frame ran and the GPU copied;
// Ready once (the readback is then forgotten); Failed when the device was lost or the id is unknown.
readback_poll :: proc(r: ^Renderer, id: Readback_Id, allocator := context.allocator) -> (pixels: []u8, size: [2]int, status: Capture_Status) {
	s := readback_slots[u32(id)]
	if s == nil { return nil, {}, .Failed }
	if s.failed { readback_release(r, id); return nil, {}, .Failed }
	if !s.copied { return nil, {}, .Pending }
	when USE_WGPU {
		g := &r.wg
		if s.wmap == .None {
			// (the copy was submitted with its frame; the id, not the slot, goes to the callback: a slot released before
			// the map finishes is then simply not found)
			on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
				context = runtime.default_context()
				if s := readback_slots[u32(uintptr(u1))]; s != nil { s.wmap = status == .Success ? .Mapped : .Failed }
			}
			s.wmap = .Asked
			wgpu.BufferMapAsync(s.wbuf, {.Read}, 0, uint(s.wrow * s.size.y), {mode = .AllowProcessEvents, callback = on_map, userdata1 = rawptr(uintptr(s.id))})
		}
		if s.wmap == .Asked {
			wgpu.DevicePoll(g.device, false)
			wgpu.InstanceProcessEvents(g.instance)
		}
		switch s.wmap {
		case .None, .Asked: return nil, {}, .Pending
		case .Failed: readback_release(r, id); return nil, {}, .Failed
		case .Mapped:
		}
		size = s.size
		src := wgpu.BufferGetConstMappedRange(s.wbuf, 0, uint(s.wrow * size.y))
		if src == nil { readback_release(r, id); return nil, {}, .Failed }
		pixels = make([]u8, size.x * size.y * 4, allocator)
		for y in 0 ..< size.y {
			row := src[y * s.wrow:]
			out := pixels[y * size.x * 4:][:size.x * 4]
			for x in 0 ..< size.x {
				px: [4]f32
				#partial switch s.wformat {
				case .RGBA16Float:
					h := ([^]u16)(raw_data(row))
					for k in 0 ..< 4 { px[k] = f32(transmute(f16)h[x * 4 + k]) }
				case .BGRA8Unorm, .BGRA8UnormSrgb:
					px = {f32(row[x * 4 + 2]) / 255, f32(row[x * 4 + 1]) / 255, f32(row[x * 4]) / 255, f32(row[x * 4 + 3]) / 255}
				case:
					px = {f32(row[x * 4]) / 255, f32(row[x * 4 + 1]) / 255, f32(row[x * 4 + 2]) / 255, f32(row[x * 4 + 3]) / 255}
				}
				out[x * 4], out[x * 4 + 1], out[x * 4 + 2], out[x * 4 + 3] = straight_srgb(px, s.space)
			}
		}
		readback_release(r, id)
		return pixels, size, .Ready
	} else {
		mapped: d3d11.MAPPED_SUBRESOURCE
		hr := r.ctx->Map(s.staging, 0, .READ, {.DO_NOT_WAIT}, &mapped)
		if hr == dxgi.ERROR_WAS_STILL_DRAWING { return nil, {}, .Pending }
		if win.FAILED(hr) { readback_release(r, id); return nil, {}, .Failed }
		size = s.size
		pixels = make([]u8, size.x * size.y * 4, allocator)
		for y in 0 ..< size.y {
			row := uintptr(mapped.pData) + uintptr(y * int(mapped.RowPitch))
			out := pixels[y * size.x * 4:][:size.x * 4]
			for x in 0 ..< size.x {
				px: [4]f32
				#partial switch s.format {
				case .R16G16B16A16_FLOAT:
					src := ([^]u16)(row)
					for k in 0 ..< 4 { px[k] = f32(transmute(f16)src[x * 4 + k]) }
				case .B8G8R8A8_UNORM, .B8G8R8A8_UNORM_SRGB:
					src := ([^]u8)(row)
					px = {f32(src[x * 4 + 2]) / 255, f32(src[x * 4 + 1]) / 255, f32(src[x * 4]) / 255, f32(src[x * 4 + 3]) / 255}
				case:
					src := ([^]u8)(row)
					px = {f32(src[x * 4]) / 255, f32(src[x * 4 + 1]) / 255, f32(src[x * 4 + 2]) / 255, f32(src[x * 4 + 3]) / 255}
				}
				out[x * 4], out[x * 4 + 1], out[x * 4 + 2], out[x * 4 + 3] = straight_srgb(px, s.space)
			}
		}
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
		if space == .Linear { v = v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1.0 / 2.4) - 0.055 }
		c[k] = v
	}
	return byte_of(c[0]), byte_of(c[1]), byte_of(c[2]), byte_of(a)
}

// Forgets a readback (its picture is no longer wanted, or was taken).
readback_release :: proc(r: ^Renderer, id: Readback_Id) {
	s := readback_slots[u32(id)]
	if s == nil { return }
	readback_free_objects(s)
	delete_key(&readback_slots, u32(id))
	free(s)
	if len(readback_slots) == 0 { delete(readback_slots); readback_slots = nil }
}

@(private)
readback_free_objects :: proc(s: ^Readback_Slot) {
	when USE_WGPU {
		if s.wbuf != nil {
			if s.wmap == .Mapped { wgpu.BufferUnmap(s.wbuf) }
			wgpu.BufferRelease(s.wbuf)
			s.wbuf = nil
		}
	} else {
		if s.staging != nil { s.staging->Release(); s.staging = nil }
	}
}

// The device is gone: copies waiting to be read are lost (their poll says Failed).
@(private)
readback_device_lost :: proc() {
	for _, s in readback_slots {
		readback_free_objects(s)
		if s.copied || s.asked { s.failed = true }
	}
}
