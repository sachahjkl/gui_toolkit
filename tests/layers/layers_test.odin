// Pixel tests of draw layers (group opacity) on an offscreen renderer (WARP, the software rasterizer: no GPU or
// window needed), in both blend spaces.   odin test tests/layers -vet
package layers_test

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

// Green of half-transparent red over white: blended in linear light (188) or on sRGB values (128).
@(private = "file")
half_over_white :: proc(space: render.Blend_Space) -> int { return space == .Srgb ? 128 : 188 }

@(private = "file")
frame :: proc(f: ^Fx, body: proc(dc: ^draw.Context)) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
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

RED :: draw.Color{1, 0, 0, 1}
BLUE :: draw.Color{0, 0, 1, 1}

@(test)
group_opacity_hides_overlaps :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		two :: proc(dc: ^draw.Context) {
			draw.rect(dc, {{8, 8}, {40, 40}}, RED)
			draw.rect(dc, {{24, 24}, {56, 56}}, BLUE)
		}
		layered := frame(&f, proc(dc: ^draw.Context) {
			draw.push_layer(dc, {{0, 0}, {64, 64}}, 0.5)
			two(dc)
			draw.pop_layer(dc)
		})
		only_blue := px(layered, 50, 50)
		overlap := px(layered, 30, 30)
		only_red := px(layered, 12, 12)
		testing.expectf(t, close_px(overlap, only_blue), "%v: inside a layer the red under the blue does not show: %v vs %v", space, overlap, only_blue)
		half := half_over_white(space)
		testing.expectf(t, only_red[0] == 255 && abs(only_red[1] - half) <= 2 && abs(only_red[2] - half) <= 2, "%v: half-transparent red over white: %v", space, only_red)
		testing.expectf(t, close_px(px(layered, 2, 2), {255, 255, 255, 255}), "%v: outside: white", space)

		per_primitive := frame(&f, proc(dc: ^draw.Context) {
			draw.push_alpha(dc, 0.5)
			two(dc)
			draw.pop_alpha(dc)
		})
		testing.expectf(t, !close_px(px(per_primitive, 30, 30), px(per_primitive, 50, 50), 8), "%v: push_alpha fades each primitive: the overlap differs", space)
		testing.expectf(t, close_px(px(per_primitive, 50, 50), only_blue), "%v: single primitives look the same either way", space)

		// an opaque layer looks exactly like no layer
		plain := frame(&f, two)
		opaque := frame(&f, proc(dc: ^draw.Context) {
			draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
			two(dc)
			draw.pop_layer(dc)
		})
		// the layer keeps antialiased edges in fp16, the frame in 8 bits: a couple of levels at most
		worst := 0
		for i in 0 ..< len(plain) { worst = max(worst, abs(int(plain[i]) - int(opaque[i]))) }
		testing.expectf(t, worst <= 2, "%v: alpha 1: the same as drawing without a layer (max channel difference %d)", space, worst)
	}
}

@(test)
layers_nest_and_follow_transforms_and_clips :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		ref := frame(&f, proc(dc: ^draw.Context) {
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.5), {32, 32}))
			draw.push_clip_rounded(dc, {{12, 12}, {52, 52}}, {10, 10, 10, 10})
			draw.rect(dc, {{0, 0}, {64, 64}}, RED)
			draw.pop_clip(dc)
			draw.pop_transform(dc)
		})
		lay := frame(&f, proc(dc: ^draw.Context) {
			draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.5), {32, 32}))
			draw.push_layer(dc, {{12, 12}, {52, 52}}, 1)
			draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)   // nested
			draw.push_clip_rounded(dc, {{12, 12}, {52, 52}}, {10, 10, 10, 10})
			draw.rect(dc, {{0, 0}, {64, 64}}, RED)
			draw.pop_clip(dc)
			draw.pop_layer(dc)
			draw.pop_layer(dc)
			draw.pop_transform(dc)
		})
		worst := 0
		for i in 0 ..< len(ref) { worst = max(worst, abs(int(ref[i]) - int(lay[i]))) }
		testing.expectf(t, worst <= 2, "%v: rotated rounded clip inside two layers matches the direct drawing (max channel difference %d)", space, worst)
		testing.expectf(t, px(lay, 32, 32)[1] < 10 && px(lay, 1, 1)[1] > 250, "%v: red inside, white outside", space)
		testing.expect(t, len(f.dc.layers) == 2 && draw.layer_depth(&f.dc) == 0)

		// targets are pooled: the same frame again allocates nothing new
		before := render.targets_bytes(&f.r)
		_ = frame(&f, proc(dc: ^draw.Context) {
			draw.push_layer(dc, {{10, 10}, {30, 30}}, 0.5)
			draw.rect(dc, {{10, 10}, {30, 30}}, BLUE)
			draw.pop_layer(dc)
		})
		testing.expectf(t, render.targets_bytes(&f.r) == before, "%v: pooled layer targets are reused", space)
	}
}

