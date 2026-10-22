package render

import win "core:sys/windows"
import "vendor:directx/d3d11"
import "vendor:directx/dxgi"

// Video pictures on the GPU. A decoder (Media Foundation, VA-API, VideoToolbox...) hands over a picture as planes (NV12 /
// P010 in a texture of the renderer's own Direct3D 11 device, or I420 / NV12 planes in memory); `video_convert` turns it
// into an ordinary RGBA texture with one small draw (video.wgsl: matrix, range, chroma upsampling, crop, rotation, HDR to
// SDR), so everything that draws an image (clips, rounded corners, opacity, transforms, filters, planes) draws a video.
// A picture decoded on the GPU is never copied to the CPU. The target is made by `create_video_target` and converted
// into again for each new picture; its mip levels are made before the next frame that draws it.

Video_Format :: enum u8 {
	NV12,      // 8 bits: Y plane, then interleaved UV at half size
	P010,      // 10 bits in the high bits of 16-bit words, same layout
	I420,      // 8 bits: Y, U, V planes (the chroma ones at half size)
	I420_10,   // 10 bits in the low bits of 16-bit words, three planes
}

Video_Matrix :: enum u8 { BT709, BT601, BT2020 }
Video_Transfer :: enum u8 { SDR, PQ, HLG }

// A picture to convert. `size` is the size of the luma plane (the surface the decoder allocated); the visible picture is the
// `crop_size` rectangle at `crop_origin` of it.
Video_Picture :: struct {
	format:      Video_Format,
	size:        [2]int,
	crop_origin: [2]int,
	crop_size:   [2]int,
	rotation:    int,          // degrees clockwise: 0, 90, 180, 270
	coeffs:      Video_Matrix,
	full_range:  bool,
	transfer:    Video_Transfer,
	hdr_peak_nits: f32,        // PQ / HLG: the brightest the content gets (0: 1000)
	sdr_white_nits: f32,       // what white is on the display (0: 203)
	// in the renderer's device: an NV12 / P010 texture (an ID3D11Texture2D) and the slice of it
	gpu_texture: rawptr,
	gpu_index:   u32,
	// else in memory (rows of strides[i] bytes; 16-bit planes little-endian)
	planes:      [3][]u8,
	strides:     [3]int,
}

// The size of the texture a picture converts to (rotation swaps the sides).
video_target_size :: proc(p: Video_Picture) -> [2]int {
	if p.rotation == 90 || p.rotation == 270 { return {p.crop_size.y, p.crop_size.x} }
	return p.crop_size
}

// An RGBA texture to convert pictures into, of the visible size (video_target_size). 0: the device refused it.
create_video_target :: proc(r: ^Renderer, w, h: int) -> Texture {
	when USE_WGPU { return wgpu_create_video_target(r, w, h) } else { return d3d_create_video_target(r, w, h) }
}

// Converts `p` into `dst` (a video target of video_target_size(p)). false: the picture could not be used (it stays as it
// was).
video_convert :: proc(r: ^Renderer, dst: Texture, p: Video_Picture) -> bool {
	when USE_WGPU { return wgpu_video_convert(r, dst, p) } else { return d3d_video_convert(r, dst, p) }
}

// The YUV to RGB matrix, offsets and scales of a picture (shared by both backends).
Video_Coefficients :: struct {
	offset: [4]f32,
	scale:  [4]f32,   // xyz: range expansion; w: what the sampled values are multiplied by first (bit depth)
	m:      [3][4]f32,
}

