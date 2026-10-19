// Pixel tests of the cost-saving paths of filters (WARP, both blend spaces, both filter precisions): blurs on reduced
// images against the exact gaussian, kept filter results against drawn ones (hits, whole-pixel moves, invalidation),
// color matrices applied by the composite, kept backdrops, pooled textures reused without clearing, the per-step GPU
// profile.   odin test tests/gpufx -vet
package gpufx_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{160, 160}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file", thread_local) current_space: render.Blend_Space
@(private = "file", thread_local) current_format: render.Target_Format

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = current_space) { return false }
	draw.init(&f.dc, &f.r, &f.fonts)
	render.set_filter_precision(&f.r, current_format)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r) }

@(private = "file", thread_local) cur_body: proc(dc: ^draw.Context)

@(private = "file")
frame :: proc(f: ^Fx, body: proc(dc: ^draw.Context), clear := [4]f32{0, 0, 0, 1}) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, clear)
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
dec :: proc(c: f32) -> f32 { return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) }

// Coverage (0..1) of a white-on-black frame pixel.
@(private = "file")
cov :: proc(img: []u8, x, y: int) -> f32 {
	v := f32(px(img, x, y)[0]) / 255
	return current_space == .Srgb ? v : dec(v)
}

// Largest difference between two frames, in 8-bit levels.
@(private = "file")
max_diff :: proc(a, b: []u8) -> int {
	d := 0
	for i in 0 ..< len(a) { d = max(d, abs(int(a[i]) - int(b[i]))) }
	return d
}

// The exact blur of a white square [x0, x1) x [y0, y1) at a pixel center: a product of differences of erf.
@(private = "file")
gauss_box :: proc(x, y: f32, x0, y0, x1, y1, sigma: f32) -> f32 {
	k := 1 / (sigma * math.SQRT_TWO)
	gx := 0.5 * (f32(math.erf(f64((x1 - x) * k))) - f32(math.erf(f64((x0 - x) * k))))
	gy := 0.5 * (f32(math.erf(f64((y1 - y) * k))) - f32(math.erf(f64((y0 - y) * k))))
	return gx * gy
}

@(private = "file", thread_local) current_sigma: f32

// Each configuration: both blend spaces, both filter precisions.
@(private = "file")
each_config :: proc(t: ^testing.T, body: proc(t: ^testing.T, f: ^Fx)) {
	for space in render.Blend_Space {
		for format in render.Target_Format {
			current_space, current_format = space, format
			f: Fx
			if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
			body(t, &f)
			close(&f)
		}
	}
}

// Blurs above the full-resolution limit run on an image reduced by 2, 4, 8 (one pass) and come back through the
// composite's bilinear sampling: within 2.5 % of coverage of the exact gaussian everywhere, and 0.6 % on average.
@(test)
reduced_blurs_stay_close_to_the_gaussian :: proc(t: ^testing.T) {
	each_config(t, proc(t: ^testing.T, f: ^Fx) {
		for sigma in ([]f32{3, 6, 11, 18, 30}) {
			current_sigma = sigma
			img := frame(f, proc(dc: ^draw.Context) {
				fl := [1]draw.Filter{draw.filter_blur(current_sigma)}
				draw.push_effects(dc, {{64, 64}, {96, 96}}, draw.Layer_Effects{alpha = 1, filters = fl[:]})
				draw.rect(dc, {{64, 64}, {96, 96}}, draw.WHITE)
				draw.pop_layer(dc)
			})
			worst, sum: f32
			for y in 0 ..< SIZE.y {
				for x in 0 ..< SIZE.x {
					d := abs(cov(img, x, y) - gauss_box(f32(x) + 0.5, f32(y) + 0.5, 64, 64, 96, 96, sigma))
					worst = max(worst, d)
					sum += d
				}
			}
			mean := sum / f32(SIZE.x * SIZE.y)
			testing.expectf(t, worst < 0.025 && mean < 0.006, "%v %v blur(%v): max %v, mean %v of coverage from the gaussian", current_space, current_format, sigma, worst, mean)
		}
	})
}

