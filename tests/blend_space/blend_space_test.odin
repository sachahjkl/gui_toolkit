// Pixel tests of the two blend spaces (render.Blend_Space) on an offscreen renderer (WARP): blending, antialiased
// edges, gradients and their interpolation space, RGBA textures (premultiplication, filtering, mips, a texture of the
// other space), layers of either space in a frame of the other, set_blend_space, the clear color and the text
// correction. Srgb results are those of web browsers (CSS Color 4, Compositing 1).   odin test tests/blend_space -vet
package blend_space_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{128, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
}

@(private = "file")
open :: proc(f: ^Fx, space: render.Blend_Space) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = space) { return false }
	font.init(&f.fonts)
	ok: bool
	f.ui, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	return ok
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

@(private = "file", thread_local) cur_fx: ^Fx

@(private = "file")
frame :: proc(f: ^Fx, body: proc(dc: ^draw.Context), clear := [4]f32{1, 1, 1, 1}) -> []u8 {
	cur_fx = f
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
near :: proc(a: [4]int, r, g, b: int, tol := 1) -> bool {
	return abs(a[0] - r) <= tol && abs(a[1] - g) <= tol && abs(a[2] - b) <= tol
}

// 8-bit sRGB value of a linear one.
@(private = "file")
enc8 :: proc(l: f32) -> int { return int(math.round(render.linear_to_srgb(l) * 255)) }

// Half of something over white / black, in each space.
@(private = "file")
half :: proc(space: render.Blend_Space) -> int { return space == .Srgb ? 128 : enc8(0.5) }

RED :: draw.Color{1, 0, 0, 1}
BLUE :: draw.Color{0, 0, 1, 1}

@(test)
translucent_colors_blend_in_their_space :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		// rgba(0, 0, 0, .5) over white: 128 in every browser, 188 in linear light
		img := frame(&f, proc(dc: ^draw.Context) { draw.rect(dc, {{0, 0}, {64, 64}}, {0, 0, 0, 0.5}) })
		h := half(space)
		testing.expectf(t, near(px(img, 32, 32), h, h, h), "%v: half black over white: %v, want %d", space, px(img, 32, 32), h)
		// the same through the alpha stack, and a translucent sRGB color: rgba(255, 0, 0, .25) over rgb(0, 0, 255)
		img2 := frame(&f, proc(dc: ^draw.Context) {
			draw.rect(dc, {{0, 0}, {128, 64}}, BLUE)
			draw.push_alpha(dc, 0.5)
			draw.rect(dc, {{0, 0}, {64, 64}}, {1, 0, 0, 0.5})
			draw.pop_alpha(dc)
		})
		want_r := space == .Srgb ? 64 : enc8(0.25)
		want_b := space == .Srgb ? 191 : enc8(0.75)
		testing.expectf(t, near(px(img2, 32, 32), want_r, 0, want_b), "%v: quarter red over blue: %v", space, px(img2, 32, 32))
		// the clear color is linear in both spaces
		gray := frame(&f, proc(dc: ^draw.Context) {}, {0.5, 0.5, 0.5, 1})
		testing.expectf(t, near(px(gray, 5, 5), enc8(0.5), enc8(0.5), enc8(0.5)), "%v: clear to linear 0.5: %v", space, px(gray, 5, 5))
	}
}

@(test)
antialiased_edges_mix_in_their_space :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.rect(dc, {{10.5, 4}, {40, 60}}, {0, 0, 0, 1})                        // edge through pixel 10
			draw.rect(dc, {{60, 1.5}, {120, 61.5}}, {0, 0, 0, 1}, 30)                 // a circle of radius 30
		})
		h := half(space)
		testing.expectf(t, near(px(img, 10, 30), h, h, h, 2), "%v: half-covered pixel of an edge: %v, want %d", space, px(img, 10, 30), h)
		// the circle's edge crosses its middle row (y = 31.5) at x = 120: pixels 119 and 120 share one pixel of coverage
		a, b := px(img, 119, 31)[0], px(img, 120, 31)[0]
		inside := func_cov(space, a) + func_cov(space, b)
		testing.expectf(t, abs(inside - 1) < 0.08, "%v: circle edge coverage %v + %v", space, a, b)
		// a pixel whose center is on the circle: 50 % coverage, the intermediate value of the space
		testing.expectf(t, abs(px(img, 90, 1)[0] - h) <= 6, "%v: pixel centered on the circle's top: %v, want about %d", space, px(img, 90, 1), h)
	}
}