video_coefficients :: proc(p: Video_Picture) -> Video_Coefficients {
	kr, kb: f32 = 0.2126, 0.0722
	switch p.coeffs {
	case .BT709:
	case .BT601: kr, kb = 0.299, 0.114
	case .BT2020: kr, kb = 0.2627, 0.0593
	}
	kg := 1 - kr - kb
	c: Video_Coefficients
	c.m[0] = {1, 0, 2 * (1 - kr), 0}
	c.m[1] = {1, -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 0}
	c.m[2] = {1, 2 * (1 - kb), 0, 0}
	ten := p.format == .P010 || p.format == .I420_10
	levels: f32 = ten ? 1023 : 255
	shift: f32 = ten ? 4 : 1   // 8-bit values lie on 16..235, 10-bit ones on 64..940
	// 16-bit texels: P010 keeps its 10 bits in the high bits (65472 = 1023 << 6 is its full scale), I420_10 in the low ones
	bits: f32 = 1
	switch p.format {
	case .P010: bits = 65535.0 / 65472.0
	case .I420_10: bits = 65535.0 / 1023.0
	case .NV12, .I420:
	}
	c.scale.w = bits
	if p.full_range {
		c.offset = {0, (128 * shift) / levels, (128 * shift) / levels, 0}
		c.scale.xyz = {1, 1, 1}
	} else {
		c.offset = {(16 * shift) / levels, (128 * shift) / levels, (128 * shift) / levels, 0}
		c.scale.xyz = {levels / (219 * shift), levels / (224 * shift), levels / (224 * shift)}
	}
	return c
}

////////////////////////////////
// Direct3D 11

@(private)
VIDEO_FLAG_THREE_PLANES :: 1
@(private)
VIDEO_FLAG_OUT_LINEAR :: 2
@(private)
VIDEO_FLAG_PQ :: 4
@(private)
VIDEO_FLAG_HLG :: 8

@(private)
Video_Constants :: struct #packed {
	crop:     [4]f32,
	dim:      [2]f32,
	rotation: u32,
	flags:    u32,
	offset:   [4]f32,
	scale:    [4]f32,
	m:        [3][4]f32,
	hdr:      [4]f32,
}
#assert(size_of(Video_Constants) == 128)

// Views of a decoder's texture slice, kept while the decoder keeps handing out the same textures.
@(private)
Video_View :: struct {
	tex:   ^d3d11.ITexture2D,   // (a reference is held: the address cannot be reused by another texture meanwhile)
	index: u32,
	y, uv: ^d3d11.IShaderResourceView,
	used:  u64,
}

// A plane texture for pictures in memory.
@(private)
Video_Plane :: struct {
	tex:  ^d3d11.ITexture2D,
	view: ^d3d11.IShaderResourceView,
	w, h: int,
	format: dxgi.FORMAT,
}

@(private)
Video_Pipeline :: struct {
	vs:       ^d3d11.IVertexShader,
	ps:       ^d3d11.IPixelShader,
	cb:       ^d3d11.IBuffer,
	views:    [dynamic]Video_View,
	clock:    u64,
	planes:   [3]Video_Plane,
	copy:     ^d3d11.ITexture2D,        // a decoder texture that cannot be sampled is copied here first
	copy_view: [2]^d3d11.IShaderResourceView,
	copy_desc: d3d11.TEXTURE2D_DESC,
	failed:   bool,
}

@(private) MAX_VIDEO_VIEWS :: 40

@(private)
video_pipeline_init :: proc(r: ^Renderer) -> bool {
	v := &r.video
	if v.vs != nil { return true }
	if v.failed { return false }
	vs_code, vs_blob, ok1 := shader_code(.Video_VS)
	defer shader_code_done(vs_blob)
	ps_code, ps_blob, ok2 := shader_code(.Video_PS)
	defer shader_code_done(ps_blob)
	if !ok1 || !ok2 { v.failed = true; return false }
	r.device->CreateVertexShader(raw_data(vs_code), uint(len(vs_code)), nil, &v.vs)
	r.device->CreatePixelShader(raw_data(ps_code), uint(len(ps_code)), nil, &v.ps)
	r.device->CreateBuffer(&{ByteWidth = size_of(Video_Constants), Usage = .DYNAMIC, BindFlags = {.CONSTANT_BUFFER}, CPUAccessFlags = {.WRITE}}, nil, &v.cb)
	if v.vs == nil || v.ps == nil || v.cb == nil { video_pipeline_destroy(r); v.failed = true; return false }
	return true
}

@(private)
video_views_clear :: proc(v: ^Video_Pipeline) {
	for &w in v.views {
		if w.y != nil { w.y->Release() }
		if w.uv != nil { w.uv->Release() }
		if w.tex != nil { w.tex->Release() }
	}
	clear(&v.views)
}

