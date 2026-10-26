package slug_test

import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

// Pixel tests of Slug text through the draw layer on an offscreen renderer (WARP): against the atlas, under transforms,
// in order with other primitives, clipped, in pictures, after a lost device.

SIZE :: [2]int{240, 90}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
}

open :: proc(t: ^testing.T, f: ^Fx, renderer: font.Text_Renderer, space := render.Blend_Space.Srgb, pages := 0) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	st := font.DEFAULT_SETTINGS
	st.text_renderer = renderer
	if pages > 0 { st.slug_pages = pages }
	font.init(&f.fonts, st)
	ok: bool
	f.ui, ok = font.load_system(&f.fonts, "Segoe UI")
	draw.init(&f.dc, &f.r, &f.fonts)
	return ok
}

close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

frame :: proc(f: ^Fx, body: proc(f: ^Fx)) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(f)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

px :: proc(img: []u8, x, y: int) -> [3]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
}

// Mean absolute difference per pixel (0..255) and the ink (darkness) of each image over a region.
compare :: proc(a, b: []u8, x0, y0, x1, y1: int) -> (diff: f64, ink_a, ink_b: f64) {
	n := 0
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			pa, pb := px(a, x, y), px(b, x, y)
			diff += f64(abs(pa.x - pb.x) + abs(pa.y - pb.y) + abs(pa.z - pb.z)) / 3
			ink_a += f64(255 - (pa.x + pa.y + pa.z) / 3)
			ink_b += f64(255 - (pb.x + pb.y + pb.z) / 3)
			n += 1
		}
	}
	return diff / f64(n), ink_a / f64(n), ink_b / f64(n)
}

BLACK :: draw.Color{0, 0, 0, 1}

paragraph :: proc(f: ^Fx) {
	draw.text(&f.dc, f.ui, 16, {6, 22}, BLACK, "Hamburgefonstiv sphinx 0123")
	draw.text(&f.dc, f.ui, 12, {6, 44}, BLACK, "The quick brown fox jumps over the lazy dog")
	draw.text(&f.dc, f.ui, 28, {6, 80}, BLACK, "Wren")
}

@(test)
slug_looks_like_the_atlas :: proc(t: ^testing.T) {
	for space in ([?]render.Blend_Space{.Srgb, .Linear}) {
		a, s := new(Fx), new(Fx)
		defer free(a)
		defer free(s)
		if !open(t, a, .Atlas, space) || !open(t, s, .Slug, space) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
		defer close(a)
		defer close(s)
		ia := frame(a, paragraph)
		is := frame(s, paragraph)
		diff, ink_a, ink_s := compare(ia, is, 0, 0, SIZE.x, SIZE.y)
		testing.expectf(t, diff < 5, "%v: Slug differs from the atlas by %.2f / 255 on average", space, diff)
		testing.expectf(t, ink_s > ink_a * 0.85 && ink_s < ink_a * 1.15, "%v: ink %.3f (atlas) vs %.3f (Slug): the weight is off", space, ink_a, ink_s)
		testing.expect(t, font.slug_stats(&s.fonts).glyphs > 10, "the glyphs came from the Slug store")
		testing.expect_value(t, font.slug_stats(&a.fonts).glyphs, 0)
	}
}

// When the device refuses the Slug shaders its text is not drawn: it used to come out as one solid rounded rect per glyph.
// Both backends: r.slug.failed is what a refusal leaves (Direct3D 11: slug_pipeline_ensure; WebGPU: wgpu_instance_pipeline).
@(test)
slug_refused_by_the_device_draws_no_blocks :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Slug) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	f.r.slug.failed = true   // as slug_pipeline_ensure leaves it after a refusal
	img := frame(f, proc(f: ^Fx) {
		draw.rect(&f.dc, {{200, 4}, {230, 30}}, draw.Color{0, 0, 1, 1})
		draw.text(&f.dc, f.ui, 28, {6, 40}, BLACK, "HHHH")
	})
	testing.expect_value(t, px(img, 215, 15), [3]int{0, 0, 255})
	_, ink, _ := compare(img, img, 6, 12, 90, 44)
	testing.expectf(t, ink < 1, "no glyph blocks: ink %.2f", ink)
}

// Rotated text: Slug draws it, in order with a rect drawn over a part of it, and a rounded clip cuts it.
@(test)
slug_order_clip_and_rotation :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Slug) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	img := frame(f, proc(f: ^Fx) {
		draw.text(&f.dc, f.ui, 28, {6, 30}, BLACK, "HHHH")                     // x 6..90
		draw.rect(&f.dc, {{40, 4}, {70, 40}}, draw.Color{1, 0, 0, 1})          // over the middle letters
		draw.text(&f.dc, f.ui, 28, {80, 30}, draw.Color{0, 0, 1, 1}, "HH")     // after it: on top where they meet
		draw.push_clip_rounded(&f.dc, {{120, 4}, {150, 40}}, {10, 10, 10, 10})
		draw.text(&f.dc, f.ui, 40, {110, 36}, BLACK, "HHHH")
		draw.pop_clip(&f.dc)
		draw.push_transform(&f.dc, draw.affine_around(draw.affine_rotate(0.5), {60, 70}))
		draw.text(&f.dc, f.ui, 20, {20, 70}, BLACK, "Rotated")
		draw.pop_transform(&f.dc)
	})
	// the rect hides the letters under it: its middle is pure red
	testing.expect_value(t, px(img, 55, 20), [3]int{255, 0, 0})
	// outside the rounded clip nothing of the big letters: the corner of the clip box is white, and far right too
	testing.expect_value(t, px(img, 121, 5), [3]int{255, 255, 255})
	ink := 0
	for x in 160 ..< 238 { for y in 0 ..< 40 { if px(img, x, y).x < 128 { ink += 1 } } }
	testing.expect_value(t, ink, 0)
	// ink inside the clip, and for the rotated text
	inside := 0
	for x in 122 ..< 148 { for y in 8 ..< 38 { if px(img, x, y).x < 128 { inside += 1 } } }
	testing.expect(t, inside > 40, "no text inside the clip")
	rot := 0
	for x in 20 ..< 110 { for y in 50 ..< 90 { if px(img, x, y).x < 128 { rot += 1 } } }
	testing.expect(t, rot > 60, "no rotated text")
}

