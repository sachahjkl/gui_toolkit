// Retained drawing (draw.Picture): a replayed picture draws exactly what direct drawing draws, slots move content
// without recording, partial re-recording, culling, the memory budget (eviction) and a device loss. Offscreen renderer
// (WARP), both blend spaces.   odin test tests/retained -vet
package retained_test

import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

N :: 128
SIZE :: [2]int{N, N}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
	tex:   render.Texture,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	font.init(&f.fonts)
	draw.init(&f.dc, &f.r, &f.fonts)
	ok: bool
	f.ui, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	f.tex = make_image(&f.r)
	return ok && f.tex != 0
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); font.destroy(&f.fonts); render.destroy(&f.r) }

@(private = "file")
make_image :: proc(r: ^render.Renderer) -> render.Texture {
	t := render.create_texture_rgba(r, 16, 16)
	fill_image(r, t)
	return t
}

@(private = "file")
fill_image :: proc(r: ^render.Renderer, t: render.Texture) {
	px := make([]u8, 16 * 16 * 4, context.temp_allocator)
	for y in 0 ..< 16 {
		for x in 0 ..< 16 {
			o := (y * 16 + x) * 4
			px[o], px[o + 1], px[o + 2], px[o + 3] = u8(x * 16), u8(y * 16), 200, (x + y) % 3 == 0 ? 128 : 255
		}
	}
	render.update_texture_rgba(r, t, 0, 0, 16, 16, px)
}

// Everything a picture can hold: shapes, borders, soft shapes, text, an image, a gradient, a shadow, nested clips of
// every kind, a nested rotated transform, an alpha.
@(private = "file")
scene :: proc(f: ^Fx) {
	dc := &f.dc
	draw.rect(dc, {{4, 4}, {60, 40}}, draw.hex(0x3b5bdbff), 8)
	draw.rect(dc, {{4, 4}, {60, 40}}, draw.hex(0xf59f00ff), 8, 2)
	draw.rect(dc, {{70, 6}, {120, 30}}, draw.hex(0x00000060), 6, 0, 4)
	draw.text(dc, f.ui, 13, {8, 30}, draw.hex(0xffffffff), "Hello 123")
	draw.image(dc, f.tex, {{70, 40}, {102, 72}}, {}, draw.WHITE, 5)
	// color glyphs (a color page: batches switch between gray and color pages) and shaped Arabic (system fallback)
	draw.text(dc, f.ui, 14, {104, 54}, draw.hex(0x000000ff), "\U0001F600")
	draw.text(dc, f.ui, 10, {103, 76}, draw.hex(0x101010ff), "\u0633\u0644\u0627\u0645")
	draw.gradient(dc, {{4, 48}, {64, 72}}, draw.Gradient{kind = .Linear, start = {0, 0}, end = {60, 0},
		stops = {{color = draw.hex(0xff0000ff), pos = 0}, {color = draw.hex(0x0000ffff), pos = 1}}}, {6, 6, 6, 6})
	draw.box_shadow(dc, {{12, 84}, {40, 108}}, {4, 4, 4, 4}, 3, draw.hex(0x000000a0), {{10, 80}, {38, 104}}, {4, 4, 4, 4})
	draw.push_clip(dc, {{50, 80}, {124, 124}})
	draw.push_clip_rounded(dc, {{52, 82}, {122, 122}}, {12, 12, 12, 12})
	draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.4), {87, 102}))
	draw.rect(dc, {{60, 90}, {114, 114}}, draw.hex(0x2f9e44ff), 4)
	draw.push_clip_ellipse(dc, {87, 102}, {20, 10})
	draw.rect(dc, {{60, 90}, {114, 114}}, draw.hex(0xe03131ff))
	draw.pop_clip(dc)
	draw.text(dc, f.ui, 11, {64, 100}, draw.hex(0x000000ff), "turned \U0001F44D")
	draw.pop_transform(dc)
	draw.pop_clip(dc)
	draw.pop_clip(dc)
	draw.push_alpha(dc, 0.5)
	draw.push_clip_polygon(dc, {{4, 112}, {30, 124}, {44, 112}})
	draw.rect(dc, {{0, 108}, {48, 128}}, draw.hex(0x7048e8ff))
	draw.pop_clip(dc)
	draw.pop_alpha(dc)
}

Mode :: enum { Direct, Replay }