@(private)
video_pipeline_destroy :: proc(r: ^Renderer) {
	v := &r.video
	rel :: proc(p: ^$T) { if p^ != nil { p^->Release(); p^ = nil } }
	video_views_clear(v)
	delete(v.views)
	for &p in v.planes { rel(&p.view); rel(&p.tex) }
	rel(&v.copy); rel(&v.copy_view[0]); rel(&v.copy_view[1])
	rel(&v.vs); rel(&v.ps); rel(&v.cb)
	v^ = {}
}

d3d_create_video_target :: proc(r: ^Renderer, w, h: int) -> Texture {
	return d3d_create_texture_rgba(r, w, h, true)
}

// The render target view of a video target, made on first use with the format the blend space needs: the texture stores
// sRGB values (Srgb: UNORM, written as they are) or linear light through an sRGB view (Linear: written linear).
@(private)
video_target_rtv :: proc(r: ^Renderer, td: ^Texture_Data) -> bool {
	if td.rtv != nil { return true }
	if td.tex == nil || !td.mips { return false }   // (only a texture with mips was made a render target)
	format: dxgi.FORMAT = td.space == .Srgb ? .R8G8B8A8_UNORM : .R8G8B8A8_UNORM_SRGB
	return win.SUCCEEDED(r.device->CreateRenderTargetView(td.tex, &{Format = format, ViewDimension = .TEXTURE2D}, &td.rtv))
}

@(private)
video_srv_format :: proc(format: Video_Format, plane: int) -> dxgi.FORMAT {
	ten := format == .P010 || format == .I420_10
	if plane == 0 { return ten ? .R16_UNORM : .R8_UNORM }
	return ten ? .R16G16_UNORM : .R8G8_UNORM
}

// The two views (luma, chroma) of slice `index` of a decoder texture; from the cache when it was seen before.
@(private)
video_gpu_views :: proc(r: ^Renderer, p: Video_Picture) -> (y, uv: ^d3d11.IShaderResourceView, ok: bool) {
	v := &r.video
	tex := (^d3d11.ITexture2D)(p.gpu_texture)
	v.clock += 1
	for &w in v.views {
		if w.tex == tex && w.index == p.gpu_index { w.used = v.clock; return w.y, w.uv, true }
	}
	desc: d3d11.TEXTURE2D_DESC
	tex->GetDesc(&desc)
	make_view :: proc(r: ^Renderer, tex: ^d3d11.ITexture2D, desc: d3d11.TEXTURE2D_DESC, format: dxgi.FORMAT, index: u32) -> ^d3d11.IShaderResourceView {
		sv: d3d11.SHADER_RESOURCE_VIEW_DESC
		sv.Format = format
		if desc.ArraySize > 1 {
			sv.ViewDimension = .TEXTURE2DARRAY
			sv.Texture2DArray = {MostDetailedMip = 0, MipLevels = 1, FirstArraySlice = index, ArraySize = 1}
		} else {
			sv.ViewDimension = .TEXTURE2D
			sv.Texture2D = {MostDetailedMip = 0, MipLevels = 1}
		}
		out: ^d3d11.IShaderResourceView
		if win.FAILED(r.device->CreateShaderResourceView(tex, &sv, &out)) { return nil }
		return out
	}
	if .SHADER_RESOURCE in desc.BindFlags {
		y = make_view(r, tex, desc, video_srv_format(p.format, 0), p.gpu_index)
		uv = make_view(r, tex, desc, video_srv_format(p.format, 1), p.gpu_index)
	}
	if y == nil || uv == nil {
		// not bindable for sampling: a copy on the GPU into a texture that is (NV12 slices copy as a whole)
		if y != nil { y->Release() }
		if uv != nil { uv->Release() }
		return video_copy_views(r, tex, desc, p)
	}
	if len(v.views) >= MAX_VIDEO_VIEWS {
		oldest := 0
		for w, i in v.views { if w.used < v.views[oldest].used { oldest = i } }
		w := v.views[oldest]
		w.y->Release(); w.uv->Release(); w.tex->Release()
		unordered_remove(&v.views, oldest)
	}
	tex->AddRef()
	append(&v.views, Video_View{tex = tex, index = p.gpu_index, y = y, uv = uv, used = v.clock})
	return y, uv, true
}

