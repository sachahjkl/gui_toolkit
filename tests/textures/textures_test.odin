// Pixel tests of RGBA image textures: what create_texture_rgba / update_texture_rgba put on the GPU (zeroing deferred to
// the first draw, opaque uploads that skip the conversion, premultiplied translucent ones, strides, partial updates), in
// both blend spaces, on an offscreen renderer (WARP).   odin test tests/textures -collection:gt=src -vet
package textures_test

import "core:testing"
import "gt:draw"
import "gt:font"
import "gt:render"

SIZE :: [2]int{64, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

@(private = "file")
close_px :: proc(a, b: [4]int, tol := 2) -> bool {
	for i in 0 ..< 4 { if abs(a[i] - b[i]) > tol { return false } }
	return true
}

// A frame that draws `tex` 1:1 at (8, 8) over a white background; `size` is the texture's size.
@(private = "file")
show :: proc(f: ^Fx, tex: render.Texture, size: [2]int) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.image(&f.dc, tex, {{8, 8}, {8 + f32(size.x), 8 + f32(size.y)}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

// Nothing was ever written: the texture is transparent (the zeroing waits for the draw), so the white background shows.
@(test)
unfilled_texture_is_transparent :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		tex := render.create_texture_rgba(&f.r, 16, 16)
		testing.expect(t, tex != 0)
		img := show(&f, tex, {16, 16})
		testing.expectf(t, close_px(px(img, 16, 16), {255, 255, 255, 255}), "%v: an empty texture shows nothing: %v", space, px(img, 16, 16))
		render.destroy_texture(&f.r, tex)
	}
}

// An opaque image (uploaded straight from the caller's pixels, a stride wider than the rows) shows exactly.
@(test)
opaque_upload_with_stride :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		W, H, STRIDE :: 8, 8, 40
		src := make([]u8, STRIDE * H, context.temp_allocator)
		for y in 0 ..< H {
			for x in 0 ..< W {
				o := y * STRIDE + x * 4
				src[o], src[o + 1], src[o + 2], src[o + 3] = u8(x * 30), u8(y * 30), 200, 255
			}
			for i in W * 4 ..< STRIDE { src[y * STRIDE + i] = 0xEE }   // padding that must not reach the texture
		}
		tex := render.create_texture_rgba(&f.r, W, H, mips = false)
		render.update_texture_rgba(&f.r, tex, 0, 0, W, H, src, STRIDE)
		img := show(&f, tex, {W, H})
		for y in 0 ..< H {
			for x in 0 ..< W {
				want := [4]int{x * 30, y * 30, 200, 255}
				testing.expectf(t, close_px(px(img, 8 + x, 8 + y), want, 1), "%v: (%d,%d) %v, want %v", space, x, y, px(img, 8 + x, 8 + y), want)
			}
		}
		render.destroy_texture(&f.r, tex)
	}
}

// One translucent pixel makes the whole block go through the conversion: premultiplied, the rest unchanged.
@(test)
translucent_upload_is_premultiplied :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		src := make([]u8, 4 * 4 * 4, context.temp_allocator)
		for i := 0; i < len(src); i += 4 { src[i], src[i + 1], src[i + 2], src[i + 3] = 10, 20, 30, 255 }
		src[(1 * 4 + 1) * 4], src[(1 * 4 + 1) * 4 + 1], src[(1 * 4 + 1) * 4 + 2], src[(1 * 4 + 1) * 4 + 3] = 255, 0, 0, 0    // transparent
		src[(2 * 4 + 2) * 4], src[(2 * 4 + 2) * 4 + 1], src[(2 * 4 + 2) * 4 + 2], src[(2 * 4 + 2) * 4 + 3] = 255, 0, 0, 128  // half red
		tex := render.create_texture_rgba(&f.r, 4, 4, mips = false)
		render.update_texture_rgba(&f.r, tex, 0, 0, 4, 4, src)
		img := show(&f, tex, {4, 4})
		testing.expectf(t, close_px(px(img, 8, 8), {10, 20, 30, 255}, 1), "%v: opaque pixel: %v", space, px(img, 8, 8))
		testing.expectf(t, close_px(px(img, 9, 9), {255, 255, 255, 255}, 1), "%v: transparent pixel shows the white behind: %v", space, px(img, 9, 9))
		half := space == .Srgb ? 128 : 188
		testing.expectf(t, close_px(px(img, 10, 10), {255, half, half, 255}, 2), "%v: half red over white: %v", space, px(img, 10, 10))
		render.destroy_texture(&f.r, tex)
	}
}

