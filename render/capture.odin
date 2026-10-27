package render

// Reading a frame back without the screen: `capture_request` marks the next frame, `frame_end` copies that frame's
// render target (or a part of it) into a staging texture just before it presents, and `capture_poll` maps the copy once
// the GPU is done with it. The frame is what the renderer drew, so it works with the window covered, minimized to the
// taskbar's size, moved off the screen, or hidden, and does not depend on the monitor's scale. Nothing here costs
// anything until a capture is asked for (the copy is one GPU command in that one frame; the map never waits).

import "base:runtime"
import "core:math"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"
import "vendor:wgpu"

_ :: runtime   // (the WebGPU backend only)
_ :: win       // (the Direct3D 11 backend only)
_ :: d3d11
_ :: dxgi

Capture_Status :: enum u8 {
	None,      // nothing requested
	Pending,   // asked, or copied and not yet readable: poll again (after the next frame, or a few ms)
	Ready,     // `pixels` is the picture
	Failed,    // the backend cannot (wgpu), the device was lost, or the rectangle is empty
}

Capture_State :: struct {
	requested: bool,
	pending:   bool,                 // the copy was issued, the result not taken yet
	failed:    bool,
	rect:      [4]int,               // x, y, w, h of the frame (w or h 0: all of it), as asked
	got:       [4]int,               // what the copy holds (the rectangle clamped to the frame)
	staging:   ^d3d11.ITexture2D,
	staging_size: [2]int,
	format:    dxgi.FORMAT,
	// WebGPU: the frame target is copied into a mappable buffer (rows of `wrow` bytes, a multiple of 256), mapped
	// asynchronously by capture_poll. `wmap` tracks the async map; `wformat` says how the buffer's texels read back.
	wbuf:      wgpu.Buffer,
	wrow:      int,
	wformat:   wgpu.TextureFormat,
	wmap:      Capture_Map,
}

@(private)
Capture_Map :: enum u8 { None, Asked, Mapped, Failed }

// Asks for a copy of the next frame (`rect`: x, y, w, h in the frame's pixels; zeros: the whole frame). False: a capture
// is already waiting to be taken. Both backends read their frame back.
capture_request :: proc(r: ^Renderer, rect := [4]int{}) -> bool {
	if r.capture.requested || r.capture.pending { return false }
	when USE_WGPU {
		capture_free_wgpu(&r.capture)   // a buffer the last capture left (it was read, or cancelled)
		r.capture = {requested = true, rect = rect}
	} else {
		r.capture = {requested = true, rect = rect, staging = r.capture.staging, staging_size = r.capture.staging_size, format = r.capture.format}
	}
	return true
}

// Forgets a capture asked for (not yet copied, or copied and not yet read): the next capture_request is free to start.
capture_cancel :: proc(r: ^Renderer) {
	when USE_WGPU { capture_free_wgpu(&r.capture) }
	r.capture.requested, r.capture.pending, r.capture.failed = false, false, false
}

// A capture is waiting for a frame or for the GPU.
capture_pending :: proc(r: ^Renderer) -> bool { return r.capture.requested || r.capture.pending }

// Called by frame_end, before the present.
@(private)
capture_copy :: proc(r: ^Renderer) {
	c := &r.capture
	c.requested = false
	if r.frame_tex == nil || r.lost { c.failed = true; return }
	fw, fh := r.size.x, r.size.y
	x, y, w, h := c.rect[0], c.rect[1], c.rect[2], c.rect[3]
	if w <= 0 || h <= 0 { x, y, w, h = 0, 0, fw, fh }
	x0, y0 := clamp(x, 0, fw), clamp(y, 0, fh)
	x1, y1 := clamp(x + w, 0, fw), clamp(y + h, 0, fh)
	if x1 <= x0 || y1 <= y0 { c.failed = true; return }
	c.got = {x0, y0, x1 - x0, y1 - y0}
	desc: d3d11.TEXTURE2D_DESC
	r.frame_tex->GetDesc(&desc)
	size := [2]int{c.got[2], c.got[3]}
	if c.staging == nil || c.staging_size != size || c.format != desc.Format {
		if c.staging != nil { c.staging->Release(); c.staging = nil }
		r.device->CreateTexture2D(&{
			Width = u32(size.x), Height = u32(size.y), MipLevels = 1, ArraySize = 1, Format = desc.Format,
			SampleDesc = {Count = 1}, Usage = .STAGING, CPUAccessFlags = {.READ},
		}, nil, &c.staging)
		if c.staging == nil { c.failed = true; return }
		c.staging_size, c.format = size, desc.Format
	}
	box := d3d11.BOX{left = u32(x0), top = u32(y0), front = 0, right = u32(x1), bottom = u32(y1), back = 1}
	r.ctx->CopySubresourceRegion(c.staging, 0, 0, 0, 0, r.frame_tex, 0, &box)
	c.pending = true
}


