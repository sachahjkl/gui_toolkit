// Pixel tests of filters, blend modes, backdrops and clip shapes on an offscreen renderer (WARP, the software
// rasterizer: no GPU or window needed). Expected values follow the formulas of CSS Filter Effects 1 and Compositing 1
// on sRGB values, as browsers compute them.   odin test tests/effects -vet
package effects_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{128, 128}

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
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r) }

@(private = "file")
frame :: proc(f: ^Fx, body: proc(dc: ^draw.Context), clear := [4]f32{1, 1, 1, 1}) -> []u8 {
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
close_rgb :: proc(a, b: [4]int, tol := 2) -> bool {
	for i in 0 ..< 3 { if abs(a[i] - b[i]) > tol { return false } }
	return true
}

@(private = "file")
dec :: proc(c: f32) -> f32 { return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4) }

@(private = "file")
to8 :: proc(c: [3]f32) -> [4]int {
	return {int(math.round(clamp(c.r, 0, 1) * 255)), int(math.round(clamp(c.g, 0, 1) * 255)), int(math.round(clamp(c.b, 0, 1) * 255)), 255}
}

// The color matrix of a filter applied to a straight sRGB color (the reference).
@(private = "file")
apply :: proc(m: draw.Color_Matrix, c: [4]f32) -> [4]f32 {
	o: [4]f32
	for row in 0 ..< 4 {
		o[row] = clamp(m[row * 5] * c.r + m[row * 5 + 1] * c.g + m[row * 5 + 2] * c.b + m[row * 5 + 3] * c.a + m[row * 5 + 4], 0, 1)
	}
	return o
}

// An opaque sRGB color (0..255) as draw's linear color.
@(private = "file")
srgb8 :: proc(r, g, b: int) -> draw.Color { return draw.srgb(f32(r) / 255, f32(g) / 255, f32(b) / 255) }

BASE :: [3]int{200, 120, 40}

@(private = "file", thread_local)
current_filters: []draw.Filter

@(test)
color_filters_match_the_spec :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	Case :: struct { name: string, filters: []draw.Filter }
	cases := []Case{
		{"brightness(0.5)", {draw.filter_brightness(0.5)}},
		{"brightness(1.6)", {draw.filter_brightness(1.6)}},
		{"contrast(1.5)", {draw.filter_contrast(1.5)}},
		{"contrast(0.3)", {draw.filter_contrast(0.3)}},
		{"grayscale(1)", {draw.filter_grayscale(1)}},
		{"grayscale(0.4)", {draw.filter_grayscale(0.4)}},
		{"sepia(1)", {draw.filter_sepia(1)}},
		{"saturate(2.5)", {draw.filter_saturate(2.5)}},
		{"saturate(0)", {draw.filter_saturate(0)}},
		{"hue-rotate(90deg)", {draw.filter_hue_rotate(math.PI / 2)}},
		{"hue-rotate(200deg)", {draw.filter_hue_rotate(200 * math.PI / 180)}},
		{"invert(1)", {draw.filter_invert(1)}},
		{"invert(0.3)", {draw.filter_invert(0.3)}},
		// clamped between steps: brightness(3) saturates, brightness(0.5) then halves the clamped value
		{"brightness(3) brightness(0.5)", {draw.filter_brightness(3), draw.filter_brightness(0.5)}},
		{"sepia(1) hue-rotate(180deg) contrast(1.2)", {draw.filter_sepia(1), draw.filter_hue_rotate(math.PI), draw.filter_contrast(1.2)}},
	}
	base := [4]f32{f32(BASE.r) / 255, f32(BASE.g) / 255, f32(BASE.b) / 255, 1}
	for cs in cases {
		current_filters = cs.filters
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.push_effects(dc, {{16, 16}, {112, 112}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
			draw.rect(dc, {{16, 16}, {112, 112}}, srgb8(BASE.r, BASE.g, BASE.b))
			draw.pop_layer(dc)
		})
		want := base
		for fl in cs.filters { want = apply(fl.cm, want) }
		exp := to8(want.rgb)
		got := px(img, 64, 64)
		testing.expectf(t, close_rgb(got, exp, 2), "%s: got %v, want %v", cs.name, got, exp)
		testing.expectf(t, close_rgb(px(img, 4, 4), {255, 255, 255, 255}, 0), "%s: outside the layer untouched", cs.name)
	}
	// opacity() as a filter: half over white
	current_filters = {draw.filter_opacity(0.5)}
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_effects(dc, {{16, 16}, {112, 112}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
		draw.rect(dc, {{16, 16}, {112, 112}}, srgb8(0, 0, 0))
		draw.pop_layer(dc)
	})
	// half black over white, blended in linear light by the renderer
	half := int(math.round((1.055 * math.pow(f32(0.5), 1 / 2.4) - 0.055) * 255))
	testing.expectf(t, close_rgb(px(img, 64, 64), {half, half, half, 255}, 2), "opacity(0.5): %v", px(img, 64, 64))
}