@(private)
video_copy_views :: proc(r: ^Renderer, src: ^d3d11.ITexture2D, desc: d3d11.TEXTURE2D_DESC, p: Video_Picture) -> (y, uv: ^d3d11.IShaderResourceView, ok: bool) {
	v := &r.video
	want := d3d11.TEXTURE2D_DESC{Width = desc.Width, Height = desc.Height, MipLevels = 1, ArraySize = 1, Format = desc.Format, SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE}}
	if v.copy == nil || v.copy_desc != want {
		if v.copy != nil { v.copy->Release(); v.copy = nil }
		for &c in v.copy_view { if c != nil { c->Release(); c = nil } }
		if win.FAILED(r.device->CreateTexture2D(&want, nil, &v.copy)) { v.copy = nil; return nil, nil, false }
		sv := d3d11.SHADER_RESOURCE_VIEW_DESC{ViewDimension = .TEXTURE2D}
		sv.Texture2D = {MostDetailedMip = 0, MipLevels = 1}
		sv.Format = video_srv_format(p.format, 0)
		r.device->CreateShaderResourceView(v.copy, &sv, &v.copy_view[0])
		sv.Format = video_srv_format(p.format, 1)
		r.device->CreateShaderResourceView(v.copy, &sv, &v.copy_view[1])
		v.copy_desc = want
	}
	if v.copy_view[0] == nil || v.copy_view[1] == nil { return nil, nil, false }
	r.ctx->CopySubresourceRegion(v.copy, 0, 0, 0, 0, src, p.gpu_index, nil)
	return v.copy_view[0], v.copy_view[1], true
}

// Pictures in memory: the planes uploaded to small textures kept between pictures.
@(private)
video_plane_upload :: proc(r: ^Renderer, i: int, w, h: int, format: dxgi.FORMAT, bytes_per_texel: int, data: []u8, stride: int) -> bool {
	pl := &r.video.planes[i]
	if pl.tex == nil || pl.w != w || pl.h != h || pl.format != format {
		if pl.view != nil { pl.view->Release(); pl.view = nil }
		if pl.tex != nil { pl.tex->Release(); pl.tex = nil }
		desc := d3d11.TEXTURE2D_DESC{Width = u32(w), Height = u32(h), MipLevels = 1, ArraySize = 1, Format = format, SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE}}
		if win.FAILED(r.device->CreateTexture2D(&desc, nil, &pl.tex)) { pl.tex = nil; return false }
		if win.FAILED(r.device->CreateShaderResourceView(pl.tex, nil, &pl.view)) { pl.tex->Release(); pl.tex = nil; return false }
		pl.w, pl.h, pl.format = w, h, format
	}
	if len(data) < stride * (h - 1) + w * bytes_per_texel { return false }
	r.ctx->UpdateSubresource(pl.tex, 0, nil, raw_data(data), u32(stride), 0)
	return true
}