// Coverage of black on white from an 8-bit value.
@(private = "file")
func_cov :: proc(space: render.Blend_Space, v: int) -> f32 {
	x := f32(v) / 255
	return 1 - (space == .Srgb ? x : render.srgb_to_linear(x))
}

@(test)
gradients_interpolate_where_asked :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		@(static) interp: draw.Interpolation
		for mode in draw.Interpolation {
			interp = mode
			img := frame(&f, proc(dc: ^draw.Context) {
				prev := draw.set_interpolation(dc, interp)
				// linear-gradient(to right, red, blue) over 128 px: pixel 63 / 64 straddle the middle
				draw.rect_corners(dc, {{0, 0}, {128, 64}}, {RED, RED, BLUE, BLUE}, {})
				draw.set_interpolation(dc, prev)
			})
			in_srgb := mode == .Srgb || (mode == .Target && space == .Srgb)
			// the middle: (128, 0, 128) in sRGB (CSS), (188, 0, 188) in linear light
			l, r := px(img, 63, 32), px(img, 64, 32)
			mid := [2]int{(l[0] + r[0]) / 2, (l[2] + r[2]) / 2}
			want := in_srgb ? 128 : enc8(0.5)
			testing.expectf(t, abs(mid[0] - want) <= 2 && abs(mid[1] - want) <= 2 && l[1] == 0, "%v, interpolation %v: middle %v %v, want %d", space, mode, l, r, want)
		}
		// red to transparent over white, interpolated premultiplied (CSS): no dark band in the middle
		img := frame(&f, proc(dc: ^draw.Context) {
			prev := draw.set_interpolation(dc, .Srgb)
			draw.rect_corners(dc, {{0, 0}, {128, 64}}, {RED, RED, {0, 0, 0, 0}, {0, 0, 0, 0}}, {})
			draw.set_interpolation(dc, prev)
		})
		p := px(img, 64, 32)
		testing.expectf(t, p[0] >= 254 && p[1] == p[2] && p[1] > 100, "%v: red to transparent stays red: %v", space, p)
	}
}

@(test)
opacity_layers_and_layers_of_the_other_space :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		// opacity: .5 of a white box over black (one layer)
		img := frame(&f, proc(dc: ^draw.Context) {
			draw.push_layer(dc, {{0, 0}, {64, 64}}, 0.5)
			draw.rect(dc, {{0, 0}, {64, 64}}, draw.WHITE)
			draw.rect(dc, {{16, 16}, {48, 48}}, draw.WHITE)
			draw.pop_layer(dc)
		}, {0, 0, 0, 1})
		h := half(space)
		testing.expectf(t, near(px(img, 32, 32), h, h, h), "%v: opacity .5 of white over black: %v, want %d", space, px(img, 32, 32), h)
		// a layer of each space inside a frame of the other: the content blends in the layer's space, the opaque result
		// composites exactly
		@(static) inner: draw.Layer_Space
		for ls in ([]draw.Layer_Space{.Srgb, .Linear}) {
			inner = ls
			img2 := frame(&f, proc(dc: ^draw.Context) {
				draw.push_effects(dc, {{0, 0}, {64, 64}}, draw.Layer_Effects{alpha = 1, space = inner})
				draw.rect(dc, {{0, 0}, {64, 64}}, draw.WHITE)
				draw.rect(dc, {{0, 0}, {64, 64}}, {0, 0, 0, 0.5})
				draw.pop_layer(dc)
				draw.rect(dc, {{64, 0}, {128, 64}}, {0, 0, 0, 0.5})   // outside: the frame's space
			})
			want := ls == .Srgb ? 128 : enc8(0.5)
			testing.expectf(t, near(px(img2, 32, 32), want, want, want), "%v frame, %v layer: %v, want %d", space, ls, px(img2, 32, 32), want)
			testing.expectf(t, near(px(img2, 96, 32), h, h, h), "%v frame outside the layer: %v", space, px(img2, 96, 32))
		}
		// filters and blend modes in a layer of the other space still compute on sRGB values
		img3 := frame(&f, proc(dc: ^draw.Context) {
			other := draw.blend_space(dc) == .Srgb ? draw.Layer_Space.Linear : draw.Layer_Space.Srgb
			draw.push_effects(dc, {{0, 0}, {64, 64}}, draw.Layer_Effects{alpha = 1, space = other, filters = {draw.filter_grayscale(1)}})
			draw.rect(dc, {{0, 0}, {64, 64}}, RED)
			draw.pop_layer(dc)
		})
		g := int(math.round(0.2126 * 255))
		testing.expectf(t, near(px(img3, 32, 32), g, g, g, 2), "%v: grayscale(red) in a layer of the other space: %v", space, px(img3, 32, 32))
	}
}

