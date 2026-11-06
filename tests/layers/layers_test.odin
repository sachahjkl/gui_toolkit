// Pixel tests of draw layers (group opacity) on an offscreen renderer (WARP, the software rasterizer: no GPU or
// window needed), in both blend spaces.   odin test tests/layers -vet
package layers_test

import "core:mem"
import "core:testing"
import "core:thread"
import "core:time"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{64, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

// How long a readback may take: it only ends a failing run.
@(private = "file") READBACK_LIMIT :: 10 * time.Second

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
		testing.expect(t, id != 0, "a readback was recorded")
		pixels: []u8
		size: [2]int
		st: render.Capture_Status
		start := time.tick_now()
		for time.tick_since(start) < READBACK_LIMIT {   // (the copy is usually ready at the first poll)
			pixels, size, st = render.readback_poll(&f.r, id, context.temp_allocator)
			if st != .Pending { break }
			thread.yield()
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
// A composite in a blend mode replaces what it read (the batch draws without blending), also when a filter pass, which puts the
// pipeline back to blending, came just before it with nothing drawn in between: translucent pixels under it keep their alpha.
@(test)
a_blend_composite_after_a_filter_pass_replaces :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	WHOLE :: draw.Rect{{0, 0}, {f32(SIZE.x), f32(SIZE.y)}}
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {0, 0, 0, 0})
	draw.rect(&f.dc, WHOLE, {1, 1, 1, 0.5})
	draw.push_effects(&f.dc, WHOLE, draw.Layer_Effects{alpha = 1, blend = .Multiply})
	draw.pop_layer(&f.dc)
	blur := [1]draw.Filter{draw.filter_blur(2)}
	bd := draw.backdrop_capture(&f.dc, WHOLE, blur[:])   // a pass, and nothing of it drawn yet
	draw.push_effects(&f.dc, WHOLE, draw.Layer_Effects{alpha = 1, blend = .Multiply})
	draw.pop_layer(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	_ = bd
	a := px(render.read_pixels(&f.r, context.temp_allocator), 32, 32).a
	testing.expectf(t, abs(a - 128) <= 2, "the alpha under two empty composites stays: %d", a)
}

// A kept snapshot is 4 bytes a texel, as the pool counts it, not 8 (and kept mips count).
@(test)
kept_targets_count_as_the_pool_counts_them :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	s := render.acquire_snapshot(&f.r, 16, 16, 0)
	m := render.acquire_target_mips(&f.r, 16, 16)
	testing.expect(t, s != 0 && m != 0)
	testing.expect(t, render.keep_target(&f.r, s) && render.keep_target(&f.r, m))
	testing.expect_value(t, render.kept_targets_bytes(&f.r), render.targets_bytes(&f.r))
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	render.unkeep_target(&f.r, s)
	render.unkeep_target(&f.r, m)
}

// A context gives back every texture it made: its atlas too.
@(test)
a_context_leaves_no_texture_behind :: proc(t: ^testing.T) {
	r: render.Renderer
	if !render.init_offscreen(&r, SIZE, warp = true) { testing.fail_now(t, "no device (WARP)") }
	defer render.destroy(&r)
	fonts: font.State
	before := render.texture_memory(&r).count
	dc: draw.Context
	draw.init(&dc, &r, &fonts)
	testing.expect(t, render.texture_memory(&r).count > before)
	draw.destroy(&dc)
	testing.expect_value(t, render.texture_memory(&r).count, before)
}

// An offscreen target nobody closed is dropped with the frame: not composited, and what it pushed goes with it.
@(test)
an_offscreen_target_left_open_ends_with_the_frame :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	frame(&f, proc(dc: ^draw.Context) {
		if !draw.offscreen_begin(dc, {8, 8}) { return }
		draw.rect(dc, {{0, 0}, {8, 8}}, {1, 0, 0, 1})
	})
	testing.expect_value(t, len(f.dc.xforms), 1)
	testing.expect_value(t, len(f.dc.open_layers), 0)
}

// A plane still open when a recording ends goes with the recording: the frame's stacks are not its own.
@(test)
a_plane_left_open_in_a_picture_ends_with_it :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	frame(&f, proc(dc: ^draw.Context) {
		@(static) pic: draw.Picture
		draw.picture_begin(dc, &pic)
		_ = draw.push_plane(dc, {{0, 0}, {8, 8}}, 1)
		draw.picture_end(dc)
		draw.picture_destroy(dc, &pic)
	})
	testing.expect_value(t, len(f.dc.planes), 0)
	testing.expect_value(t, len(f.dc.clips), 1)
}