// Linear coverage (0..1) of a white-on-black frame pixel.
@(private = "file")
cov :: proc(img: []u8, x, y: int) -> f32 { return dec(f32(px(img, x, y)[0]) / 255) }

@(test)
blur_conserves_energy_and_is_symmetric :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	sigmas := []f32{1.5, 4, 14}   // 14: computed on a reduced image (above the sigma limit)
	for s in sigmas {
		current_filters = {draw.filter_blur(s)}
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.push_effects(dc, {{56, 56}, {72, 72}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
			draw.rect(dc, {{56, 56}, {72, 72}}, draw.WHITE)
			draw.pop_layer(dc)
		}, {0, 0, 0, 1})
		total: f32
		for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x { total += cov(img, x, y) } }
		// the square holds 256 px of coverage; blurring spreads it without adding or losing any (8-bit rounding aside)
		testing.expectf(t, abs(total - 256) < 256 * 0.04, "blur(%v): energy %v, want 256", s, total)
		worst: f32
		for y in 0 ..< SIZE.y {
			for x in 0 ..< SIZE.x / 2 {
				worst = max(worst, abs(cov(img, x, y) - cov(img, SIZE.x - 1 - x, y)), abs(cov(img, y, x) - cov(img, y, SIZE.x - 1 - x)))
			}
		}
		testing.expectf(t, worst < 0.02, "blur(%v): mirror images differ by %v", s, worst)
		// the center of a 16 px square: erf(8 / (sigma sqrt 2)) squared
		e := f32(math.erf(f64(8 / (s * math.SQRT_TWO))))
		testing.expectf(t, abs(cov(img, 64, 64) - e * e) < 0.03, "blur(%v): center %v, want %v", s, cov(img, 64, 64), e * e)
		testing.expectf(t, cov(img, 56 - int(math.ceil(s)) - 1, 64) > 0.002, "blur(%v): spreads past the square", s)
	}
	// a gaussian's profile: one sigma inside the edge of a large area, the standard values of erf
	current_filters = {draw.filter_blur(4)}
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_effects(dc, {{0, 0}, {64, 128}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
		draw.rect(dc, {{-40, -40}, {64, 168}}, draw.WHITE)
		draw.pop_layer(dc)
	}, {0, 0, 0, 1})
	// the edge is at x = 64: pixel centers 63.5 - 4 and 64.5 + 4 are one sigma away (0.841 / 0.159 of coverage). The
	// layer's bounds cut the content at x = 0 - 12 (they are what the caller promised).
	testing.expectf(t, abs(cov(img, 59, 64) - 0.841) < 0.04, "1 sigma inside: %v", cov(img, 59, 64))
	testing.expectf(t, abs(cov(img, 68, 64) - 0.159) < 0.04, "1 sigma outside: %v", cov(img, 68, 64))
}