@(private = "file")
frame :: proc(f: ^Fx, pic: ^draw.Picture, mode: Mode, m: draw.Affine, alpha: f32 = 1, outer_clip := false) -> []u8 {
	draw.begin_frame(&f.dc, {N, N})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	if outer_clip { draw.push_clip_rounded(&f.dc, {{10, 10}, {118, 118}}, {20, 20, 20, 20}) }
	if alpha < 1 { draw.push_alpha(&f.dc, alpha) }
	switch mode {
	case .Direct:
		draw.push_transform(&f.dc, m)
		scene(f)
		draw.pop_transform(&f.dc)
	case .Replay:
		res := draw.replay(&f.dc, pic, m)
		if res == .Stale {
			draw.picture_begin(&f.dc, pic, draw.affine_scale_factor(m))
			scene(f)
			draw.picture_end(&f.dc)
			res = draw.replay(&f.dc, pic, m)
		}
	}
	if alpha < 1 { draw.pop_alpha(&f.dc) }
	if outer_clip { draw.pop_clip(&f.dc) }
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
diff :: proc(a, b: []u8) -> (worst, count: int) {
	for i in 0 ..< len(a) {
		d := abs(int(a[i]) - int(b[i]))
		worst = max(worst, d)
		if d > 0 { count += 1 }
	}
	return
}

@(private = "file")
record :: proc(f: ^Fx, pic: ^draw.Picture) {
	draw.picture_begin(&f.dc, pic)
	scene(f)
	draw.picture_end(&f.dc)
}

@(test)
replay_is_identical_to_direct_drawing :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
		defer close(&f)
		pic: draw.Picture
		defer draw.picture_destroy(&f.dc, &pic)
		// glyphs are rasterized while recording: draw once directly so both see the same atlas
		_ = frame(&f, nil, .Direct, draw.AFFINE_IDENTITY)
		record(&f, &pic)
		color_batches := 0
		for bb in pic.batch_bounds { if bb.color >= 0 { color_batches += 1 } }
		testing.expect(t, color_batches > 0 && len(pic.pages) >= 2, "the picture holds glyphs of a gray and a color page")
		cases := []struct { name: string, m: draw.Affine, alpha: f32, clip: bool, exact: bool }{
			{"identity", draw.AFFINE_IDENTITY, 1, false, true},
			{"integer translation", draw.affine_translate({7, -5}), 1, false, true},
			{"alpha", draw.AFFINE_IDENTITY, 0.5, false, true},
			{"inside a rounded clip", draw.affine_translate({3, 2}), 1, true, true},
			{"rotated", draw.affine_around(draw.affine_rotate(0.3), {64, 64}), 1, false, false},
			{"skewed", draw.affine_skew(0.2, 0.1), 1, false, false},
		}
		for c in cases {
			a := frame(&f, nil, .Direct, c.m, c.alpha, c.clip)
			b := frame(&f, &pic, .Replay, c.m, c.alpha, c.clip)
			worst, count := diff(a, b)
			if c.exact {
				testing.expectf(t, worst == 0, "%v, %s: replay differs from direct drawing (%d bytes, worst %d)", space, c.name, count, worst)
			} else {
				// the same pixels up to the order of floating point operations (composed matrices)
				testing.expectf(t, worst <= 2 && count < len(a) / 100, "%v, %s: replay differs (%d bytes, worst %d)", space, c.name, count, worst)
			}
		}
		testing.expect(t, len(f.dc.replays) == 1 && len(f.dc.insts) == 0, "a replay draws no immediate instance")
	}
}

@(test)
text_scale_makes_a_picture_stale :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer close(&f)
	pic: draw.Picture
	defer draw.picture_destroy(&f.dc, &pic)
	record(&f, &pic)
	testing.expect(t, !draw.picture_stale(&f.dc, &pic, draw.affine_scale({1.05, 1.05})), "within the raster tolerance: the same glyphs")
	testing.expect(t, draw.picture_stale(&f.dc, &pic, draw.affine_scale({2, 2})), "at twice the size text is rasterized again")
	// recorded for scale 2: drawn there without going stale, sharp
	draw.picture_begin(&f.dc, &pic, 2)
	scene(&f)
	draw.picture_end(&f.dc)
	testing.expect(t, !draw.picture_stale(&f.dc, &pic, draw.affine_scale({2, 2})))
	// new text rendering settings make it stale
	st := f.fonts.settings
	st.subpixel_steps = st.subpixel_steps == 4 ? 2 : 4
	font.set_settings(&f.fonts, st)
	testing.expect(t, draw.picture_stale(&f.dc, &pic, draw.affine_scale({2, 2})), "after a change of the rendering settings")
	draw.picture_begin(&f.dc, &pic, 2)
	scene(&f)
	draw.picture_end(&f.dc)
	testing.expect(t, !draw.picture_stale(&f.dc, &pic, draw.affine_scale({2, 2})), "recorded with the new settings")
	// clearing the atlas makes it stale
	font.clear_atlas(&f.fonts)
	testing.expect(t, draw.picture_stale(&f.dc, &pic, draw.affine_scale({2, 2})), "after the atlas was cleared")
}