@(private = "file", thread_local) scene_shift: draw.Vec2
@(private = "file", thread_local) scene_key: u64
@(private = "file", thread_local) scene_cache: bool
@(private = "file", thread_local) scene_filters: []draw.Filter
@(private = "file", thread_local) scene_blend: draw.Blend_Mode
@(private = "file", thread_local) drawn: int
@(private = "file", thread_local) scene_under: u64

// A card with a blurred drop shadow and a color filter, at scene_shift; its content changes with scene_key.
@(private = "file")
card :: proc(dc: ^draw.Context) {
	draw.rect(dc, {{0, 0}, {160, 80}}, draw.srgb(0.9, 0.85, 0.3))
	draw.rect(dc, {{0, 80}, {160, 160}}, draw.srgb(0.2, 0.4, 0.8))
	o := scene_shift
	r := draw.Rect{o + {40, 40}, o + {100, 90}}
	fx := draw.Layer_Effects{alpha = 0.9, filters = scene_filters, blend = scene_blend}
	if scene_cache { fx.cache_id, fx.cache_key, fx.cache_anchor, fx.cache_under = 7, scene_key, o, scene_under }
	if draw.push_effects(dc, r, fx) {
		drawn += 1
		c := scene_key == 1 ? draw.srgb(0.8, 0.2, 0.1) : draw.srgb(0.1, 0.7, 0.3)
		draw.rect(dc, draw.rect_pad(r, -4), c, 8)
		draw.rect(dc, {o + {50, 55}, o + {90, 65}}, draw.WHITE, 3)
	}
	draw.pop_layer(dc)
}

// A kept result is composited instead of the content being drawn, and gives the same pixels as drawing it; whole-pixel
// moves of the anchor reuse it; a new key, other filters or a fractional move draw it again.
@(test)
kept_layers_match_drawn_ones :: proc(t: ^testing.T) {
	each_config(t, proc(t: ^testing.T, f: ^Fx) {
		base := []draw.Filter{draw.filter_drop_shadow({4, 6}, 5, {0, 0, 0, 0.6}), draw.filter_blur(1.5), draw.filter_sepia(0.7)}
		scene_filters, scene_blend, scene_key, scene_shift = base, .Normal, 1, {}
		scene_cache = false
		want := frame(f, card)
		scene_cache = true
		drawn = 0
		a := frame(f, card)   // asked once: drawn, not kept
		b := frame(f, card)   // asked twice in a row: drawn and kept
		c := frame(f, card)   // kept result
		testing.expectf(t, drawn == 2, "%v %v: content drawn twice, then kept (drawn %d)", current_space, current_format, drawn)
		s := draw.layer_cache_stats(&f.dc)
		testing.expectf(t, s.hits == 1 && s.entries == 1, "one hit: %v", s)
		testing.expectf(t, max_diff(a, want) <= 1 && max_diff(b, want) <= 1 && max_diff(c, want) <= 1, "kept = drawn: %d %d %d", max_diff(a, want), max_diff(b, want), max_diff(c, want))

		// a whole-pixel move: the kept result, moved (the content would be drawn moved by as much)
		scene_shift = {13, -7}
		scene_cache = false
		want_moved := frame(f, card)
		scene_cache = true
		drawn = 0
		moved := frame(f, card)
		testing.expectf(t, drawn == 0, "a whole-pixel move reuses the kept result")
		testing.expectf(t, max_diff(moved, want_moved) <= 1, "moved kept result = drawn moved: %d", max_diff(moved, want_moved))

		// the trailing color matrix is the composite's: another one reuses the kept result
		scene_filters = []draw.Filter{base[0], base[1], draw.filter_hue_rotate(1.2)}
		scene_cache = false
		want_hue := frame(f, card)
		scene_cache = true
		drawn = 0
		_ = frame(f, card)
		hue := frame(f, card)
		testing.expectf(t, drawn == 0, "a new trailing color matrix reuses the kept result (drawn %d)", drawn)
		testing.expectf(t, max_diff(hue, want_hue) <= 1, "hue-rotate on the kept result = drawn: %d", max_diff(hue, want_hue))

		// another key: drawn again, the new content shows
		scene_key = 2
		scene_cache = false
		want_key := frame(f, card)
		scene_cache = true
		drawn = 0
		k := frame(f, card)
		testing.expectf(t, drawn == 1 && max_diff(k, want_key) <= 1, "a new key draws again (drawn %d, diff %d)", drawn, max_diff(k, want_key))

		// other filters run by passes: drawn again
		scene_filters = []draw.Filter{draw.filter_drop_shadow({4, 6}, 9, {0, 0, 0, 0.6}), base[1], base[2]}
		drawn = 0
		_ = frame(f, card)
		testing.expectf(t, drawn == 1, "another shadow draws again")

		// a fractional move: drawn again
		scene_filters = base
		for _ in 0 ..< 3 { _ = frame(f, card) }
		scene_shift = {13.5, -7}
		drawn = 0
		_ = frame(f, card)
		testing.expectf(t, drawn == 1, "a fractional move draws again")

		// with a blend mode: the kept result blends with what is under it this frame
		scene_shift, scene_filters, scene_blend = {}, base, .Multiply
		scene_cache = false
		want_blend := frame(f, card)
		scene_cache = true
		for _ in 0 ..< 3 { _ = frame(f, card) }
		drawn = 0
		bl := frame(f, card)
		testing.expectf(t, drawn == 0 && max_diff(bl, want_blend) <= 1, "kept result through multiply = drawn (drawn %d, diff %d)", drawn, max_diff(bl, want_blend))
		// what lies under is known too: the blended pixels are kept, no copy of what is under
		scene_under = 1
		for _ in 0 ..< 3 { _ = frame(f, card) }
		drawn = 0
		blr := frame(f, card)
		copies := 0
		for op in f.dc.ops { if op.kind == .Copy { copies += 1 } }
		testing.expectf(t, drawn == 0 && copies == 0 && max_diff(blr, want_blend) <= 1, "kept blended pixels = drawn (drawn %d, copies %d, diff %d)", drawn, copies, max_diff(blr, want_blend))
		scene_under = 0

		// nothing kept with caching off; kept textures go back to the pool
		draw.set_layer_cache(&f.dc, 0)
		drawn = 0
		_ = frame(f, card)
		testing.expectf(t, drawn == 1 && render.kept_targets_bytes(&f.r) == 0, "cache off: drawn, nothing kept (%d bytes)", render.kept_targets_bytes(&f.r))
	})
}