// A device lost is one renderer's: the read-back waiting on another still comes.
@(test)
a_device_loss_leaves_the_readbacks_of_another_renderer :: proc(t: ^testing.T) {
	a, b: Fx
	if !open(&a, .Linear) || !open(&b, .Linear) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&a.dc); render.destroy(&a.r); draw.destroy(&b.dc); render.destroy(&b.r) }
	@(static) id: render.Readback_Id
	frame(&a, proc(dc: ^draw.Context) {
		if !draw.offscreen_begin(dc, {8, 8}) { return }
		draw.rect(dc, {{0, 0}, {8, 8}}, {1, 0, 0, 1})
		id = draw.offscreen_end(dc)
	})
	testing.expect(t, id != 0)
	render.simulate_device_loss(&b.r)
	testing.expect(t, render.recover(&b.r))
	st: render.Capture_Status
	start := time.tick_now()
	for time.tick_since(start) < READBACK_LIMIT {
		_, _, st = render.readback_poll(&a.r, id, context.temp_allocator)
		if st != .Pending { break }
		thread.yield()
	}
	testing.expect_value(t, st, render.Capture_Status.Ready)
}

// The table of read-backs is the process's: it does not belong to the allocator of whoever wrote in it first. Two tests side by side showed it, on a
// busy machine: the first one ended with the second's read-back still in the table, and counted the table as its leak.
@(test)
the_readback_table_is_not_its_first_writers :: proc(t: ^testing.T) {
	r: render.Renderer
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	first: render.Readback_Id
	{
		context.allocator = mem.tracking_allocator(&track)
		first = render.readback_new(&r)
	}
	second := render.readback_new(&r)
	defer render.readback_release(&r, second)
	{
		context.allocator = mem.tracking_allocator(&track)
		render.readback_release(&r, first)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}

// A second end_frame submits nothing: the frame is not drawn twice.
@(test)
a_second_end_frame_submits_nothing :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.rect(&f.dc, {{0, 0}, {64, 64}}, {1, 0, 0, 0.5})
	draw.end_frame(&f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	img := render.read_pixels(&f.r, context.temp_allocator)
	testing.expectf(t, abs(px(img, 32, 32)[1] - half_over_white(.Srgb)) <= 2, "%v", px(img, 32, 32))
}

// Pops past the root do nothing: what comes next draws as if they had not been made.
@(test)
pops_stop_at_the_root :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.pop_clip(dc)
		draw.pop_alpha(dc)
		draw.pop_transform(dc)
		draw.pop_xform(dc)
		draw.pop_layer(dc)
		draw.pop_mask(dc)
		draw.rect(dc, {{0, 0}, {64, 64}}, RED)
	})
	testing.expect(t, close_px(px(img, 32, 32), {255, 0, 0, 255}))
}

// What a layer opened is its own: a pop inside it stops at it, and what it left pushed ends with it.
@(test)
a_layer_owns_its_stacks :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_clip(dc, {{0, 0}, {32, 64}})
		draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
		draw.pop_clip(dc)       // (the layer's root: not the caller's)
		draw.pop_alpha(dc)
		draw.rect(dc, {{0, 0}, {16, 64}}, RED)
		draw.push_clip(dc, {{0, 0}, {4, 4}})
		draw.push_alpha(dc, 0.5)
		draw.push_transform(dc, draw.affine_translate({1, 1}))
		draw.pop_layer(dc)      // (left pushed)
		draw.rect(dc, {{16, 0}, {64, 64}}, BLUE)
		draw.pop_clip(dc)
	})
	testing.expect(t, close_px(px(img, 8, 32), {255, 0, 0, 255}), "the layer's content")
	testing.expect(t, close_px(px(img, 24, 32), {0, 0, 255, 255}), "after it: the caller's clip, opaque, not moved")
	testing.expect(t, close_px(px(img, 48, 32), {255, 255, 255, 255}), "cut by the caller's clip")
	testing.expect_value(t, len(f.dc.clips), 1)
	testing.expect_value(t, len(f.dc.alphas), 1)
	testing.expect_value(t, len(f.dc.xforms), 1)
}

// Layers and planes end in the order they were opened: a layer left open in a plane ends with the plane.
@(test)
a_layer_left_open_in_a_plane_ends_with_it :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		_ = draw.push_plane(dc, {{0, 0}, {64, 64}}, 1)
		draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
		draw.rect(dc, {{0, 0}, {32, 64}}, RED)
		draw.pop_plane_draw(dc, draw.MAT4_IDENTITY)
	})
	testing.expect(t, close_px(px(img, 16, 32), {255, 0, 0, 255}), "the layer's content is in the plane")
	testing.expect_value(t, len(f.dc.open_layers), 0)
	testing.expect_value(t, len(f.dc.clips), 1)
}