// Tiny atlas pages: reusing a page makes the pictures with glyphs on it stale, and only them; a picture drawn in the
// current frame keeps its page (never reused under it); a picture still valid replays what direct drawing draws.
@(test)
page_reuse_makes_only_its_pictures_stale :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !render.init_offscreen(&f.r, SIZE, warp = true) { testing.fail_now(t, "no D3D11 device (WARP)") }
	st := font.DEFAULT_SETTINGS
	st.page_size, st.max_gray_pages = 256, 2
	font.init(&f.fonts, st)
	draw.init(&f.dc, &f.r, &f.fonts)
	defer close(f)
	ok: bool
	f.ui, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { testing.fail_now(t, "no font") }
	gray_pages :: proc(f: ^Fx) -> int {
		n := 0
		for i in 0 ..< font.atlas_page_count(&f.fonts) { if k, _, _ := font.atlas_page_info(&f.fonts, i); k == .Gray { n += 1 } }
		return n
	}
	a, b: draw.Picture
	defer { draw.picture_destroy(&f.dc, &a); draw.picture_destroy(&f.dc, &b) }
	ALPHABET :: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	draw_b :: proc(f: ^Fx) { draw.text(&f.dc, f.ui, 120, {0, 100}, draw.hex(0x000000ff), "Wg") }
	direct_b :: proc(f: ^Fx) -> []u8 {
		draw.begin_frame(&f.dc, {N, N})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw_b(f)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		return render.read_pixels(&f.r, context.temp_allocator)
	}
	draw.picture_begin(&f.dc, &a)
	draw.text(&f.dc, f.ui, 12, {4, 20}, draw.hex(0x000000ff), "Hello")
	draw.picture_end(&f.dc)
	// fill the first page until a second one is made
	size: f32 = 20
	for gray_pages(f) < 2 && size < 200 {
		draw.begin_frame(&f.dc, {N, N})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.text(&f.dc, f.ui, size, {0, 60}, draw.hex(0x000000ff), ALPHABET)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		size += 1
	}
	testing.expect(t, gray_pages(f) == 2, "a second gray page")
	// b: glyphs too tall for what is left of the first page
	draw.picture_begin(&f.dc, &b)
	draw_b(f)
	draw.picture_end(&f.dc)
	for ra in a.pages { for rb in b.pages { testing.expect(t, ra.page != rb.page, "a and b on different pages") } }
	// b is drawn every frame while other text fills the atlas: the page of a goes
	evictions := font.atlas_evictions(&f.fonts)
	for font.atlas_evictions(&f.fonts) == evictions && size < 400 {
		draw.begin_frame(&f.dc, {N, N})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		testing.expect(t, draw.replay(&f.dc, &b, draw.AFFINE_IDENTITY) == .Drawn, "b drawn")
		draw.text(&f.dc, f.ui, size, {0, 60}, draw.hex(0x000000ff), ALPHABET)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		size += 1
	}
	testing.expect(t, font.atlas_evictions(&f.fonts) > evictions, "a page was reused")
	testing.expect(t, draw.picture_stale(&f.dc, &a, draw.AFFINE_IDENTITY), "its page was reused: a is stale")
	testing.expect(t, !draw.picture_stale(&f.dc, &b, draw.AFFINE_IDENTITY), "b kept its page")
	direct := direct_b(f)
	draw.begin_frame(&f.dc, {N, N})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	res := draw.replay(&f.dc, &b, draw.AFFINE_IDENTITY)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	replayed := render.read_pixels(&f.r, context.temp_allocator)
	worst, count := diff(direct, replayed)
	testing.expectf(t, res == .Drawn && worst == 0, "b replays what direct drawing draws (%d bytes, worst %d)", count, worst)
}

