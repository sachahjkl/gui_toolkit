// Pixel tests of RGBA image textures: what create_texture_rgba / update_texture_rgba put on the GPU (zeroing deferred to
// the first draw, opaque uploads that skip the conversion, premultiplied translucent ones, strides, partial updates), in
// both blend spaces, on an offscreen renderer (WARP).   odin test tests/textures -vet
package textures_test

import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

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