// ... and at the end of the frame, whichever stack is closed first.
@(test)
a_layer_and_a_plane_left_open_end_with_the_frame :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	_ = frame(&f, proc(dc: ^draw.Context) {
		_ = draw.push_plane(dc, {{0, 0}, {64, 64}}, 1)
		draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
	})
	testing.expect_value(t, len(f.dc.clips), 1)
	_ = frame(&f, proc(dc: ^draw.Context) {
		draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
		_ = draw.push_plane(dc, {{0, 0}, {64, 64}}, 1)
	})
	testing.expect_value(t, len(f.dc.clips), 1)
	testing.expect_value(t, len(f.dc.xforms), 1)
}

// A plane left open in a layer ends with the layer: the layer is closed, its plane dropped.
@(test)
a_plane_left_open_in_a_layer_ends_with_it :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_layer(dc, {{0, 0}, {64, 64}}, 1)
		draw.rect(dc, {{0, 0}, {32, 64}}, RED)
		_ = draw.push_plane(dc, {{0, 0}, {64, 64}}, 1)
		draw.rect(dc, {{0, 0}, {64, 64}}, BLUE)
		draw.pop_layer(dc)
	})
	testing.expect(t, close_px(px(img, 16, 32), {255, 0, 0, 255}), "the layer")
	testing.expect(t, close_px(px(img, 48, 32), {255, 255, 255, 255}), "not the plane")
	testing.expect_value(t, len(f.dc.planes), 0)
}

// A recording ends only what it opened: the frame's plane stays open across it.
@(test)
a_recording_cannot_close_the_frames_plane :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	img := frame(&f, proc(dc: ^draw.Context) {
		@(static) pic: draw.Picture
		_ = draw.push_plane(dc, {{0, 0}, {64, 64}}, 1)
		draw.picture_begin(dc, &pic)
		_ = draw.pop_plane(dc)
		draw.picture_end(dc)
		draw.picture_destroy(dc, &pic)
		draw.rect(dc, {{0, 0}, {64, 64}}, RED)
		draw.pop_plane_draw(dc, draw.MAT4_IDENTITY)
	})
	testing.expect(t, close_px(px(img, 32, 32), {255, 0, 0, 255}))
}

// A plane opened while recording draws nothing: there is no frame for it to say.
@(test)
a_plane_of_a_recording_has_no_frame :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no device (WARP)") }
	defer { draw.destroy(&f.dc); render.destroy(&f.r) }
	@(static) ok: bool
	_ = frame(&f, proc(dc: ^draw.Context) {
		@(static) pic: draw.Picture
		draw.picture_begin(dc, &pic)
		_ = draw.push_plane(dc, {{0, 0}, {8, 8}}, 1)
		_, _, ok = draw.open_plane_frame(dc)
		_ = draw.pop_plane(dc)
		draw.picture_end(dc)
		draw.picture_destroy(dc, &pic)
	})
	testing.expect(t, !ok)
}

// A context destroyed in the middle of a recording frees the frame's lists it had put aside.
@(test)
a_context_destroyed_while_recording_leaves_nothing :: proc(t: ^testing.T) {
	r: render.Renderer
	if !render.init_offscreen(&r, SIZE, warp = true) { testing.fail_now(t, "no device (WARP)") }
	defer render.destroy(&r)
	fonts: font.State
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	pic: draw.Picture
	dc: draw.Context
	draw.init(&dc, &r, &fonts)
	{
		context.allocator = mem.tracking_allocator(&track)
		draw.begin_frame(&dc, {f32(SIZE.x), f32(SIZE.y)})
		draw.rect(&dc, {{0, 0}, {8, 8}}, RED)
		draw.picture_begin(&dc, &pic)
		draw.rect(&dc, {{0, 0}, {8, 8}}, RED)
	}
	{
		draw.destroy(&dc)   // (what is freed knows its allocator; what the renderer keeps is not tracked here)
		delete(pic.insts); delete(pic.batches); delete(pic.batch_bounds); delete(pic.slots); delete(pic.clips); delete(pic.clip_rects)
		delete(pic.points); delete(pic.grads); delete(pic.pages); delete(pic.slug_pages); delete(pic.slug_runs)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}