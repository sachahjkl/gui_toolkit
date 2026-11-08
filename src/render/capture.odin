package render

// Reading a frame back without the screen: `capture_request` marks the next frame, `frame_end` copies that frame's
// render target (or a part of it) into a staging texture just before it presents, and `capture_poll` maps the copy once
// the GPU is done with it. The frame is what the renderer drew, so it works with the window covered, minimized to the
// taskbar's size, moved off the screen, or hidden (Direct3D 11; on WebGPU a hidden window's surface may give no frame, and the
// capture says Failed), and does not depend on the monitor's scale. Nothing here costs
// anything until a capture is asked for (the copy is one GPU command in that one frame; the map never waits).

import "base:runtime"
import "core:sync"
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
	Failed,    // the device was lost, the rectangle is empty, or there was no frame to copy (WebGPU: a hidden window's surface gives none)
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
	// asynchronously by capture_poll. `wmap` tracks the async map (nil: not asked yet); `wformat` says how the buffer's
	// texels read back.
	wbuf:      wgpu.Buffer,
	wrow:      int,
	wformat:   wgpu.TextureFormat,
	wmap:      ^Capture_Map,
}

// What the map's callback writes. The heap's, not the state's: a Capture_State moves (surface_use), and a map cancelled still
// calls back when the buffer goes: it must not write on the next capture. `abandoned`: the callback frees it.
@(private)
Capture_Map :: struct {
	state:     Capture_Map_State,
	abandoned: bool,
}

@(private)
Capture_Map_State :: enum u8 { Asked, Mapped, Failed }

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
	case .RGBA16Float: bpp = TEXEL_BYTES_FP16
	}
	if src == nil || r.lost || x1 <= x0 || y1 <= y0 || bpp == 0 { c.failed = true; return }
	c.got = {x0, y0, x1 - x0, y1 - y0}
	gw, gh := c.got[2], c.got[3]
	row := align_up(gw * bpp, COPY_ROW_ALIGN_BYTES)
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
	submitted := wgpu_submit(r, cb)
	wgpu.CommandBufferRelease(cb)
	wgpu.CommandEncoderRelease(enc)
	if !submitted { c.failed = true; return }
	c.wformat, c.wrow = format, row
	c.pending = true
}

@(private)
capture_free_wgpu :: proc(c: ^Capture_State) {
	mapped := c.wmap != nil && c.wmap.state == .Mapped
	if c.wmap != nil {
		if c.wmap.state == .Asked { c.wmap.abandoned = true } else { free(c.wmap, runtime.heap_allocator()) }
		c.wmap = nil
	}
	if c.wbuf != nil {
		if mapped { wgpu.BufferUnmap(c.wbuf) }
		wgpu.BufferRelease(c.wbuf)
		c.wbuf = nil
	}
}

@(private)
capture_on_map :: proc "c" (status: wgpu.MapAsyncStatus, message: wgpu.StringView, u1, u2: rawptr) {
	context = runtime.default_context()
	m := (^Capture_Map)(u1)
	if m.abandoned { free(m, runtime.heap_allocator()); return }
	m.state = status == .Success ? .Mapped : .Failed
}

// Fault Capture_Map_Late: the map held back (the callback that comes after its capture was cancelled).
@(private, thread_local) capture_map_held: ^Capture_Map

fault_capture_map_answer :: proc() {
	if capture_map_held == nil { return }
	m := capture_map_held
	capture_map_held = nil
	capture_on_map(.Aborted, {}, m, nil)
}

// The picture of a capture: RGBA8, straight rows, sRGB values, alpha forced to 255 (a window is opaque; a translucent
// one keeps what the compositor would show over black). Pending until the GPU has finished the copy: this never waits.
// The pixels are the caller's (allocated with `allocator`); `size` is the rectangle the copy holds.
capture_poll :: proc(r: ^Renderer, allocator := context.allocator) -> (pixels: []u8, size: [2]int, status: Capture_Status) {
	raw: Capture_Raw
	raw, status = capture_poll_raw(r, allocator)
	if status != .Ready { return nil, {}, status }
	return capture_raw_finish(raw), raw.size, .Ready
}

// What the texels of a capture are until capture_raw_finish.
Capture_Raw_Format :: enum u8 { BGRA8, RGBA8, Half }

// A capture as it came off the GPU: its rows copied, tightly packed, and nothing else done.
Capture_Raw :: struct {
	pixels: []u8,
	size:   [2]int,
	format: Capture_Raw_Format,
}