// WebGPU: copy the frame target (or a part of it) into a mappable buffer. Called by frame_end, before the present
// consumes the surface texture; the copy is one more command on the queue after the frame's own. `src` is the frame
// texture (surface or offscreen), `format` its storage format, `space` what its texels hold.
@(private)
capture_copy_wgpu :: proc(r: ^Renderer, src: wgpu.Texture, format: wgpu.TextureFormat, _: Blend_Space) {
	c := &r.capture
	c.requested = false
	fw, fh := r.size.x, r.size.y
	x, y, w, h := c.rect[0], c.rect[1], c.rect[2], c.rect[3]
	if w <= 0 || h <= 0 { x, y, w, h = 0, 0, fw, fh }
	x0, y0 := clamp(x, 0, fw), clamp(y, 0, fh)
	x1, y1 := clamp(x + w, 0, fw), clamp(y + h, 0, fh)
	bpp := 0
	#partial switch format {
	case .RGBA8Unorm, .BGRA8Unorm, .RGBA8UnormSrgb, .BGRA8UnormSrgb: bpp = 4
	case .RGBA16Float: bpp = 8
	}
	if src == nil || r.lost || x1 <= x0 || y1 <= y0 || bpp == 0 { c.failed = true; return }
	c.got = {x0, y0, x1 - x0, y1 - y0}
	gw, gh := c.got[2], c.got[3]
	row := align_up(gw * bpp, 256)   // (bytesPerRow of a texture to buffer copy: a multiple of 256)
	g := &r.wg
	capture_free_wgpu(c)
	c.wbuf = wgpu.DeviceCreateBuffer(g.device, &{label = "capture readback", usage = {.CopyDst, .MapRead}, size = u64(row * gh)})
	if c.wbuf == nil { c.failed = true; return }
	enc := wgpu.DeviceCreateCommandEncoder(g.device)
	wgpu.CommandEncoderCopyTextureToBuffer(enc,
		&{texture = src, mipLevel = 0, origin = {u32(x0), u32(y0), 0}, aspect = .All},
		&{buffer = c.wbuf, layout = {offset = 0, bytesPerRow = u32(row), rowsPerImage = u32(gh)}},
		&{u32(gw), u32(gh), 1})
	cb := wgpu.CommandEncoderFinish(enc)
	wgpu.QueueSubmit(g.queue, {cb})
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(enc)
	c.wformat, c.wrow, c.wmap = format, row, .None
	c.pending = true
}

@(private)
capture_free_wgpu :: proc(c: ^Capture_State) {
	if c.wbuf != nil {
		if c.wmap == .Mapped { wgpu.BufferUnmap(c.wbuf) }
		wgpu.BufferRelease(c.wbuf)
		c.wbuf = nil
	}
	c.wmap = .None
}