d3d_video_convert :: proc(r: ^Renderer, dst: Texture, p: Video_Picture) -> bool {
	if int(dst) <= 0 || int(dst) >= len(r.textures) { return false }
	td := &r.textures[int(dst)]
	target := video_target_size(p)
	if td.kind != .RGBA || td.w != target.x || td.h != target.y || p.crop_size.x <= 0 || p.crop_size.y <= 0 { return false }
	if !video_pipeline_init(r) || !video_target_rtv(r, td) { return false }
	v := &r.video
	views: [3]^d3d11.IShaderResourceView
	flags: u32
	if p.gpu_texture != nil {
		if p.format != .NV12 && p.format != .P010 { return false }
		y, uv, ok := video_gpu_views(r, p)
		if !ok { return false }
		views[0], views[1], views[2] = y, uv, uv
	} else {
		w, h := p.size.x, p.size.y
		ten := p.format == .P010 || p.format == .I420_10
		bpt := ten ? 2 : 1
		if len(p.planes[0]) == 0 { return false }
		if !video_plane_upload(r, 0, w, h, video_srv_format(p.format, 0), bpt, p.planes[0], p.strides[0]) { return false }
		cw, ch := (w + 1) / 2, (h + 1) / 2
		if p.format == .NV12 || p.format == .P010 {
			if !video_plane_upload(r, 1, cw, ch, video_srv_format(p.format, 1), bpt * 2, p.planes[1], p.strides[1]) { return false }
			views[0], views[1], views[2] = v.planes[0].view, v.planes[1].view, v.planes[1].view
		} else {
			if !video_plane_upload(r, 1, cw, ch, video_srv_format(p.format, 0), bpt, p.planes[1], p.strides[1]) { return false }
			if !video_plane_upload(r, 2, cw, ch, video_srv_format(p.format, 0), bpt, p.planes[2], p.strides[2]) { return false }
			views[0], views[1], views[2] = v.planes[0].view, v.planes[1].view, v.planes[2].view
			flags |= VIDEO_FLAG_THREE_PLANES
		}
	}
	co := video_coefficients(p)
	if td.space == .Linear { flags |= VIDEO_FLAG_OUT_LINEAR }
	switch p.transfer {
	case .SDR:
	case .PQ: flags |= VIDEO_FLAG_PQ
	case .HLG: flags |= VIDEO_FLAG_HLG
	}
	rot := ((p.rotation % 360) + 360) % 360
	vc := Video_Constants{
		crop = {f32(p.crop_origin.x), f32(p.crop_origin.y), f32(p.crop_origin.x + p.crop_size.x), f32(p.crop_origin.y + p.crop_size.y)},
		dim = {f32(max(p.size.x, 1)), f32(max(p.size.y, 1))},
		rotation = u32(rot), flags = flags, offset = co.offset, scale = co.scale, m = co.m,
		hdr = {p.sdr_white_nits > 0 ? p.sdr_white_nits : 203, p.hdr_peak_nits > 0 ? p.hdr_peak_nits : 1000, 0, 0},
	}
	mapped: d3d11.MAPPED_SUBRESOURCE
	if win.FAILED(r.ctx->Map(v.cb, 0, .WRITE_DISCARD, {}, &mapped)) { return false }
	(^Video_Constants)(mapped.pData)^ = vc
	r.ctx->Unmap(v.cb, 0)

	rtv := td.rtv
	r.ctx->OMSetRenderTargets(1, &rtv, nil)
	vp := d3d11.VIEWPORT{0, 0, f32(td.w), f32(td.h), 0, 1}
	r.ctx->RSSetViewports(1, &vp)
	rc := d3d11.RECT{0, 0, i32(td.w), i32(td.h)}
	r.ctx->RSSetScissorRects(1, &rc)
	r.ctx->OMSetBlendState(r.blend_replace, nil, ~u32(0))
	r.ctx->IASetInputLayout(nil)
	r.ctx->IASetPrimitiveTopology(.TRIANGLELIST)
	r.ctx->VSSetShader(v.vs, nil, 0)
	r.ctx->PSSetShader(v.ps, nil, 0)
	r.ctx->PSSetConstantBuffers(0, 1, &v.cb)
	r.ctx->PSSetSamplers(0, 1, &r.sampler)
	r.ctx->PSSetShaderResources(0, 3, &views[0])
	// (the instanced-quad shader reads the same slots: b0 is its own constant buffer, bound again by the next frame)
	r.ctx->Draw(3, 0)
	none: [3]^d3d11.IShaderResourceView
	r.ctx->PSSetShaderResources(0, 3, &none[0])
	r.ctx->OMSetRenderTargets(0, nil, nil)
	td.mips_dirty = td.mips
	return true
}

// Texture bytes the picture handling holds (statistics).
video_gpu_bytes :: proc(r: ^Renderer) -> int {
	n := 0
	for pl in r.video.planes { n += pl.w * pl.h * 2 }
	return n
}
