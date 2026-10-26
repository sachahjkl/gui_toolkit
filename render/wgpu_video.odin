package render

import "core:fmt"
import "core:sync"
import "vendor:wgpu"

// Video pictures on the WebGPU backend: the planes come from memory (I420 / NV12, and P010 / I420_10 when the device has
// 16-bit normalized textures) and go through the same shader as on Direct3D 11 (video.wgsl), drawn into the target with a
// submit of their own, before the frame that draws the target. Decoder textures (Video_Picture.gpu_texture) are refused:
// wgpu-native cannot import a Direct3D 11 texture, so there is no zero-copy path here.

@(private)
Wgpu_Video_Plane :: struct {
	tex:    wgpu.Texture,
	view:   wgpu.TextureView,
	w, h:   int,
	format: wgpu.TextureFormat,
}

@(private)
Wgpu_Video :: struct {
	module: wgpu.ShaderModule,
	bgl:    wgpu.BindGroupLayout,
	layout: wgpu.PipelineLayout,
	pipes:  [2]wgpu.RenderPipeline,   // into RGBA8Unorm (Srgb space), RGBA8UnormSrgb (Linear)
	params: wgpu.Buffer,
	planes: [3]Wgpu_Video_Plane,
	failed: bool,                     // the device refused the shader: no pictures until the device is recreated
}

wgpu_create_video_target :: proc(r: ^Renderer, w, h: int) -> Texture {
	return wgpu_create_texture_rgba(r, w, h, true)
}

@(private)
wgpu_video_init :: proc(r: ^Renderer) -> bool {
	g := &r.wg
	v := &g.video
	if v.params != nil { return true }
	if v.failed { return false }
	F :: wgpu.ShaderStageFlags{.Fragment}
	e := [?]wgpu.BindGroupLayoutEntry{
		bgl_buffer(0, F, .Uniform, false, size_of(Video_Constants)), bgl_texture(1, F), bgl_texture(2, F), bgl_texture(3, F), bgl_sampler(4, F),
	}
	v.module = wgpu_module(g, "video.wgsl", WGSL_VIDEO)
	v.bgl = wgpu.DeviceCreateBindGroupLayout(g.device, &{label = "video", entryCount = len(e), entries = raw_data(e[:])})
	if v.module != nil && v.bgl != nil {
		v.layout = wgpu.DeviceCreatePipelineLayout(g.device, &{label = "video", bindGroupLayoutCount = 1, bindGroupLayouts = &v.bgl})
	}
	if v.layout != nil {
		v.params = wgpu.DeviceCreateBuffer(g.device, &{label = "video constants", usage = {.Uniform, .CopyDst}, size = size_of(Video_Constants)})
	}
	if v.params == nil {
		fmt.eprintln("render: wgpu: the video shader was refused by the device")
		wgpu_video_release(g)
		v.failed = true
		return false
	}
	return true
}

@(private)
wgpu_video_pipeline :: proc(r: ^Renderer, format: wgpu.TextureFormat) -> wgpu.RenderPipeline {
	g := &r.wg
	v := &g.video
	i := format == .RGBA8UnormSrgb ? 1 : 0
	if v.pipes[i] != nil { return v.pipes[i] }
	target := wgpu.ColorTargetState{format = format, writeMask = wgpu.ColorWriteMaskFlags_All}
	fs := wgpu.FragmentState{module = v.module, entryPoint = "ps_video", targetCount = 1, targets = &target}
	sync.mutex_lock(&g_compile_lock)
	v.pipes[i] = wgpu.DeviceCreateRenderPipeline(g.device, &{
		label = "video", layout = v.layout,
		vertex = {module = v.module, entryPoint = "vs_video"},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = 0xFFFFFFFF},
		fragment = &fs,
	})
	sync.mutex_unlock(&g_compile_lock)
	return v.pipes[i]
}