@(test)
drop_shadow_is_the_blurred_alpha_under_the_content :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	current_filters = {draw.filter_drop_shadow({20, 10}, 0, draw.Color{0, 0, 1, 1})}
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_effects(dc, {{20, 20}, {60, 60}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
		draw.rect(dc, {{20, 20}, {60, 60}}, draw.Color{1, 0, 0, 1})
		draw.pop_layer(dc)
	})
	testing.expectf(t, close_rgb(px(img, 40, 40), {255, 0, 0, 255}), "content on top: %v", px(img, 40, 40))
	testing.expectf(t, close_rgb(px(img, 70, 50), {0, 0, 255, 255}), "shadow moved by (20, 10): %v", px(img, 70, 50))
	testing.expectf(t, close_rgb(px(img, 70, 25), {255, 255, 255, 255}), "nothing above the shadow: %v", px(img, 70, 25))
	testing.expectf(t, close_rgb(px(img, 10, 10), {255, 255, 255, 255}), "nothing elsewhere: %v", px(img, 10, 10))

	// blurred and translucent: the shadow's alpha is the color's times the blurred coverage
	current_filters = {draw.filter_drop_shadow({0, 30}, 3, draw.Color{0, 0, 0, 0.5})}
	img2 := frame(&f, proc(dc: ^draw.Context) {
		draw.push_effects(dc, {{20, 20}, {108, 60}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
		draw.rect(dc, {{20, 20}, {108, 60}}, draw.Color{1, 0, 0, 1})
		draw.pop_layer(dc)
	})
	// deep inside the shadow (not under the content): half black, composited over white by the renderer (in linear
	// light, as everything it blends: 188, where an sRGB compositor gives 128)
	p := px(img2, 64, 80)
	testing.expectf(t, abs(p[0] - 188) <= 3 && p[0] == p[1] && p[1] == p[2], "half black shadow over white: %v", p)
	testing.expectf(t, px(img2, 64, 92)[0] > px(img2, 64, 85)[0], "softened toward its edge")
}

// Reference of CSS Compositing 1 on straight sRGB values (backdrop b, source s, both opaque).
@(private = "file")
blend_ref :: proc(mode: draw.Blend_Mode, b, s: [3]f32) -> [3]f32 {
	ch :: proc(mode: draw.Blend_Mode, b, s: f32) -> f32 {
		#partial switch mode {
		case .Multiply: return b * s
		case .Screen: return b + s - b * s
		case .Overlay: return ch(.Hard_Light, s, b)
		case .Darken: return min(b, s)
		case .Lighten: return max(b, s)
		case .Color_Dodge: return b == 0 ? 0 : (s == 1 ? 1 : min(1, b / (1 - s)))
		case .Color_Burn: return b == 1 ? 1 : (s == 0 ? 0 : 1 - min(1, (1 - b) / s))
		case .Hard_Light: return s <= 0.5 ? b * 2 * s : ch(.Screen, b, 2 * s - 1)
		case .Soft_Light:
			if s <= 0.5 { return b - (1 - 2 * s) * b * (1 - b) }
			d := b <= 0.25 ? ((16 * b - 12) * b + 4) * b : math.sqrt(b)
			return b + (2 * s - 1) * (d - b)
		case .Difference: return abs(b - s)
		case .Exclusion: return b + s - 2 * b * s
		}
		return s
	}
	lum :: proc(c: [3]f32) -> f32 { return 0.3 * c.r + 0.59 * c.g + 0.11 * c.b }
	clip_color :: proc(c: [3]f32) -> [3]f32 {
		l := lum(c)
		n, x := min(c.r, c.g, c.b), max(c.r, c.g, c.b)
		o := c
		if n < 0 { o = l + (o - l) * l / (l - n) }
		if x > 1 { o = l + (o - l) * (1 - l) / (x - l) }
		return o
	}
	set_lum :: proc(c: [3]f32, l: f32) -> [3]f32 { return clip_color(c + (l - lum(c))) }
	sat :: proc(c: [3]f32) -> f32 { return max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
	set_sat :: proc(c: [3]f32, s: f32) -> [3]f32 {
		mx, mn := max(c.r, c.g, c.b), min(c.r, c.g, c.b)
		if mx <= mn { return {} }
		return (c - mn) * s / (mx - mn)
	}
	#partial switch mode {
	case .Hue: return set_lum(set_sat(s, sat(b)), lum(b))
	case .Saturation: return set_lum(set_sat(b, sat(s)), lum(b))
	case .Color: return set_lum(s, lum(b))
	case .Luminosity: return set_lum(b, lum(s))
	case .Plus_Lighter: return {min(1, b.r + s.r), min(1, b.g + s.g), min(1, b.b + s.b)}
	case .Plus_Darker: return {max(0, b.r + s.r - 1), max(0, b.g + s.g - 1), max(0, b.b + s.b - 1)}
	}
	return {ch(mode, b.r, s.r), ch(mode, b.g, s.g), ch(mode, b.b, s.b)}
}