@(private = "file", thread_local) tex: render.Texture

@(test)
textures_are_premultiplied_and_filtered_in_their_space :: proc(t: ^testing.T) {
	for space in render.Blend_Space {
		f: Fx
		if !open(&f, space) { testing.fail_now(t, "no D3D11 device (WARP)") }
		defer close(&f)
		// a PNG pixel rgba(255, 0, 0, 128) over white: Chromium gives (255, 127, 127)
		tex = render.create_texture_rgba(&f.r, 2, 2, mips = false)
		testing.expect(t, render.texture_space(&f.r, tex) == space)
		pix := [16]u8{255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128, 255, 0, 0, 128}
		render.update_texture_rgba(&f.r, tex, 0, 0, 2, 2, pix[:])
		img := frame(&f, proc(dc: ^draw.Context) { draw.image(dc, tex, {{0, 0}, {64, 64}}) })
		w := space == .Srgb ? 127 : enc8(1 - 128.0 / 255)
		testing.expectf(t, near(px(img, 32, 32), 255, w, w), "%v: half red texel over white: %v", space, px(img, 32, 32))
		render.destroy_texture(&f.r, tex)

		// opaque red next to transparent, magnified: halfway between them the premultiplied filter gives half red
		tex = render.create_texture_rgba(&f.r, 2, 1, mips = false)
		pix2 := [8]u8{255, 0, 0, 255, 0, 0, 0, 0}
		render.update_texture_rgba(&f.r, tex, 0, 0, 2, 1, pix2[:])
		img2 := frame(&f, proc(dc: ^draw.Context) { draw.image(dc, tex, {{0, 0}, {128, 64}}) })
		mid := px(img2, 63, 32)
		testing.expectf(t, mid[0] >= 254 && mid[1] == mid[2] && abs(mid[1] - (space == .Srgb ? 128 : enc8(0.5))) <= 6, "%v: filtered edge of a transparent texel: %v", space, mid)
		render.destroy_texture(&f.r, tex)

		// mips: a 4 x 4 black and white checker drawn on one pixel averages in the texture's space
		tex = render.create_texture_rgba(&f.r, 4, 4)
		checker: [64]u8
		for i in 0 ..< 16 {
			v: u8 = (i % 4 + i / 4) % 2 == 0 ? 255 : 0
			checker[i * 4], checker[i * 4 + 1], checker[i * 4 + 2], checker[i * 4 + 3] = v, v, v, 255
		}
		render.update_texture_rgba(&f.r, tex, 0, 0, 4, 4, checker[:])
		img3 := frame(&f, proc(dc: ^draw.Context) { draw.image(dc, tex, {{10, 10}, {11, 11}}) })
		avg := space == .Srgb ? 128 : enc8(0.5)
		testing.expectf(t, abs(px(img3, 10, 10)[0] - avg) <= 3, "%v: mip average of a checker: %v, want %d", space, px(img3, 10, 10), avg)
		render.destroy_texture(&f.r, tex)
	}
}

