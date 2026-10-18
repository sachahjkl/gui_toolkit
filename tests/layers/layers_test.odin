// Pixel tests of draw layers (group opacity) on an offscreen renderer (WARP, the software rasterizer: no GPU or
// window needed).   odin test tests/layers -vet
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
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

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
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
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
	testing.expectf(t, close_px(overlap, only_blue), "inside a layer the red under the blue does not show: %v vs %v", overlap, only_blue)
	testing.expectf(t, only_red[0] > 200 && only_red[1] > 150 && only_red[1] < 220, "half-transparent red over white: %v", only_red)
	testing.expectf(t, close_px(px(layered, 2, 2), {255, 255, 255, 255}), "outside: white")

	per_primitive := frame(&f, proc(dc: ^draw.Context) {
		draw.push_alpha(dc, 0.5)
		two(dc)
		draw.pop_alpha(dc)
	})
	testing.expect(t, !close_px(px(per_primitive, 30, 30), px(per_primitive, 50, 50), 8), "push_alpha fades each primitive: the overlap differs")
	testing.expect(t, close_px(px(per_primitive, 50, 50), only_blue), "single primitives look the same either way")

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
	testing.expectf(t, worst <= 2, "alpha 1: the same as drawing without a layer (max channel difference %d)", worst)
}

@(test)
layers_nest_and_follow_transforms_and_clips :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
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
	testing.expectf(t, worst <= 2, "rotated rounded clip inside two layers matches the direct drawing (max channel difference %d)", worst)
	testing.expect(t, px(lay, 32, 32)[1] < 10 && px(lay, 1, 1)[1] > 250, "red inside, white outside")
	testing.expect(t, len(f.dc.layers) == 2 && draw.layer_depth(&f.dc) == 0)

	// targets are pooled: the same frame again allocates nothing new
	before := render.targets_bytes(&f.r)
	_ = frame(&f, proc(dc: ^draw.Context) {
		draw.push_layer(dc, {{10, 10}, {30, 30}}, 0.5)
		draw.rect(dc, {{10, 10}, {30, 30}}, BLUE)
		draw.pop_layer(dc)
	})
	testing.expect(t, render.targets_bytes(&f.r) == before, "pooled layer targets are reused")
}

@(test)
empty_layer_falls_back :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_layer(dc, {{100, 100}, {120, 120}}, 0.5)   // outside the frame: no target, plain alpha
		draw.rect(dc, {{0, 0}, {10, 10}}, RED)
		draw.pop_layer(dc)
	})
	testing.expect(t, len(f.dc.layers) == 0)
	p := px(img, 5, 5)
	testing.expectf(t, p[0] > 200 && p[1] > 150 && p[1] < 220, "faded with push_alpha: %v", p)
}