@(private = "file", thread_local) current_mode: draw.Blend_Mode
@(private = "file", thread_local) current_alpha: f32

BACK :: [3]int{60, 150, 220}
SRC :: [3]int{230, 90, 30}

@(test)
blend_modes_match_the_spec :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	b := [3]f32{f32(BACK.r), f32(BACK.g), f32(BACK.b)} / 255
	s := [3]f32{f32(SRC.r), f32(SRC.g), f32(SRC.b)} / 255
	for mode in draw.Blend_Mode {
		current_mode, current_alpha = mode, 1
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.rect(dc, {{0, 0}, {128, 128}}, srgb8(BACK.r, BACK.g, BACK.b))
			draw.push_effects(dc, {{32, 32}, {96, 96}}, draw.Layer_Effects{alpha = current_alpha, blend = current_mode})
			draw.rect(dc, {{32, 32}, {96, 96}}, srgb8(SRC.r, SRC.g, SRC.b))
			draw.pop_layer(dc)
		})
		exp := to8(blend_ref(mode, b, s))
		testing.expectf(t, close_rgb(px(img, 64, 64), exp, 2), "%v: got %v, want %v", mode, px(img, 64, 64), exp)
		testing.expectf(t, close_rgb(px(img, 8, 8), to8(b), 1), "%v: the backdrop outside is unchanged: %v", mode, px(img, 8, 8))
	}
	// half transparent source (group opacity 0.5): Cs' = B(Cb, Cs), co = 0.5 Cs' + 0.5 Cb (in sRGB)
	current_mode, current_alpha = .Multiply, 0.5
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {128, 128}}, srgb8(BACK.r, BACK.g, BACK.b))
		draw.push_effects(dc, {{32, 32}, {96, 96}}, draw.Layer_Effects{alpha = current_alpha, blend = current_mode})
		draw.rect(dc, {{32, 32}, {96, 96}}, srgb8(SRC.r, SRC.g, SRC.b))
		draw.pop_layer(dc)
	})
	exp := to8(blend_ref(.Multiply, b, s) * 0.5 + b * 0.5)
	testing.expectf(t, close_rgb(px(img, 64, 64), exp, 2), "multiply at 50 %%: got %v, want %v", px(img, 64, 64), exp)
	// blending inside an isolated group (a layer) only sees the group: over its transparent pixels the source is as is
	img2 := frame(&f, proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {128, 128}}, srgb8(BACK.r, BACK.g, BACK.b))
		draw.push_layer(dc, {{0, 0}, {128, 128}}, 1)
		draw.push_effects(dc, {{32, 32}, {96, 96}}, draw.Layer_Effects{alpha = 1, blend = .Multiply})
		draw.rect(dc, {{32, 32}, {96, 96}}, srgb8(SRC.r, SRC.g, SRC.b))
		draw.pop_layer(dc)
		draw.pop_layer(dc)
	})
	testing.expectf(t, close_rgb(px(img2, 64, 64), {SRC.r, SRC.g, SRC.b, 255}, 2), "isolated: the source unblended: %v", px(img2, 64, 64))
}

