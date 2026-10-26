// Pixel tests of video pictures (render.video_convert): planes in memory and an NV12 texture of the device, matrices and
// ranges, crop, rotation, in both blend spaces, on the offscreen renderer (WARP).   odin test tests/video -vet
package video_test

import "core:testing"
import "vendor:directx/d3d11"
import win "core:sys/windows"
import "../../draw"
import "../../font"
import "../../render"

_ :: d3d11   // (only the Direct3D 11 build uses them: nv12_texture_of_the_device)
_ :: win

W, H :: 64, 32

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	size:  [2]int,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space, size: [2]int) -> bool {
	f.size = size
	if !render.init_offscreen(&f.r, size, warp = true, space = space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r) }

// The test picture: four quadrants, red / lime (top), blue / white (bottom).
QUAD := [4][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}}

@(private = "file")
rgb_to_yuv :: proc(c: [3]f32, kr, kb: f32, full: bool, bits: int) -> (y, u, v: f32) {
	kg := 1 - kr - kb
	yy := kr * c[0] + kg * c[1] + kb * c[2]
	cb := (c[2] - yy) / (2 * (1 - kb))
	cr := (c[0] - yy) / (2 * (1 - kr))
	shift := f32(bits == 10 ? 4 : 1)
	levels := f32(bits == 10 ? 1023 : 255)
	if full { return yy * levels, cb * levels + 128 * shift, cr * levels + 128 * shift }
	return (16 * shift + 219 * shift * yy), 128 * shift + 224 * shift * cb, 128 * shift + 224 * shift * cr
}

// Planes of the quadrant picture, w x h, 4:2:0 (NV12 or I420), 8 bits.
@(private = "file")
make_planes :: proc(w, h: int, kr, kb: f32, full: bool, nv12: bool, pad_rows := 0) -> (y, uv, u, v: []u8) {
	y = make([]u8, w * (h + pad_rows), context.temp_allocator)
	cw, ch := w / 2, (h + pad_rows) / 2
	if nv12 { uv = make([]u8, cw * 2 * ch, context.temp_allocator) } else { u = make([]u8, cw * ch, context.temp_allocator); v = make([]u8, cw * ch, context.temp_allocator) }
	quad :: proc(x, yy, w, h: int) -> int { return (yy >= h / 2 ? 2 : 0) + (x >= w / 2 ? 1 : 0) }
	for py in 0 ..< h + pad_rows {
		for px in 0 ..< w {
			c := py < h ? QUAD[quad(px, py, w, h)] : [3]f32{0, 1, 0}   // rows past the picture: green (cropped away)
			yy, _, _ := rgb_to_yuv(c, kr, kb, full, 8)
			y[py * w + px] = u8(clamp(yy + 0.5, 0, 255))
		}
	}
	for py in 0 ..< ch {
		for px in 0 ..< cw {
			c := py * 2 < h ? QUAD[quad(px * 2, py * 2, w, h)] : [3]f32{0, 1, 0}
			_, cu, cv := rgb_to_yuv(c, kr, kb, full, 8)
			if nv12 {
				uv[py * cw * 2 + px * 2] = u8(clamp(cu + 0.5, 0, 255))
				uv[py * cw * 2 + px * 2 + 1] = u8(clamp(cv + 0.5, 0, 255))
			} else {
				u[py * cw + px] = u8(clamp(cu + 0.5, 0, 255))
				v[py * cw + px] = u8(clamp(cv + 0.5, 0, 255))
			}
		}
	}
	return
}