@(private)
wgpu_video_release :: proc(g: ^Wgpu_State) {
	v := &g.video
	for &p in v.planes {
		if p.view != nil { wgpu.TextureViewRelease(p.view) }
		if p.tex != nil { wgpu.TextureRelease(p.tex) }
	}
	for p in v.pipes { if p != nil { wgpu.RenderPipelineRelease(p) } }
	if v.params != nil { wgpu.BufferRelease(v.params) }
	if v.layout != nil { wgpu.PipelineLayoutRelease(v.layout) }
	if v.bgl != nil { wgpu.BindGroupLayoutRelease(v.bgl) }
	if v.module != nil { wgpu.ShaderModuleRelease(v.module) }
	v^ = {}
}

@(private)
wgpu_video_format :: proc(format: Video_Format, plane: int) -> wgpu.TextureFormat {
	ten := format == .P010 || format == .I420_10
	interleaved := plane > 0 && (format == .NV12 || format == .P010)
	if ten { return interleaved ? .RG16Unorm : .R16Unorm }
	return interleaved ? .RG8Unorm : .R8Unorm
}

@(private)
wgpu_video_plane_upload :: proc(r: ^Renderer, i: int, w, h: int, format: wgpu.TextureFormat, bytes_per_texel: int, data: []u8, stride: int) -> bool {
	g := &r.wg
	pl := &g.video.planes[i]
	if stride < w * bytes_per_texel || len(data) < stride * (h - 1) + w * bytes_per_texel { return false }
	if pl.tex == nil || pl.w != w || pl.h != h || pl.format != format {
		if pl.view != nil { wgpu.TextureViewRelease(pl.view) }
		if pl.tex != nil { wgpu.TextureRelease(pl.tex) }
		pl^ = {}
		pl.tex = wgpu.DeviceCreateTexture(g.device, &{
			label = "video plane", usage = {.TextureBinding, .CopyDst}, dimension = ._2D,
			size = {u32(w), u32(h), 1}, format = format, mipLevelCount = 1, sampleCount = 1,
		})
		if pl.tex == nil { return false }
		pl.view = wgpu.TextureCreateView(pl.tex, nil)
		if pl.view == nil { wgpu.TextureRelease(pl.tex); pl.tex = nil; return false }
		pl.w, pl.h, pl.format = w, h, format
	}
	wgpu.QueueWriteTexture(g.queue,
		&{texture = pl.tex, mipLevel = 0, origin = {0, 0, 0}, aspect = .All},
		raw_data(data), uint(stride * (h - 1) + w * bytes_per_texel),
		&{offset = 0, bytesPerRow = u32(stride), rowsPerImage = u32(h)},
		&{u32(w), u32(h), 1})
	return true
}