@(test)
clip_shapes_are_antialiased :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	img := frame(&f, proc(dc: ^draw.Context) {
		draw.push_clip_ellipse(dc, {64, 64}, {50, 25})
		draw.rect(dc, {{0, 0}, {128, 128}}, draw.WHITE)
		draw.pop_clip(dc)
	}, {0, 0, 0, 1})
	testing.expect(t, cov(img, 64, 64) > 0.99 && cov(img, 110, 64) > 0.99, "inside the ellipse")
	testing.expect(t, cov(img, 64, 30) < 0.01 && cov(img, 120, 64) < 0.01 && cov(img, 108, 84) < 0.01, "outside")
	// the edge crosses x = 114 at y = 64 (pixel 113 is centered 0.5 px inside, pixel 114 0.5 px outside)
	e0, e1 := cov(img, 113, 64), cov(img, 114, 64)
	testing.expectf(t, abs(e0 + e1 - 1) < 0.08, "the two pixels around the edge share one pixel of coverage: %v + %v", e0, e1)
	// top edge at y = 39: the pixel row 38.5..39.5 is half covered... rows 38 and 39 share one pixel
	t0, t1 := cov(img, 64, 38), cov(img, 64, 39)
	testing.expectf(t, abs(t0 + t1 - 1) < 0.08 && t0 < 0.6, "top edge: %v + %v", t0, t1)

	// a pentagram: nonzero fills the center, even-odd leaves it empty
	star :: proc(dc: ^draw.Context, evenodd: bool) {
		pts: [5]draw.Vec2
		for i in 0 ..< 5 {
			a := -math.PI / 2 + f32(i) * 4 * math.PI / 5
			pts[i] = {64 + 56 * math.cos(a), 64 + 56 * math.sin(a)}
		}
		draw.push_clip_polygon(dc, pts[:], evenodd)
		draw.rect(dc, {{0, 0}, {128, 128}}, draw.WHITE)
		draw.pop_clip(dc)
	}
	nz := frame(&f, proc(dc: ^draw.Context) { star(dc, false) }, {0, 0, 0, 1})
	eo := frame(&f, proc(dc: ^draw.Context) { star(dc, true) }, {0, 0, 0, 1})
	testing.expect(t, cov(nz, 64, 64) > 0.99, "nonzero: the center is filled")
	testing.expect(t, cov(eo, 64, 64) < 0.01, "even-odd: the center is a hole")
	testing.expect(t, cov(nz, 64, 12) > 0.99 && cov(eo, 64, 12) > 0.99, "a point of the star, both rules")
	testing.expect(t, cov(nz, 8, 8) < 0.01, "outside")
	// a square polygon matches push_clip on the same rect, edges at pixel boundaries
	sq := frame(&f, proc(dc: ^draw.Context) {
		pts := [4]draw.Vec2{{20.5, 20}, {100.5, 20}, {100.5, 90}, {20.5, 90}}
		draw.push_clip_polygon(dc, pts[:])
		draw.rect(dc, {{0, 0}, {128, 128}}, draw.WHITE)
		draw.pop_clip(dc)
	}, {0, 0, 0, 1})
	testing.expectf(t, abs(cov(sq, 20, 50) - 0.5) < 0.06 && abs(cov(sq, 100, 50) - 0.5) < 0.06, "half-pixel edges: %v %v", cov(sq, 20, 50), cov(sq, 100, 50))
	testing.expect(t, cov(sq, 50, 19) < 0.01 && cov(sq, 50, 20) > 0.99, "pixel-aligned edge")
}

