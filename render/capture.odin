package render

// Reading a frame back without the screen: `capture_request` marks the next frame, `frame_end` copies that frame's
// render target (or a part of it) into a staging texture just before it presents, and `capture_poll` maps the copy once
// the GPU is done with it. The frame is what the renderer drew, so it works with the window covered, minimized to the
// taskbar's size, moved off the screen, or hidden, and does not depend on the monitor's scale. Nothing here costs
// anything until a capture is asked for (the copy is one GPU command in that one frame; the map never waits).

import "core:math"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

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
}

// Asks for a copy of the next frame (`rect`: x, y, w, h in the frame's pixels; zeros: the whole frame). False: this
// backend cannot read its frame back (wgpu), or a capture is already waiting to be taken.
capture_request :: proc(r: ^Renderer, rect := [4]int{}) -> bool {
	when USE_WGPU {
		return false
	} else {
		if r.capture.requested || r.capture.pending { return false }
		r.capture = {requested = true, rect = rect, staging = r.capture.staging, staging_size = r.capture.staging_size, format = r.capture.format}
		return true
	}
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


// The picture of a capture: RGBA8, straight rows, sRGB values, alpha forced to 255 (a window is opaque; a translucent
// one keeps what the compositor would show over black). Pending until the GPU has finished the copy: this never waits.
// The pixels are the caller's (allocated with `allocator`); `size` is the rectangle the copy holds.
capture_poll :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, size: [2]int, status: Capture_Status) {
	c := &r.capture
	if c.failed { c.failed = false; return nil, {}, .Failed }
	if c.requested { return nil, {}, .Pending }
	if !c.pending { return nil, {}, .None }
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

@(private)
srgb_byte :: proc(v: f32) -> u8 {
	x := clamp(v, 0, 1)
	e := x <= 0.0031308 ? x * 12.92 : 1.055 * math.pow(x, 1.0 / 2.4) - 0.055
	return u8(clamp(e * 255 + 0.5, 0, 255))
}

// The device the copy was made on is gone: the staging texture goes with it (it must not be used on the next device), and a copy that
// was waiting to be read is lost (capture_poll says Failed). A request not yet served stays.
@(private)
capture_release_device_objects :: proc(c: ^Capture_State) {
	if c.staging != nil { c.staging->Release(); c.staging = nil }
	c.staging_size, c.format = {}, .UNKNOWN
	if c.pending { c.pending = false; c.failed = true }
}

@(private)
capture_destroy :: proc(r: ^Renderer) {
	if r.capture.staging != nil { r.capture.staging->Release() }
	r.capture = {}
}