// capture_poll in two halves, so that a frame's thread only pays for the copy of the rows: capture_poll_raw there,
// capture_raw_finish on any thread (it touches nothing of the renderer).
capture_poll_raw :: proc(r: ^Renderer, allocator := context.allocator) -> (raw: Capture_Raw, status: Capture_Status) {
	c := &r.capture
	if c.failed { c.failed = false; return {}, .Failed }
	if c.requested { return {}, .Pending }
	if !c.pending { return {}, .None }
	when USE_WGPU {
		if c.wbuf == nil { c.pending = false; return {}, .Failed }
		if c.wmap == nil {
			c.wmap = new(Capture_Map, runtime.heap_allocator())
			if fault_hit(.Capture_Map) {
				capture_on_map(.Error, {}, c.wmap, nil)
			} else if fault_hit(.Capture_Map_Late) {
				capture_map_held = c.wmap
			} else {
				wgpu.BufferMapAsync(c.wbuf, {.Read}, 0, uint(c.wrow * c.got[3]), {mode = .AllowProcessEvents, callback = capture_on_map, userdata1 = c.wmap})
			}
		}
		if c.wmap.state == .Asked { wgpu_poll(r, false, events = true) }
		switch c.wmap.state {
		case .Asked: return {}, .Pending
		case .Failed: c.pending = false; capture_free_wgpu(c); return {}, .Failed
		case .Mapped:
		}
		size := [2]int{c.got[2], c.got[3]}
		src := wgpu.BufferGetConstMappedRange(c.wbuf, 0, uint(c.wrow * size.y))
		if src == nil { c.pending = false; capture_free_wgpu(c); return {}, .Failed }
		// The frame target stores sRGB-encoded bytes whatever the blend space (surface_format is BGRA8Unorm: in the sRGB
		// space the shader writes sRGB values, in the linear space the sRGB view encodes them on store), so an 8-bit
		// format is copied straight as the Direct3D path does. Only the fp16 target (a translucent window in linear light)
		// holds scRGB halves to encode.
		format := Capture_Raw_Format.BGRA8
		#partial switch c.wformat {
		case .RGBA16Float: format = .Half
		case .RGBA8Unorm, .RGBA8UnormSrgb: format = .RGBA8
		}
		raw = capture_raw_rows(raw_data(src), c.wrow, size, format, allocator)
		c.pending = false
		capture_free_wgpu(c)
		return raw, .Ready
	} else {
		mapped: d3d11.MAPPED_SUBRESOURCE
		hr := r.ctx->Map(c.staging, 0, .READ, {.DO_NOT_WAIT}, &mapped)
		if hr == dxgi.ERROR_WAS_STILL_DRAWING { return {}, .Pending }
		if win.FAILED(hr) { c.pending = false; return {}, .Failed }
		defer { r.ctx->Unmap(c.staging, 0); c.pending = false }
		// (R16G16B16A16_FLOAT: a translucent window in linear light, scRGB halves)
		raw = capture_raw_rows(([^]u8)(mapped.pData), int(mapped.RowPitch), {c.got[2], c.got[3]}, c.format == .R16G16B16A16_FLOAT ? .Half : .BGRA8, allocator)
		return raw, .Ready
	}
}

@(private)
capture_raw_rows :: proc(src: [^]u8, pitch: int, size: [2]int, format: Capture_Raw_Format, allocator: runtime.Allocator) -> Capture_Raw {
	row := size.x * (format == .Half ? TEXEL_BYTES_FP16 : 4)
	pixels := make([]u8, row * size.y, allocator)
	for y in 0 ..< size.y { runtime.mem_copy_non_overlapping(raw_data(pixels[y * row:]), src[y * pitch:], row) }
	return {pixels, size, format}
}

// The rows of a capture into the picture capture_poll gives: in place, in the same memory (`raw.pixels` is freed as usual), which
// is returned as long as the picture is.
capture_raw_finish :: proc(raw: Capture_Raw) -> []u8 #no_bounds_check {
	n := raw.size.x * raw.size.y
	switch raw.format {
	case .BGRA8:
		// (a word at a time: on the little-endian word B G R A, A in the high byte)
		words := ([^]u32)(raw_data(raw.pixels))
		for i in 0 ..< n {
			v := words[i]
			words[i] = (v & 0x0000_FF00) | (v >> 16) & 0xFF | (v & 0xFF) << 16 | 0xFF00_0000
		}
	case .RGBA8:
		words := ([^]u32)(raw_data(raw.pixels))
		for i in 0 ..< n { words[i] |= 0xFF00_0000 }
	case .Half:
		table := srgb_table()
		// (the bytes written lie behind the halves still to read)
		halves := ([^]u16)(raw_data(raw.pixels))
		out := raw_data(raw.pixels)
		for i in 0 ..< n {
			out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = table[halves[i * 4]], table[halves[i * 4 + 1]], table[halves[i * 4 + 2]], 255
		}
	}
	return raw.pixels[:n * 4]
}

// The bit patterns of a half (f16).
@(private) HALF_BIT_PATTERNS :: 65536

@(private = "file") srgb_table_bytes: [HALF_BIT_PATTERNS]u8
@(private = "file") srgb_table_once: sync.Once

// A half's sRGB byte, by its bits: a window of millions of pixels through pow takes a good part of a second. Built the first time a
// capture of an fp16 target is finished, on the thread that finishes it.
@(private)
srgb_table :: proc() -> ^[HALF_BIT_PATTERNS]u8 {
	sync.once_do(&srgb_table_once, proc() {
		for i in 0 ..< HALF_BIT_PATTERNS { srgb_table_bytes[i] = srgb_byte(f32(transmute(f16)u16(i))) }
	})
	return &srgb_table_bytes
}

@(private)
srgb_byte :: proc(v: f32) -> u8 {
	return u8(clamp(linear_to_srgb(v) * 255 + 0.5, 0, 255))
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