// A layer kept while partly visible is drawn whole (small enough), so scrolling more of it into view still matches.
@(test)
kept_layers_are_drawn_whole :: proc(t: ^testing.T) {
	each_config(t, proc(t: ^testing.T, f: ^Fx) {
		scene_filters, scene_blend, scene_key, scene_cache = []draw.Filter{draw.filter_blur(3)}, .Normal, 1, true
		scene_shift = {-60, 0}   // the card half off the frame
		for _ in 0 ..< 3 { _ = frame(f, card) }
		scene_shift = {-20, 0}
		drawn = 0
		got := frame(f, card)
		scene_cache = false
		want := frame(f, card)
		testing.expectf(t, drawn == 1, "moved into view: the kept result was drawn whole (drawn %d)", drawn - 1)
		testing.expectf(t, max_diff(got, want) <= 1, "and matches: %d", max_diff(got, want))
	})
}

@(private = "file", thread_local) bd_key: u64
@(private = "file", thread_local) bd_cache: bool

@(private = "file")
glass :: proc(dc: ^draw.Context) {
	for i in 0 ..< 8 {
		x := f32(i) * 20
		draw.rect(dc, {{x, 0}, {x + 10, 160}}, bd_key == 1 ? draw.srgb(1, 0.2, 0.2) : draw.srgb(0.2, 1, 0.2))
	}
	fl := []draw.Filter{draw.filter_blur(14), draw.filter_saturate(1.8)}
	r := draw.Rect{{30, 40}, {130, 120}}
	if bd_cache {
		draw.backdrop(dc, r, {12, 12, 12, 12}, fl, cache_id = 3, cache_key = bd_key, cache_anchor = r.min)
	} else {
		draw.backdrop(dc, r, {12, 12, 12, 12}, fl)
	}
	draw.rect(dc, r, {1, 1, 1, 0.2}, 12)
}