@(test)
circular_corners_override_the_squircle :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		disc :: proc(dc: ^draw.Context) {
			draw.rect(dc, {{0, 0}, {64, 64}}, RED, 32)
			draw.push_clip_rounded(dc, {{8, 8}, {56, 56}}, {24, 24, 24, 24})
			draw.rect(dc, {{0, 0}, {64, 64}}, BLUE)
			draw.pop_clip(dc)
		}
		render.set_corner_smoothing(&f.r, 0)
		circle := frame(&f, disc)
		render.set_corner_smoothing(&f.r, 1)
		squircle := frame(&f, disc)
		forced := frame(&f, proc(dc: ^draw.Context) {
			prev := draw.set_circular_corners(dc, true)
			disc(dc)
			draw.set_circular_corners(dc, prev)
		})
		diff :: proc(a, b: []u8) -> int {
			worst := 0
			for i in 0 ..< len(a) { worst = max(worst, abs(int(a[i]) - int(b[i]))) }
			return worst
		}
		testing.expectf(t, diff(circle, squircle) > 20, "%v: the squircle differs from the circle", space)
		testing.expectf(t, diff(circle, forced) <= 1, "%v: set_circular_corners draws circles under the squircle setting (difference %d)", space, diff(circle, forced))
	}
}

@(test)
empty_layer_falls_back :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.push_layer(dc, {{100, 100}, {120, 120}}, 0.5)   // outside the frame: no target, plain alpha
			draw.rect(dc, {{0, 0}, {10, 10}}, RED)
			draw.pop_layer(dc)
		})
		testing.expect(t, len(f.dc.layers) == 0)
		p := px(img, 5, 5)
		testing.expectf(t, p[0] == 255 && abs(p[1] - half_over_white(space)) <= 2, "%v: faded with push_alpha: %v", space, p)
	}
}
// What is drawn offscreen is never shown, is not cut by the frame (bigger than it, at negative coordinates of the
// frame's scene), keeps its alpha, and reads back as straight sRGB RGBA (render.readback_poll), in both blend spaces.
@(test)
offscreen_draw_and_read_back :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer { draw.destroy(&f.dc); render.destroy(&f.r) }
		@(static) id: render.Readback_Id
		img := frame(&f, proc(dc: ^draw.Context) {
			testing_ok := draw.offscreen_begin(dc, {100, 40})
			if !testing_ok { return }
			draw.rect(dc, {{0, 0}, {50, 40}}, RED)
			draw.rect(dc, {{50, 0}, {100, 40}}, {0, 0, 1, 0.5})
			id = draw.offscreen_end(dc)
		})
		testing.expect(t, close_px(px(img, 10, 10), {255, 255, 255, 255}), "nothing of it on the frame")
		when render.USE_WGPU {
			// the WebGPU backend cannot read back yet (render/readback.odin): no id, and polling says Failed rather than
			// Pending forever; what was drawn offscreen still stays off the frame (above)
			testing.expect_value(t, id, render.Readback_Id(0))
			_, _, none := render.readback_poll(&f.r, id, context.temp_allocator)
			testing.expect_value(t, none, render.Capture_Status.Failed)
			continue
		}
		testing.expect(t, id != 0, "a readback was recorded")
		pixels: []u8
		size: [2]int
		st: render.Capture_Status
		for _ in 0 ..< 200 {
			pixels, size, st = render.readback_poll(&f.r, id, context.temp_allocator)
			if st != .Pending { break }
		}
		testing.expect_value(t, st, render.Capture_Status.Ready)
		testing.expect_value(t, size, [2]int{100, 40})
		if st != .Ready { continue }
		at :: proc(p: []u8, x, y: int) -> [4]int { o := (y * 100 + x) * 4; return {int(p[o]), int(p[o + 1]), int(p[o + 2]), int(p[o + 3])} }
		testing.expect(t, close_px(at(pixels, 10, 10), {255, 0, 0, 255}), "opaque red, straight")
		testing.expect(t, close_px(at(pixels, 80, 30), {0, 0, 255, 128}), "half blue: straight colour, its alpha")
		_, _, again := render.readback_poll(&f.r, id, context.temp_allocator)
		testing.expect_value(t, again, render.Capture_Status.Failed)   // taken once
	}
	r, g, b, a := render.straight_srgb({0.5, 0, 0, 0.5}, .Srgb)
	testing.expect(t, r == 255 && g == 0 && b == 0 && a == 128)
}