// A partial update of a texture nothing else was written to: the rest is transparent, not undefined.
@(test)
partial_update_zeroes_the_rest :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		tex := render.create_texture_rgba(&f.r, 16, 16)
		block: [4 * 4 * 4]u8
		for i := 0; i < len(block); i += 4 { block[i], block[i + 1], block[i + 2], block[i + 3] = 0, 255, 0, 255 }
		render.update_texture_rgba(&f.r, tex, 4, 4, 4, 4, block[:])
		img := show(&f, tex, {16, 16})
		testing.expectf(t, close_px(px(img, 8 + 5, 8 + 5), {0, 255, 0, 255}, 1), "%v: the written block: %v", space, px(img, 13, 13))
		testing.expectf(t, close_px(px(img, 8 + 1, 8 + 1), {255, 255, 255, 255}, 1), "%v: outside the block: transparent: %v", space, px(img, 9, 9))
		testing.expectf(t, close_px(px(img, 8 + 12, 8 + 12), {255, 255, 255, 255}, 1), "%v: far outside: transparent: %v", space, px(img, 20, 20))
		render.destroy_texture(&f.r, tex)
	}
}

// A mipmapped photo drawn at half size: the chain is built from what was uploaded (opaque path included).
@(test)
mips_follow_an_opaque_upload :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		src := make([]u8, 32 * 32 * 4, context.temp_allocator)
		for i := 0; i < len(src); i += 4 { src[i], src[i + 1], src[i + 2], src[i + 3] = 0, 0, 255, 255 }
		tex := render.create_texture_rgba(&f.r, 32, 32)
		render.update_texture_rgba(&f.r, tex, 0, 0, 32, 32, src)
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.image(&f.dc, tex, {{8, 8}, {24, 24}})
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		img := render.read_pixels(&f.r, context.temp_allocator)
		testing.expectf(t, close_px(px(img, 16, 16), {0, 0, 255, 255}, 1), "%v: a blue texture shrunk stays blue: %v", space, px(img, 16, 16))
		render.destroy_texture(&f.r, tex)
	}
}