wgpu_video_convert :: proc(r: ^Renderer, dst: Texture, p: Video_Picture) -> bool {
	g := &r.wg
	if r.lost || g.device == nil || int(dst) <= 0 || int(dst) >= len(r.textures) { return false }
	td := &r.textures[int(dst)]
	target := video_target_size(p)
	if td.kind != .RGBA || td.wtex == nil || !td.mips || td.w != target.x || td.h != target.y || p.crop_size.x <= 0 || p.crop_size.y <= 0 { return false }
	if p.gpu_texture != nil { return false }   // no import of Direct3D 11 textures (see the top of this file)
	ten := p.format == .P010 || p.format == .I420_10
	if ten && !g.can_norm16 { return false }
	if len(p.planes[0]) == 0 || !wgpu_video_init(r) { return false }
	v := &g.video

	w, h := p.size.x, p.size.y
	bpt := ten ? 2 : 1
	cw, ch := (w + 1) / 2, (h + 1) / 2
	flags: u32
	if !wgpu_video_plane_upload(r, 0, w, h, wgpu_video_format(p.format, 0), bpt, p.planes[0], p.strides[0]) { return false }
	views: [3]wgpu.TextureView
	if p.format == .NV12 || p.format == .P010 {
		if !wgpu_video_plane_upload(r, 1, cw, ch, wgpu_video_format(p.format, 1), bpt * 2, p.planes[1], p.strides[1]) { return false }
		views = {v.planes[0].view, v.planes[1].view, v.planes[1].view}
	} else {
		if !wgpu_video_plane_upload(r, 1, cw, ch, wgpu_video_format(p.format, 1), bpt, p.planes[1], p.strides[1]) { return false }
		if !wgpu_video_plane_upload(r, 2, cw, ch, wgpu_video_format(p.format, 2), bpt, p.planes[2], p.strides[2]) { return false }
		views = {v.planes[0].view, v.planes[1].view, v.planes[2].view}
		flags |= VIDEO_FLAG_THREE_PLANES
	}

	co := video_coefficients(p)
	if td.space == .Linear { flags |= VIDEO_FLAG_OUT_LINEAR }   // (the target is RGBA8UnormSrgb: written linear, stored sRGB)
	switch p.transfer {
	case .SDR:
	case .PQ: flags |= VIDEO_FLAG_PQ
	case .HLG: flags |= VIDEO_FLAG_HLG
	}
	rot := ((p.rotation % 360) + 360) % 360
	vc := Video_Constants{
		crop = {f32(p.crop_origin.x), f32(p.crop_origin.y), f32(p.crop_origin.x + p.crop_size.x), f32(p.crop_origin.y + p.crop_size.y)},
		dim = {f32(max(w, 1)), f32(max(h, 1))},
		rotation = u32(rot), flags = flags, offset = co.offset, scale = co.scale, m = co.m,
		hdr = {p.sdr_white_nits > 0 ? p.sdr_white_nits : 203, p.hdr_peak_nits > 0 ? p.hdr_peak_nits : 1000, 0, 0},
	}
	wgpu.QueueWriteBuffer(g.queue, v.params, 0, &vc, size_of(vc))

	pipe := wgpu_video_pipeline(r, td.wformat)
	if pipe == nil { return false }
	if td.wrtv == nil {
		td.wrtv = wgpu.TextureCreateView(td.wtex, &{format = td.wformat, dimension = ._2D, baseMipLevel = 0, mipLevelCount = 1, arrayLayerCount = 1, aspect = .All})
		if td.wrtv == nil { return false }
	}
	e := [5]wgpu.BindGroupEntry{
		{binding = 0, buffer = v.params, offset = 0, size = size_of(Video_Constants)},
		{binding = 1, textureView = views[0]},
		{binding = 2, textureView = views[1]},
		{binding = 3, textureView = views[2]},
		{binding = 4, sampler = g.s_img},   // bilinear, clamped: it upsamples the chroma
	}
	bg := wgpu.DeviceCreateBindGroup(g.device, &{label = "video", layout = v.bgl, entryCount = len(e), entries = raw_data(e[:])})
	if bg == nil { return false }
	defer wgpu.BindGroupRelease(bg)
	enc := wgpu.DeviceCreateCommandEncoder(g.device)
	att := wgpu.RenderPassColorAttachment{view = td.wrtv, depthSlice = wgpu.DEPTH_SLICE_UNDEFINED, loadOp = .Clear, storeOp = .Store}
	pass := wgpu.CommandEncoderBeginRenderPass(enc, &{label = "video", colorAttachmentCount = 1, colorAttachments = &att})
	wgpu.RenderPassEncoderSetPipeline(pass, pipe)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, bg)
	wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)
	cb := wgpu.CommandEncoderFinish(enc)
	wgpu.CommandEncoderRelease(enc)
	wgpu.QueueSubmit(g.queue, {cb})
	wgpu.CommandBufferRelease(cb)
	td.mips_dirty = td.mips   // the levels are drawn from level 0 before the next frame (wgpu_generate_mips)
	td.unfilled = false
	return true
}