// A picture of Slug text replays at any scale without going stale (no bitmaps depend on the scale), and looks like the
// text drawn directly; reusing its glyph page makes it stale.
@(test)
slug_in_pictures :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Slug, pages = 1) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	@(static) pic: draw.Picture
	defer draw.picture_destroy(&f.dc, &pic)
	record :: proc(f: ^Fx) {
		draw.picture_begin(&f.dc, &pic)
		draw.text(&f.dc, f.ui, 16, {4, 20}, BLACK, "Picture text 123")
		draw.picture_end(&f.dc)
	}
	@(static) result: draw.Replay_Result
	@(static) scale: f32
	scale = 1
	direct := frame(f, proc(f: ^Fx) {
		draw.push_scale(&f.dc, {0, 0}, scale)
		draw.text(&f.dc, f.ui, 16, {4, 20}, BLACK, "Picture text 123")
		draw.pop_xform(&f.dc)
	})
	frame(f, record)
	for k in ([?]f32{1, 3}) {
		scale = k
		direct = frame(f, proc(f: ^Fx) {
			draw.push_scale(&f.dc, {0, 0}, scale)
			draw.text(&f.dc, f.ui, 16, {4, 20}, BLACK, "Picture text 123")
			draw.pop_xform(&f.dc)
		})
		replayed := frame(f, proc(f: ^Fx) { result = draw.replay(&f.dc, &pic, draw.affine_scale({scale, scale})) })
		testing.expect_value(t, result, draw.Replay_Result.Drawn)
		diff, ink_d, _ := compare(direct, replayed, 0, 0, SIZE.x, SIZE.y)
		testing.expectf(t, diff < 0.5 && ink_d > 1, "x%.0f: the replay differs from direct drawing by %.2f", k, diff)
	}
	// a flood of other glyphs on the one page the store may have, over several frames: the picture's page is reused
	frame(f, proc(f: ^Fx) {
		for gid in 3 ..< 900 { font.slug_glyph(&f.fonts, f.ui, u16(gid)) }
	})
	frame(f, proc(f: ^Fx) {
		for gid in 900 ..< 1800 { font.slug_glyph(&f.fonts, f.ui, u16(gid)) }
		result = draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY)
	})
	testing.expect_value(t, result, draw.Replay_Result.Stale)
}

// Switching the renderer while the app runs: what was recorded with the other one is recorded again, and both draw.
@(test)
slug_switch_at_run_time :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Atlas) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	@(static) pic: draw.Picture
	defer draw.picture_destroy(&f.dc, &pic)
	@(static) result: draw.Replay_Result
	frame(f, proc(f: ^Fx) {
		draw.picture_begin(&f.dc, &pic)
		draw.text(&f.dc, f.ui, 16, {4, 20}, BLACK, "Picture text 123")
		draw.picture_end(&f.dc)
	})
	frame(f, proc(f: ^Fx) { result = draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY) })
	testing.expect_value(t, result, draw.Replay_Result.Drawn)
	atlas_img := frame(f, proc(f: ^Fx) { result = draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY) })
	st := f.fonts.settings
	st.text_renderer = .Slug
	font.set_settings(&f.fonts, st)
	frame(f, proc(f: ^Fx) { result = draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY) })
	testing.expect_value(t, result, draw.Replay_Result.Stale)
	frame(f, proc(f: ^Fx) {
		draw.picture_begin(&f.dc, &pic)
		draw.text(&f.dc, f.ui, 16, {4, 20}, BLACK, "Picture text 123")
		draw.picture_end(&f.dc)
	})
	slug_img := frame(f, proc(f: ^Fx) { result = draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY) })
	testing.expect_value(t, result, draw.Replay_Result.Drawn)
	diff, ink_a, ink_s := compare(atlas_img, slug_img, 0, 0, SIZE.x, SIZE.y)
	testing.expect(t, ink_a > 1 && ink_s > 1 && diff < 5)
}

// A lost device: the next frame recreates the textures and uploads the glyph pages again.
@(test)
slug_survives_device_loss :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Slug) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	before := frame(f, paragraph)
	render.simulate_device_loss(&f.r)
	after := frame(f, paragraph)
	diff, ink, _ := compare(before, after, 0, 0, SIZE.x, SIZE.y)
	testing.expect(t, ink > 1)
	testing.expectf(t, diff < 0.01, "after the loss the text differs by %.3f", diff)
}

// Both renderers on one font state: the atlas still draws what Slug does not (here a color glyph).
@(test)
slug_leaves_emoji_to_the_atlas :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f, .Slug) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	img := frame(f, proc(f: ^Fx) { draw.text(&f.dc, f.ui, 32, {4, 40}, BLACK, "\U0001F600 a") })
	colored := 0
	for y in 0 ..< 60 {
		for x in 0 ..< 50 {
			p := px(img, x, y)
			if abs(p.x - p.z) > 60 { colored += 1 }
		}
	}
	testing.expect(t, colored > 50, "the emoji is not in color")
}