// A picture of cards whose rotations are slots: changing a slot moves the card with no recording.
@(test)
slots_move_content_without_recording :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
		defer close(&f)
		Cards :: struct { f: ^Fx, angle: [4]f32 }
		cards :: proc(c: ^Cards, slots: ^[4]u32) {
			dc := &c.f.dc
			for i in 0 ..< 4 {
				center := draw.Vec2{32 + f32(i % 2) * 64, 32 + f32(i / 2) * 64}
				draw.push_transform(dc, draw.affine_around(draw.affine_rotate(c.angle[i]), center))
				if slots != nil { slots[i] = draw.current_slot(dc) }
				draw.rect(dc, {center - {22, 14}, center + {22, 14}}, draw.hex(0x1971c2ff), 6)
				draw.box_shadow(dc, {center - {22, 14}, center + {22, 14}}, {6, 6, 6, 6}, 2, draw.hex(0x00000080), {center - {22, 14}, center + {22, 14}}, {6, 6, 6, 6})
				draw.text(dc, c.f.ui, 12, center - {14, -4}, draw.hex(0xffffffff), "card")
				draw.pop_transform(dc)
			}
		}
		state := Cards{f = &f, angle = {0.1, 0.2, 0.3, 0.4}}
		pic: draw.Picture
		defer draw.picture_destroy(&f.dc, &pic)
		slots: [4]u32
		draw.picture_begin(&f.dc, &pic)
		cards(&state, &slots)
		draw.picture_end(&f.dc)
		version := pic.version
		for step in 0 ..< 3 {
			for i in 0 ..< 4 { state.angle[i] += 0.37 * f32(step + i) }
			for i in 0 ..< 4 {
				center := draw.Vec2{32 + f32(i % 2) * 64, 32 + f32(i / 2) * 64}
				draw.picture_set_slot(&pic, slots[i], draw.affine_around(draw.affine_rotate(state.angle[i]), center))
			}
			draw.begin_frame(&f.dc, {N, N})
			render.frame_begin(&f.r, {1, 1, 1, 1})
			cards(&state, nil)
			draw.end_frame(&f.dc)
			render.frame_end(&f.r)
			direct := render.read_pixels(&f.r, context.temp_allocator)
			draw.begin_frame(&f.dc, {N, N})
			render.frame_begin(&f.r, {1, 1, 1, 1})
			res := draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY)
			draw.end_frame(&f.dc)
			render.frame_end(&f.r)
			replayed := render.read_pixels(&f.r, context.temp_allocator)
			worst, count := diff(direct, replayed)
			testing.expectf(t, res == .Drawn && worst <= 2 && count < len(direct) / 200, "%v, step %d: moved slots draw what direct drawing does (%d bytes, worst %d)", space, step, count, worst)
		}
		testing.expect(t, pic.version == version, "no recording")
	}
}

// Two pictures in z order with direct drawing between them; one of them recorded again: only it uploads.
@(test)
order_and_partial_recording :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer close(&f)
	a, b: draw.Picture
	defer { draw.picture_destroy(&f.dc, &a); draw.picture_destroy(&f.dc, &b) }
	draw.picture_begin(&f.dc, &a)
	draw.rect(&f.dc, {{10, 10}, {70, 70}}, draw.hex(0xff0000ff))
	draw.picture_end(&f.dc)
	record_b :: proc(f: ^Fx, b: ^draw.Picture, color: u32) {
		draw.picture_begin(&f.dc, b)
		draw.rect(&f.dc, {{50, 50}, {110, 110}}, draw.hex(color))
		draw.picture_end(&f.dc)
	}
	record_b(&f, &b, 0x0000ffff)
	shoot :: proc(f: ^Fx, a, b: ^draw.Picture) -> []u8 {
		draw.begin_frame(&f.dc, {N, N})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.replay(&f.dc, a, draw.AFFINE_IDENTITY)
		draw.rect(&f.dc, {{30, 30}, {90, 90}}, draw.hex(0x00ff00ff))   // direct, between the two
		draw.replay(&f.dc, b, draw.AFFINE_IDENTITY)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		return render.read_pixels(&f.r, context.temp_allocator)
	}
	img := shoot(&f, &a, &b)
	p := proc(img: []u8, x, y: int) -> [3]u8 { o := (y * N + x) * 4; return {img[o], img[o + 1], img[o + 2]} }
	testing.expect(t, p(img, 20, 20) == {255, 0, 0}, "a")
	testing.expect(t, p(img, 40, 40) == {0, 255, 0}, "direct over a")
	testing.expect(t, p(img, 60, 60) == {0, 0, 255}, "b over the direct rect")
	ua := a.uploaded
	record_b(&f, &b, 0xffff00ff)
	img = shoot(&f, &a, &b)
	testing.expect(t, p(img, 60, 60) == {255, 255, 0}, "b recorded again")
	testing.expect(t, a.uploaded == ua && b.uploaded == b.version, "only b uploaded again")
	// culled: outside the frame, nothing uploaded
	c: draw.Picture
	defer draw.picture_destroy(&f.dc, &c)
	draw.picture_begin(&f.dc, &c)
	draw.rect(&f.dc, {{0, 0}, {10, 10}}, draw.hex(0xff0000ff))
	draw.picture_end(&f.dc)
	draw.begin_frame(&f.dc, {N, N})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	res := draw.replay(&f.dc, &c, draw.affine_translate({500, 0}))
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	testing.expect(t, res == .Culled && !c.resident, "culled pictures do not upload")
}