@(test)
set_blend_space_switches_and_keeps_textures :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	tex = render.create_texture_rgba(&f.r, 1, 1, mips = false)
	pix := [4]u8{255, 0, 0, 128}
	render.update_texture_rgba(&f.r, tex, 0, 0, 1, 1, pix[:])
	body :: proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {64, 64}}, {0, 0, 0, 0.5})
		draw.image(dc, tex, {{64, 0}, {128, 64}})
		// a backdrop and a blend mode read copies of the frame, in its space
		draw.push_effects(dc, {{0, 40}, {20, 60}}, draw.Layer_Effects{alpha = 1, blend = .Multiply})
		draw.rect(dc, {{0, 40}, {20, 60}}, draw.WHITE)
		draw.pop_layer(dc)
	}
	lin := frame(&f, body)
	testing.expect(t, near(px(lin, 32, 20), enc8(0.5), enc8(0.5), enc8(0.5)))
	render.set_blend_space(&f.r, .Srgb)
	testing.expect(t, render.blend_space(&f.r) == .Srgb && render.text_rendering(&f.r) == render.TEXT_RENDERING_SRGB)
	s := frame(&f, body)
	testing.expectf(t, near(px(s, 32, 20), 128, 128, 128), "after set_blend_space(.Srgb): %v", px(s, 32, 20))
	// the texture stored in linear light, drawn in sRGB: a straight red at half alpha, blended on sRGB values
	testing.expectf(t, near(px(s, 96, 32), 255, 127, 127, 2), "linear texture in an sRGB frame: %v", px(s, 96, 32))
	testing.expectf(t, near(px(s, 10, 50), 128, 128, 128), "multiply by white leaves the backdrop: %v", px(s, 10, 50))
	render.set_blend_space(&f.r, .Linear)
	back := frame(&f, body)
	worst := 0
	for i in 0 ..< len(lin) { worst = max(worst, abs(int(lin[i]) - int(back[i]))) }
	testing.expectf(t, worst <= 1, "back to linear: the same frame (difference %d)", worst)
	render.destroy_texture(&f.r, tex)
}

@(private = "file", thread_local) text_color: draw.Color

// Sum of ink (how far from the background) of a line of text.
@(private = "file")
ink :: proc(img: []u8, bg: int) -> int {
	n := 0
	for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x { n += abs(px(img, x, y)[1] - bg) } }
	return n
}

@(private = "file")
text_frame :: proc(f: ^Fx, color: draw.Color, bg: [4]f32) -> []u8 {
	text_color = color
	return frame(f, proc(dc: ^draw.Context) {
		draw.text(dc, cur_fx.ui, 22, {4, 40}, text_color, "Wren hamburgefonts")
	}, bg)
}