// The picture of a capture: RGBA8, straight rows, sRGB values, alpha forced to 255 (a window is opaque; a translucent
// one keeps what the compositor would show over black). Pending until the GPU has finished the copy: this never waits.
// The pixels are the caller's (allocated with `allocator`); `size` is the rectangle the copy holds.
capture_poll :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, size: [2]int, status: Capture_Status) {
	c := &r.capture
	if c.failed { c.failed = false; return nil, {}, .Failed }
	if c.requested { return nil, {}, .Pending }
	if !c.pending { return nil, {}, .None }
	when USE_WGPU {
		g := &r.wg
		if c.wbuf == nil { c.pending = false; return nil, {}, .Failed }
		if c.wmap == .None {
			// the id (not the slot) travels to the callback is not needed here: one capture at a time, c lives in the renderer
			on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
				context = runtime.default_context()
				st := (^Capture_Map)(u1)
				if st != nil { st^ = status == .Success ? .Mapped : .Failed }
			}
			c.wmap = .Asked
			wgpu.BufferMapAsync(c.wbuf, {.Read}, 0, uint(c.wrow * c.got[3]), {mode = .AllowProcessEvents, callback = on_map, userdata1 = &c.wmap})
		}
		if c.wmap == .Asked {
			wgpu.DevicePoll(g.device, false)
			wgpu.InstanceProcessEvents(g.instance)
		}
		switch c.wmap {
		case .None, .Asked: return nil, {}, .Pending
		case .Failed: c.pending = false; capture_free_wgpu(c); return nil, {}, .Failed
		case .Mapped:
		}
		size = {c.got[2], c.got[3]}
		src := wgpu.BufferGetConstMappedRange(c.wbuf, 0, uint(c.wrow * size.y))
		if src == nil { c.pending = false; capture_free_wgpu(c); return nil, {}, .Failed }
		pixels = make([]u8, size.x * size.y * 4, allocator)
		// The frame target stores sRGB-encoded bytes whatever the blend space (surface_format is BGRA8Unorm: in the sRGB
		// space the shader writes sRGB values, in the linear space the sRGB view encodes them on store), so an 8-bit
		// format is copied straight as the Direct3D path does. Only the fp16 target (a translucent window in linear light)
		// holds scRGB halves to encode. Alpha is forced to 255: a window is opaque.
		for py in 0 ..< size.y {
			rowb := src[py * c.wrow:]
			out := pixels[py * size.x * 4:][:size.x * 4]
			#partial switch c.wformat {
			case .RGBA16Float:
				hp := ([^]u16)(raw_data(rowb))
				for px in 0 ..< size.x {
					for k in 0 ..< 3 { out[px * 4 + k] = srgb_byte(f32(transmute(f16)hp[px * 4 + k])) }
					out[px * 4 + 3] = 255
				}
			case .RGBA8Unorm, .RGBA8UnormSrgb:
				for px in 0 ..< size.x {
					out[px * 4], out[px * 4 + 1], out[px * 4 + 2], out[px * 4 + 3] = rowb[px * 4], rowb[px * 4 + 1], rowb[px * 4 + 2], 255
				}
			case:   // BGRA8Unorm / BGRA8UnormSrgb (the usual surface format)
				for px in 0 ..< size.x {
					out[px * 4], out[px * 4 + 1], out[px * 4 + 2], out[px * 4 + 3] = rowb[px * 4 + 2], rowb[px * 4 + 1], rowb[px * 4], 255
				}
			}
		}
		c.pending = false
		capture_free_wgpu(c)
		return pixels, size, .Ready
	} else {
	mapped: d3d11.MAPPED_SUBRESOURCE
	hr := r.ctx->Map(c.staging, 0, .READ, {.DO_NOT_WAIT}, &mapped)
	if hr == dxgi.ERROR_WAS_STILL_DRAWING { return nil, {}, .Pending }
	if win.FAILED(hr) { c.pending = false; return nil, {}, .Failed }
	defer { r.ctx->Unmap(c.staging, 0); c.pending = false }
	size = {c.got[2], c.got[3]}
	pixels = make([]u8, size.x * size.y * 4, allocator)
	for y in 0 ..< size.y {
		row := ([^]u8)(uintptr(mapped.pData) + uintptr(y * int(mapped.RowPitch)))
		out := pixels[y * size.x * 4:][:size.x * 4]
		#partial switch c.format {
		case .R16G16B16A16_FLOAT:
			// a translucent window in linear light: scRGB halves, encoded for the picture
			src := ([^]u16)(row)
			for x in 0 ..< size.x {
				for k in 0 ..< 3 { out[x * 4 + k] = srgb_byte(f32(transmute(f16)src[x * 4 + k])) }
				out[x * 4 + 3] = 255
			}
		case:
			for x in 0 ..< size.x {
				out[x * 4], out[x * 4 + 1], out[x * 4 + 2], out[x * 4 + 3] = row[x * 4 + 2], row[x * 4 + 1], row[x * 4], 255
			}
		}
	}
	return pixels, size, .Ready
	}
}

@(private)
srgb_byte :: proc(v: f32) -> u8 {
	x := clamp(v, 0, 1)
	e := x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1.0 / 2.4) - 0.055
	return u8(clamp(e * 255 + 0.5, 0, 255))
}

// The device the copy was made on is gone: the staging texture or buffer goes with it (it must not be used on the next
// device), and a copy that was waiting to be read is lost (capture_poll says Failed). A request not yet served stays.
@(private)
capture_release_device_objects :: proc(c: ^Capture_State) {
	when USE_WGPU {
		capture_free_wgpu(c)
	} else {
		if c.staging != nil { c.staging->Release(); c.staging = nil }
		c.staging_size, c.format = {}, .UNKNOWN
	}
	if c.pending { c.pending = false; c.failed = true }
}

@(private)
capture_destroy :: proc(r: ^Renderer) {
	when USE_WGPU {
		capture_free_wgpu(&r.capture)
	} else {
		if r.capture.staging != nil { r.capture.staging->Release() }
	}
	r.capture = {}
}