@(test)
budget_evicts_unused_pictures :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
	defer close(&f)
	pics: [4]draw.Picture
	defer for &p in pics { draw.picture_destroy(&f.dc, &p) }
	for &p, i in pics {
		draw.picture_begin(&f.dc, &p)
		for k in 0 ..< 200 { draw.rect(&f.dc, {{f32(k % 20) * 6, f32(k / 20) * 6}, {f32(k % 20) * 6 + 5, f32(k / 20) * 6 + 5}}, draw.hsv(f32(i) / 4, 0.8, 0.9)) }
		draw.picture_end(&f.dc)
	}
	one := 200 * size_of(render.Rect_Inst)
	draw.set_retained_budget(&f.dc, one * 2 + one / 2)   // two pictures fit
	shots: [4][]u8
	for i in 0 ..< 4 {
		draw.begin_frame(&f.dc, {N, N})
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.replay(&f.dc, &pics[i], draw.AFFINE_IDENTITY)
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		shots[i] = render.read_pixels(&f.r, context.temp_allocator)
	}
	resident := 0
	for p in pics { if p.resident { resident += 1 } }
	testing.expectf(t, resident <= 2, "over the budget the least recently drawn are evicted (%d resident)", resident)
	testing.expect(t, !pics[0].resident && pics[3].resident)
	// an evicted picture uploads again from its recording: same pixels
	draw.begin_frame(&f.dc, {N, N})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	draw.replay(&f.dc, &pics[0], draw.AFFINE_IDENTITY)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	again := render.read_pixels(&f.r, context.temp_allocator)
	worst, _ := diff(again, shots[0])
	testing.expect(t, worst == 0 && pics[0].resident, "evicted then drawn again: identical")
}

@(test)
device_loss_recovers :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP) or font") }
		defer close(&f)
		pic: draw.Picture
		defer draw.picture_destroy(&f.dc, &pic)
		_ = frame(&f, nil, .Direct, draw.AFFINE_IDENTITY)
		record(&f, &pic)
		before := frame(&f, &pic, .Replay, draw.AFFINE_IDENTITY)
		gen := f.r.device_generation
		render.simulate_device_loss(&f.r)
		// the next frame recreates the device; texture contents are gone: the owner uploads its image again, the
		// atlas pages upload again from the CPU copy (the picture's glyphs are where they were: not stale)
		draw.begin_frame(&f.dc, {N, N})
		testing.expect(t, !render.device_lost(&f.r) && f.r.device_generation == gen + 1, "recovered at the start of the frame")
		testing.expect(t, !draw.picture_stale(&f.dc, &pic, draw.AFFINE_IDENTITY), "the atlas pages come back: the picture is not stale")
		render.frame_begin(&f.r, {1, 1, 1, 1})
		draw.end_frame(&f.dc)
		render.frame_end(&f.r)
		fill_image(&f.r, f.tex)   // same handle, contents uploaded again
		version := pic.version
		after := frame(&f, &pic, .Replay, draw.AFFINE_IDENTITY)
		worst, count := diff(before, after)
		testing.expectf(t, worst == 0, "%v: after the device loss the same pixels (%d bytes, worst %d)", space, count, worst)
		testing.expect(t, pic.version == version, "replayed without recording")
	}
}