@(test)
text_correction_is_the_same_in_both_spaces :: proc(t: ^testing.T) {
	lf, sf: Fx
	if !open(&lf, .Linear) || !open(&sf, .Srgb) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer { close(&lf); close(&sf) }
	black, white := draw.Color{0, 0, 0, 1}, draw.Color{1, 1, 1, 1}
	on_white, on_black := [4]f32{1, 1, 1, 1}, [4]f32{0, 0, 0, 1}

	// no correction: the same coverage blended in each space (p_linear = encode(p_srgb as linear))
	plain := render.Text_Rendering{curve = .None, gamma = 1, contrast = 0, coverage_exponent = 1}
	render.set_text_rendering(&lf.r, plain)
	render.set_text_rendering(&sf.r, plain)
	l, s := text_frame(&lf, black, on_white), text_frame(&sf, black, on_white)
	worst := 0
	for y in 0 ..< SIZE.y {
		for x in 0 ..< SIZE.x {
			want := enc8(f32(px(s, x, y)[1]) / 255)
			worst = max(worst, abs(px(l, x, y)[1] - want))
		}
	}
	testing.expectf(t, worst <= 3, "uncorrected coverage relates the two spaces (worst %d)", worst)
	srgb_plain := ink(s, 255)
	testing.expectf(t, srgb_plain > ink(l, 255), "black text blended in sRGB is heavier than in linear light: %d vs %d", srgb_plain, ink(l, 255))

	// Skia / Chromium correction: the same result whatever the space, for both curves
	@(static) settings: render.Text_Rendering
	for setting in ([]render.Text_Rendering{render.TEXT_RENDERING_SRGB, {curve = .Power, gamma = 1.2, contrast = 0.2, coverage_exponent = 1}}) {
		settings = setting
		render.set_text_rendering(&lf.r, settings)
		render.set_text_rendering(&sf.r, settings)
		for c in ([][2]int{{0, 1}, {1, 0}}) {
			col := c[0] == 0 ? black : white
			bg := c[1] == 1 ? on_white : on_black
			l2, s2 := text_frame(&lf, col, bg), text_frame(&sf, col, bg)
			worst = 0
			for i in 0 ..< len(l2) { worst = max(worst, abs(int(l2[i]) - int(s2[i]))) }
			testing.expectf(t, worst <= 3, "%v, %v text: corrected coverage gives the same pixels in both spaces (worst %d)", settings.curve, col, worst)
		}
	}
	// the sRGB curve without contrast is blending in linear light: in an sRGB frame, the pixels of a linear frame
	render.set_text_rendering(&sf.r, {curve = .Srgb, gamma = 1, contrast = 0, coverage_exponent = 1})
	s3 := text_frame(&sf, black, on_white)
	worst = 0
	for i in 0 ..< len(l) { worst = max(worst, abs(int(l[i]) - int(s3[i]))) }
	testing.expectf(t, worst <= 3, "sRGB curve, no contrast = linear blending (worst %d)", worst)
	// contrast 1 makes black text heavier than linear blending; a power curve alone (1.2, contrast 0) blends a little
	// closer to linear light than sRGB values, which lightens it
	render.set_text_rendering(&sf.r, render.TEXT_RENDERING_SRGB)
	dark := ink(text_frame(&sf, black, on_white), 255)
	testing.expectf(t, dark > ink(l, 255) * 11 / 10, "contrast thickens dark text: %d vs %d", dark, ink(l, 255))
	render.set_text_rendering(&sf.r, {curve = .Power, gamma = 1.2, contrast = 0, coverage_exponent = 1})
	g := ink(text_frame(&sf, black, on_white), 255)
	testing.expectf(t, g < srgb_plain && g > ink(l, 255), "gamma 1.2 alone: %d between %d and %d", g, ink(l, 255), srgb_plain)
	// light text on black: the contrast fades out (the guessed background is dark), only the curve remains
	render.set_text_rendering(&sf.r, render.TEXT_RENDERING_SRGB)
	light := ink(text_frame(&sf, white, on_black), 0)
	render.set_text_rendering(&sf.r, {curve = .Srgb, gamma = 1, contrast = 0, coverage_exponent = 1})
	light_no_contrast := ink(text_frame(&sf, white, on_black), 0)
	testing.expectf(t, abs(light - light_no_contrast) * 50 < light, "white on black ignores the contrast: %d vs %d", light, light_no_contrast)
	// (plain coverage gives white on black the ink of black on white)
	testing.expectf(t, light > srgb_plain * 21 / 20, "light text is heavier than plain sRGB coverage: %d vs %d", light, srgb_plain)
	// the Linear default keeps the historical look: coverage^0.8 blended in linear light
	render.set_text_rendering(&lf.r, render.TEXT_RENDERING_SRGB)
	testing.expect(t, render.text_rendering(&lf.r) == render.TEXT_RENDERING_SRGB)
	render.set_text_rendering(&lf.r, render.text_rendering_default(.Linear))
	testing.expect(t, render.text_rendering(&lf.r) == render.TEXT_RENDERING_LINEAR)
}

@(test)
alpha_like_linear_matches_the_linear_look :: proc(t: ^testing.T) {
	f: Fx
	if !open(&f, .Linear) { testing.fail_now(t, "no D3D11 device (WARP)") }
	defer close(&f)
	@(static) a: f32
	@(static) bg: draw.Color
	bg = draw.hex(0x171b2fff)
	a = 0.1
	body :: proc(dc: ^draw.Context) {
		draw.rect(dc, {{0, 0}, {128, 64}}, bg)
		draw.rect(dc, {{0, 0}, {64, 64}}, {1, 1, 1, draw.alpha_like_linear(draw.blend_space(dc), draw.WHITE, a, bg)})
	}
	lin := frame(&f, body)
	render.set_blend_space(&f.r, .Srgb)
	s := frame(&f, body)
	testing.expectf(t, abs(px(lin, 32, 32)[1] - px(s, 32, 32)[1]) <= 2, "10 %% white over a dark panel looks the same: %v vs %v", px(lin, 32, 32), px(s, 32, 32))
	testing.expect(t, draw.alpha_like_linear(.Linear, draw.WHITE, 0.3, bg) == 0.3)
	testing.expect(t, draw.alpha_like_linear(.Srgb, draw.WHITE, 0.1, bg) > 0.1)
}