// Upscaling a 2x2 checkerboard: Smooth blends across the middle; Pixelated and Nearest keep hard texel boundaries.
@(test)
image_filter_upscale_pixelated_and_nearest :: proc(t: ^testing.T) {
	checker := [2 * 2 * 4]u8{
		255, 0, 0, 255,   0, 0, 255, 255,
		0, 0, 255, 255,   255, 0, 0, 255,
	}
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no offscreen renderer") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		tex := render.create_texture_rgba(&f.r, 2, 2, mips = false)
		defer render.destroy_texture(&f.r, tex)
		render.update_texture_rgba(&f.r, tex, 0, 0, 2, 2, checker[:])

		draw_with :: proc(f: ^Fx, tex: render.Texture, filter: draw.Image_Filter) -> []u8 {
			draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
			render.frame_begin(&f.r, {1, 1, 1, 1})
			prev := draw.set_image_filter(&f.dc, filter)
			draw.image(&f.dc, tex, {{8, 8}, {48, 48}})
			draw.set_image_filter(&f.dc, prev)
			draw.end_frame(&f.dc)
			render.frame_end(&f.r)
			return render.read_pixels(&f.r, context.temp_allocator)
		}

		// Smooth blends between red and blue at the vertical boundary (x = 27, 28)
		smooth := draw_with(&f, tex, .Smooth)
		sm_l, sm_r := px(smooth, 27, 18), px(smooth, 28, 18)
		testing.expectf(t, sm_l[0] > 30 && sm_l[2] > 30 && sm_r[0] > 30 && sm_r[2] > 30,
			"%v: smooth upscale blends across boundary: %v %v", space, sm_l, sm_r)

		for filter in ([?]draw.Image_Filter{.Pixelated, .Nearest}) {
			img := draw_with(&f, tex, filter)
			testing.expectf(t, close_px(px(img, 27, 18), {255, 0, 0, 255}, 1), "%v %v: left of seam is pure red: %v", space, filter, px(img, 27, 18))
			testing.expectf(t, close_px(px(img, 28, 18), {0, 0, 255, 255}, 1), "%v %v: right of seam is pure blue: %v", space, filter, px(img, 28, 18))
			testing.expectf(t, close_px(px(img, 27, 27), {255, 0, 0, 255}, 1), "%v %v: top-left corner of center: %v", space, filter, px(img, 27, 27))
			testing.expectf(t, close_px(px(img, 27, 28), {0, 0, 255, 255}, 1), "%v %v: bottom-left corner of center: %v", space, filter, px(img, 27, 28))
			testing.expectf(t, close_px(px(img, 28, 28), {255, 0, 0, 255}, 1), "%v %v: bottom-right corner of center: %v", space, filter, px(img, 28, 28))
		}

		// begin_frame resets image_filter back to .Smooth
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		prev := draw.set_image_filter(&f.dc, .Pixelated)
		testing.expect_value(t, prev, draw.Image_Filter.Smooth)
		draw.end_frame(&f.dc)
		draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
		testing.expect_value(t, draw.set_image_filter(&f.dc, .Smooth), draw.Image_Filter.Smooth)
		draw.end_frame(&f.dc)
	}
}

// Downscaling a 4x4 red/blue checkerboard to 2x2: Pixelated falls back to smooth mip filtering, Nearest stays hard.
@(test)
image_filter_downscale_pixelated_vs_nearest :: proc(t: ^testing.T) {
	src: [4 * 4 * 4]u8
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			o := (y * 4 + x) * 4
			if (x + y) & 1 == 0 {
				src[o], src[o + 1], src[o + 2], src[o + 3] = 255, 0, 0, 255
			} else {
				src[o], src[o + 1], src[o + 2], src[o + 3] = 0, 0, 255, 255
			}
		}
	}
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no offscreen renderer") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		tex := render.create_texture_rgba(&f.r, 4, 4, mips = true)
		defer render.destroy_texture(&f.r, tex)
		render.update_texture_rgba(&f.r, tex, 0, 0, 4, 4, src[:])

		draw_down :: proc(f: ^Fx, tex: render.Texture, filter: draw.Image_Filter) -> [4]int {
			draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
			render.frame_begin(&f.r, {1, 1, 1, 1})
			draw.set_image_filter(&f.dc, filter)
			draw.image(&f.dc, tex, {{8, 8}, {10, 10}})
			draw.end_frame(&f.dc)
			render.frame_end(&f.r)
			img := render.read_pixels(&f.r, context.temp_allocator)
			return px(img, 8, 8)
		}

		pix := draw_down(&f, tex, .Pixelated)
		testing.expectf(t, pix[0] >= 80 && pix[2] >= 80, "%v: pixelated downscale blends smoothly: %v", space, pix)

		near := draw_down(&f, tex, .Nearest)
		pure := (near[0] >= 250 && near[2] <= 5) || (near[2] >= 250 && near[0] <= 5)
		testing.expectf(t, pure, "%v: nearest downscale picks an unblended texel: %v", space, near)
	}
}