@(private = "file")
convert_and_draw :: proc(f: ^Fx, p: render.Video_Picture) -> []u8 {
	target := render.video_target_size(p)
	tex := render.create_video_target(&f.r, target.x, target.y)
	if tex == 0 { return nil }
	defer render.destroy_texture(&f.r, tex)
	if !render.video_convert(&f.r, tex, p) { return nil }
	draw.begin_frame(&f.dc, {f32(f.size.x), f32(f.size.y)})
	render.frame_begin(&f.r, {1, 0, 1, 1})
	draw.image(&f.dc, tex, {{0, 0}, {f32(target.x), f32(target.y)}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
px :: proc(f: ^Fx, img: []u8, x, y: int) -> [3]int {
	o := (y * f.size.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
}

@(private = "file")
near :: proc(a: [3]int, r, g, b: int, tol := 3) -> bool {
	return abs(a[0] - r) <= tol && abs(a[1] - g) <= tol && abs(a[2] - b) <= tol
}

@(private = "file")
expect_quad :: proc(t: ^testing.T, f: ^Fx, img: []u8, what: string, tol := 3) {
	if img == nil { testing.expectf(t, false, "%s: no picture", what); return }
	w, h := f.size.x, f.size.y
	// centers of the quadrants (away from the edges, where the chroma is filtered)
	testing.expectf(t, near(px(f, img, w / 4, h / 4), 255, 0, 0, tol), "%s: top left red: %v", what, px(f, img, w / 4, h / 4))
	testing.expectf(t, near(px(f, img, w * 3 / 4, h / 4), 0, 255, 0, tol), "%s: top right lime: %v", what, px(f, img, w * 3 / 4, h / 4))
	testing.expectf(t, near(px(f, img, w / 4, h * 3 / 4), 0, 0, 255, tol), "%s: bottom left blue: %v", what, px(f, img, w / 4, h * 3 / 4))
	testing.expectf(t, near(px(f, img, w * 3 / 4, h * 3 / 4), 255, 255, 255, tol), "%s: bottom right white: %v", what, px(f, img, w * 3 / 4, h * 3 / 4))
}

@(test)
planes_in_memory_both_spaces :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space, {W, H}) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		// I420 BT.709 limited range
		y, _, u, v := make_planes(W, H, 0.2126, 0.0722, false, false)
		p := render.Video_Picture{format = .I420, size = {W, H}, crop_size = {W, H}, coeffs = .BT709, planes = {y, u, v}, strides = {W, W / 2, W / 2}}
		expect_quad(t, &f, convert_and_draw(&f, p), "I420 709 limited")
		// NV12 BT.601 full range
		y2, uv2, _, _ := make_planes(W, H, 0.299, 0.114, true, true)
		p2 := render.Video_Picture{format = .NV12, size = {W, H}, crop_size = {W, H}, coeffs = .BT601, full_range = true, planes = {y2, uv2, nil}, strides = {W, W, 0}}
		expect_quad(t, &f, convert_and_draw(&f, p2), "NV12 601 full")
		// a matrix that does not match the stream gives other colors: the matrix is used
		p3 := p
		p3.coeffs = .BT601
		img := convert_and_draw(&f, p3)
		testing.expectf(t, img != nil && !near(px(&f, img, W / 4, H / 4), 255, 0, 0, 3), "%v: BT.601 over BT.709 data is visibly different", space)
	}
}

@(test)
crop_and_rotation :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb, {W, H}) { testing.fail_now(t, "no D3D11 device (WARP)") }
	// a surface with 16 extra rows (green), the picture cropped out of it
	y, uv, _, _ := make_planes(W, H, 0.2126, 0.0722, false, true, 16)
	p := render.Video_Picture{format = .NV12, size = {W, H + 16}, crop_size = {W, H}, coeffs = .BT709, planes = {y, uv, nil}, strides = {W, W, 0}}
	expect_quad(t, &f, convert_and_draw(&f, p), "cropped")
	close(&f)
	// rotated by 90 degrees clockwise: 32 x 64; the top left corner of the result is the bottom left of the picture (blue)
	if !open(&f, .Srgb, {H, W}) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	p.rotation = 90
	img := convert_and_draw(&f, p)
	if !testing.expect(t, img != nil, "rotated picture") { return }
	testing.expectf(t, near(px(&f, img, H / 4, W / 4), 0, 0, 255), "90: top left is blue: %v", px(&f, img, H / 4, W / 4))
	testing.expectf(t, near(px(&f, img, H * 3 / 4, W / 4), 255, 0, 0), "90: top right is red: %v", px(&f, img, H * 3 / 4, W / 4))
	testing.expectf(t, near(px(&f, img, H / 4, W * 3 / 4), 255, 255, 255), "90: bottom left is white: %v", px(&f, img, H / 4, W * 3 / 4))
}

// A decoder's NV12 texture of the renderer's Direct3D 11 device, sampled where it is. The WebGPU backend has no Direct3D 11
// device and wgpu-native cannot import such a texture: there, video_convert refuses a picture that names one (and leaves the
// target as it was), and the same planes handed over in memory still convert.
@(test)
nv12_texture_of_the_device :: proc(t: ^testing.T) {
	when render.USE_WGPU {
		f: Fx
		if !open(&f, .Srgb, {W, H}) { testing.fail_now(t, "no device (WARP)") }
		defer close(&f)
		y, uv, _, _ := make_planes(W, H, 0.2126, 0.0722, false, true)
		mem := render.Video_Picture{format = .NV12, size = {W, H}, crop_size = {W, H}, coeffs = .BT709, planes = {y, uv, nil}, strides = {W, W, 0}}
		tex := render.create_video_target(&f.r, W, H)
		if !testing.expect(t, tex != 0, "a video target") { return }
		defer render.destroy_texture(&f.r, tex)
		gpu := mem
		gpu.gpu_texture = rawptr(uintptr(1))   // never dereferenced: refused before
		testing.expect(t, !render.video_convert(&f.r, tex, gpu), "WebGPU: a decoder texture is refused")
		expect_quad(t, &f, convert_and_draw(&f, mem), "NV12 in memory (WebGPU)")
	} else {
		for space in render.Blend_Space {
			f: Fx
			if !open(&f, space, {W, H}) { testing.fail_now(t, "no D3D11 device (WARP)") }
			defer close(&f)
			y, uv, _, _ := make_planes(W, H, 0.2126, 0.0722, false, true)
			// one NV12 texture holding both planes (Y rows, then the UV rows)
			data := make([]u8, len(y) + len(uv), context.temp_allocator)
			copy(data, y)
			copy(data[len(y):], uv)
			desc := d3d11.TEXTURE2D_DESC{Width = W, Height = H, MipLevels = 1, ArraySize = 1, Format = .NV12, SampleDesc = {Count = 1}, Usage = .DEFAULT, BindFlags = {.SHADER_RESOURCE}}
			init := d3d11.SUBRESOURCE_DATA{pSysMem = raw_data(data), SysMemPitch = W}
			tex: ^d3d11.ITexture2D
			if win.FAILED(f.r.device->CreateTexture2D(&desc, &init, &tex)) || tex == nil {
				testing.expectf(t, false, "%v: this device has no NV12 textures (WARP)", space)
				continue
			}
			defer tex->Release()
			p := render.Video_Picture{format = .NV12, size = {W, H}, crop_size = {W, H}, coeffs = .BT709, gpu_texture = tex}
			expect_quad(t, &f, convert_and_draw(&f, p), "NV12 texture")
		}
	}
}