@(test)
backdrops_filter_what_is_behind :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	scene :: proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {64, 128}}, draw.Color{1, 0, 0, 1})
		draw.rect(dc, {{64, 0}, {128, 128}}, draw.Color{0, 0, 1, 1})
	}
	current_filters = {draw.filter_blur(6)}
	img := frame(&f, proc(dc: ^draw.Context) {
		scene(dc)
		draw.backdrop(dc, {{32, 32}, {96, 96}}, {12, 12, 12, 12}, current_filters)
		draw.rect(dc, {{40, 40}, {48, 48}}, draw.Color{0, 1, 0, 1})   // content on top of the backdrop
	})
	mid := px(img, 64, 64)
	testing.expectf(t, mid[0] > 90 && mid[2] > 90 && mid[1] < 10, "red and blue mixed at the boundary: %v", mid)
	testing.expectf(t, close_rgb(px(img, 20, 64), {255, 0, 0, 255}, 0) && close_rgb(px(img, 110, 64), {0, 0, 255, 255}, 0), "outside the box unchanged")
	testing.expectf(t, close_rgb(px(img, 36, 64), {255, 0, 0, 255}, 3), "edges repeat (no dark fringe): %v", px(img, 36, 64))
	testing.expectf(t, close_rgb(px(img, 44, 44), {0, 255, 0, 255}, 0), "content drawn after the backdrop is on top")
	testing.expectf(t, close_rgb(px(img, 33, 33), {255, 0, 0, 255}, 0), "rounded corner: outside it the original shows")

	current_filters = {draw.filter_grayscale(1)}
	gray := frame(&f, proc(dc: ^draw.Context) {
		scene(dc)
		draw.backdrop(dc, {{32, 32}, {96, 96}}, {}, current_filters)
	})
	g := px(gray, 40, 64)
	want := int(math.round(0.2126 * 255))
	testing.expectf(t, abs(g[0] - want) <= 2 && g[0] == g[1] && g[1] == g[2], "grayscale(red) = %d: %v", want, g)

	// inside a layer the backdrop is the layer's content; a rotated backdrop is clipped to its rotated rect
	rot := frame(&f, proc(dc: ^draw.Context) {
		scene(dc)
		draw.push_layer(dc, {{0, 0}, {128, 128}}, 1)
		draw.rect(dc, {{0, 0}, {128, 128}}, draw.Color{0, 1, 0, 1})
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.PI / 4), {64, 64}))
		draw.backdrop(dc, {{44, 44}, {84, 84}}, {}, current_filters)
		draw.pop_transform(dc)
		draw.pop_layer(dc)
	})
	c := px(rot, 64, 64)
	testing.expectf(t, c[0] == c[1] && c[1] == c[2] && c[0] > 100, "grayscale of the layer's green: %v", c)
	// the square turned 45 degrees is a diamond of half diagonal 28.3: its top corner is at y = 35.7
	testing.expectf(t, close_rgb(px(rot, 64, 33), {0, 255, 0, 255}, 0), "above the diamond: %v", px(rot, 64, 33))
	testing.expectf(t, close_rgb(px(rot, 46, 46), {0, 255, 0, 255}, 0), "the unrotated corner is outside: %v", px(rot, 46, 46))
	testing.expectf(t, px(rot, 64, 38)[0] > 100, "inside, near the top corner: %v", px(rot, 64, 38))
}

@(test)
targets_are_reused_and_nothing_leaks :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	body :: proc(dc: ^draw.Context) {
		fl := []draw.Filter{draw.filter_blur(10), draw.filter_drop_shadow({4, 4}, 3, {0, 0, 0, 0.6}), draw.filter_sepia(1)}
		for i in 0 ..< 6 {
			x := f32(i % 3) * 40 + 4
			y := f32(i / 3) * 60 + 4
			draw.push_effects(dc, {{x, y}, {x + 30, y + 40}}, draw.Layer_Effects{alpha = 0.8, filters = fl, blend = i % 2 == 0 ? .Multiply : .Normal})
			draw.rect(dc, {{x, y}, {x + 30, y + 40}}, draw.Color{0.8, 0.3, 0.1, 1}, 6)
			draw.pop_layer(dc)
		}
		draw.backdrop(dc, {{10, 10}, {110, 110}}, {8, 8, 8, 8}, fl)
	}
	_ = frame(&f, body)
	before := render.targets_bytes(&f.r)
	pooled := len(f.r.targets)
	_ = frame(&f, body)
	testing.expectf(t, render.targets_bytes(&f.r) == before && len(f.r.targets) == pooled, "the same frame again allocates nothing (%d targets)", pooled)
	// passes hand their textures back as soon as they are read: six filtered layers share a few targets
	testing.expectf(t, pooled <= 12, "targets reused within the frame: %d", pooled)
	// identity filters make no layer pass
	current_filters = {draw.filter_brightness(1), draw.filter_blur(0)}
	_ = frame(&f, proc(dc: ^draw.Context) {
		draw.push_effects(dc, {{0, 0}, {64, 64}}, draw.Layer_Effects{alpha = 1, filters = current_filters})
		draw.rect(dc, {{0, 0}, {64, 64}}, draw.WHITE)
		draw.pop_layer(dc)
	})
	passes := 0
	for op in f.dc.ops { if op.kind == .Pass { passes += 1 } }
	testing.expect(t, passes == 0, "identity filters run no pass")
}