// Sprite-sheet sub-rect clamping, tiled image wrapping, and retained draw.Picture replay with Pixelated.
@(test)
image_filter_subrect_tiled_and_picture :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no offscreen renderer") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }

	// 4x4 texture with green outer ring and 2x2 red/blue inner sprite
	atlas: [4 * 4 * 4]u8
	for y in 0 ..< 4 {
		for x in 0 ..< 4 {
			o := (y * 4 + x) * 4
			if x >= 1 && x <= 2 && y >= 1 && y <= 2 {
				if (x + y) & 1 == 0 {
					atlas[o], atlas[o + 1], atlas[o + 2], atlas[o + 3] = 255, 0, 0, 255
				} else {
					atlas[o], atlas[o + 1], atlas[o + 2], atlas[o + 3] = 0, 0, 255, 255
				}
			} else {
				atlas[o], atlas[o + 1], atlas[o + 2], atlas[o + 3] = 0, 255, 0, 255
			}
		}
	}
	tex_atlas := render.create_texture_rgba(&f.r, 4, 4, mips = false)
	defer render.destroy_texture(&f.r, tex_atlas)
	render.update_texture_rgba(&f.r, tex_atlas, 0, 0, 4, 4, atlas[:])

	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.set_image_filter(&f.dc, .Pixelated)
	draw.image(&f.dc, tex_atlas, {{4, 4}, {44, 44}}, src = {{1, 1}, {3, 3}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	sub_img := render.read_pixels(&f.r, context.temp_allocator)
	for y in 4 ..< 44 {
		for x in 4 ..< 44 {
			c := px(sub_img, x, y)
			testing.expectf(t, c[1] == 0, "sub-rect (%d,%d) must not bleed green border: %v", x, y, c)
		}
	}
	testing.expectf(t, close_px(px(sub_img, 23, 14), {255, 0, 0, 255}, 1), "sub-rect left of seam: %v", px(sub_img, 23, 14))
	testing.expectf(t, close_px(px(sub_img, 24, 14), {0, 0, 255, 255}, 1), "sub-rect right of seam: %v", px(sub_img, 24, 14))

	// Tiled 2x2 red/blue texture repeated across 32x32 with 16x16 tiles (offset so negative UVs also wrap)
	checker := [2 * 2 * 4]u8{
		255, 0, 0, 255,   0, 0, 255, 255,
		0, 0, 255, 255,   255, 0, 0, 255,
	}
	tex_tile := render.create_texture_rgba(&f.r, 2, 2, mips = false)
	defer render.destroy_texture(&f.r, tex_tile)
	render.update_texture_rgba(&f.r, tex_tile, 0, 0, 2, 2, checker[:])

	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.set_image_filter(&f.dc, .Pixelated)
	draw.image_tiled(&f.dc, tex_tile, {{0, 0}, {32, 32}}, {{16, 16}, {32, 32}})
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	tile_img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expectf(t, close_px(px(tile_img, 7, 4), {255, 0, 0, 255}, 1), "wrapped tile (-1) left: %v", px(tile_img, 7, 4))
	testing.expectf(t, close_px(px(tile_img, 8, 4), {0, 0, 255, 255}, 1), "wrapped tile (-1) right: %v", px(tile_img, 8, 4))
	testing.expectf(t, close_px(px(tile_img, 15, 4), {0, 0, 255, 255}, 1), "tile seam left: %v", px(tile_img, 15, 4))
	testing.expectf(t, close_px(px(tile_img, 16, 4), {255, 0, 0, 255}, 1), "tile seam right: %v", px(tile_img, 16, 4))

	// Retained picture preserves Pixelated flag even when replayed under Smooth
	pic: draw.Picture
	defer draw.picture_destroy(&pic)
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.picture_begin(&f.dc, &pic)
	draw.set_image_filter(&f.dc, .Pixelated)
	draw.image(&f.dc, tex_tile, {{8, 8}, {48, 48}})
	draw.set_image_filter(&f.dc, .Smooth)
	draw.picture_end(&f.dc)
	draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	pic_img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expectf(t, close_px(px(pic_img, 27, 18), {255, 0, 0, 255}, 1), "picture replay left: %v", px(pic_img, 27, 18))
	testing.expectf(t, close_px(px(pic_img, 28, 18), {0, 0, 255, 255}, 1), "picture replay right: %v", px(pic_img, 28, 18))
}