// A kept backdrop (what lies under it unchanged) gives the pixels of a captured one, without a copy or a pass.
@(test)
kept_backdrops_match_captured_ones :: proc(t: ^testing.T) {
	each_config(t, proc(t: ^testing.T, f: ^Fx) {
		bd_key, bd_cache = 1, false
		want := frame(f, glass)
		bd_cache = true
		for _ in 0 ..< 3 { _ = frame(f, glass) }
		got := frame(f, glass)
		passes, copies := 0, 0
		for op in f.dc.ops {
			if op.kind == .Pass { passes += 1 }
			if op.kind == .Copy { copies += 1 }
		}
		testing.expectf(t, passes == 0 && copies == 0, "kept backdrop: no pass, no copy (%d, %d)", passes, copies)
		testing.expectf(t, max_diff(got, want) <= 1, "kept backdrop = captured: %d", max_diff(got, want))
		// what lies under changed (a new key): captured again
		bd_key = 2
		changed := frame(f, glass)
		testing.expect(t, max_diff(changed, got) > 20, "a new key captures what is under it now")
	})
}

// Pooled textures are not cleared before a pass: what a previous user left past a pass's region is never read.
@(test)
stale_texels_are_never_read :: proc(t: ^testing.T) {
	each_config(t, proc(t: ^testing.T, f: ^Fx) {
		draw.set_layer_cache(&f.dc, 0)
		for _ in 0 ..< 2 {
			_ = frame(f, proc(dc: ^draw.Context) {
				fl := [1]draw.Filter{draw.filter_blur(2)}
				draw.push_effects(dc, {{0, 0}, {160, 160}}, draw.Layer_Effects{alpha = 1, filters = fl[:]})
				draw.rect(dc, {{0, 0}, {160, 160}}, draw.WHITE)
				draw.pop_layer(dc)
			})
		}
		img := frame(f, proc(dc: ^draw.Context) {
			fl := [2]draw.Filter{draw.filter_blur(3), draw.filter_drop_shadow({2, 2}, 2, {1, 1, 1, 1})}
			draw.push_effects(dc, {{20, 20}, {28, 28}}, draw.Layer_Effects{alpha = 1, filters = fl[:]})
			draw.rect(dc, {{20, 20}, {28, 28}}, draw.Color{1, 0, 0, 1})
			draw.pop_layer(dc)
		})
		worst := 0
		for y in 0 ..< SIZE.y {
			for x in 0 ..< SIZE.x {
				if x < 50 && y < 50 { continue }
				p := px(img, x, y)
				worst = max(worst, p[0], p[1], p[2])
			}
		}
		testing.expectf(t, worst == 0, "%v %v: nothing past the small layer's reach (got %d)", current_space, current_format, worst)
	})
}

// The per-step profile counts the steps of a frame and gives them times that add up to at most the frame's.
@(test)
gpu_profile_counts_steps :: proc(t: ^testing.T) {
	current_space, current_format = .Srgb, .Unorm8
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	render.set_gpu_profile(&f.r, true)
	draw.set_layer_cache(&f.dc, 0)
	p: render.Gpu_Profile
	ok := false
	for _ in 0 ..< 12 {
		_ = frame(&f, proc(dc: ^draw.Context) {
			fl := [2]draw.Filter{draw.filter_blur(20), draw.filter_grayscale(1)}
			draw.push_effects(dc, {{20, 20}, {120, 120}}, draw.Layer_Effects{alpha = 1, filters = fl[:]})
			draw.rect(dc, {{20, 20}, {120, 120}}, draw.WHITE)
			draw.pop_layer(dc)
		})
		p, ok = render.gpu_profile(&f.r)
	}
	if !ok { return }   // no timestamps on this device
	// blur(20) with the limit at 8: a reduction by 4 in one pass, two blur passes; grayscale goes to the composite
	testing.expectf(t, p.steps[.Clear].count == 1 && p.steps[.Downsample].count == 1 && p.steps[.Blur].count == 2 && p.steps[.Color].count == 0, "steps: %v", p.steps)
	testing.expectf(t, p.steps[.Draw_Layer].count == 1 && p.steps[.Draw_Frame].count >= 1, "draw runs: %v", p.steps)
	sum: f32
	for s in p.steps { sum += s.ms }
	testing.expectf(t, sum <= p.total_ms * 1.01 + 0.01, "steps %v ms within the frame's %v ms", sum, p.total_ms)
}
