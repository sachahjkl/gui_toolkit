// Pixel tests of masks (CSS Masking 1 §7: mask-image, mask-mode, mask-composite; background-clip: text) on an
// offscreen renderer (WARP), in both blend spaces.   odin test tests/masks -vet
package masks_test

import "core:math"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

SIZE :: [2]int{160, 64}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
}

@(private = "file", thread_local)
current_space: render.Blend_Space

@(private = "file")
open :: proc(f: ^Fx) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true, space = current_space) { return false }
	font.init(&f.fonts)
	draw.init(&f.dc, &f.r, &f.fonts)
	return true
}

@(private = "file")
close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

@(private = "file")
frame :: proc(f: ^Fx, body: proc(f: ^Fx)) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(f)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
px :: proc(img: []u8, x, y: int) -> [3]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
}

@(private = "file")
close_rgb :: proc(a, b: [3]int, tol := 3) -> bool {
	for i in 0 ..< 3 { if abs(a[i] - b[i]) > tol { return false } }
	return true
}

// Red over the white frame at coverage `a`: on sRGB values (as browsers blend) in an sRGB frame, in linear light in a
// linear one (the coverage itself is the same in both).
@(private = "file")
red_at :: proc(a: f32) -> [3]int {
	v := 1 - a
	if current_space == .Linear { v = v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055 }
	k := int(math.round(255 * v))
	return {255, k, k}
}

RED :: draw.Color{1, 0, 0, 1}
WHITE :: draw.Color{1, 1, 1, 1}
BLACK :: draw.Color{0, 0, 0, 1}
CONTENT :: draw.Rect{{0, 0}, {160, 64}}

@(private = "file")
spaces :: proc(t: ^testing.T, body: proc(t: ^testing.T, f: ^Fx)) {
	for space in ([?]render.Blend_Space{.Srgb, .Linear}) {
		current_space = space
		f := new(Fx)
		if !open(f) { free(f); testing.fail_now(t, "no offscreen renderer") }
		body(t, f)
		close(f)
		free(f)
	}
}

@(test)
alpha_and_luminance :: proc(t: ^testing.T) {
	spaces(t, proc(t: ^testing.T, f: ^Fx) {
		img := frame(f, proc(f: ^Fx) {
			dc := &f.dc
			draw.push_mask(dc, CONTENT)
			draw.rect(dc, CONTENT, RED)
			// alpha: opaque on the left quarter, half transparent on the second, nothing on the right half (the
			// color of the mask does not matter)
			draw.mask_layer(dc, .Alpha, .Add)
			draw.rect(dc, {{0, 0}, {40, 32}}, draw.Color{0, 0, 1, 1})
			draw.rect(dc, {{40, 0}, {80, 32}}, draw.Color{0, 1, 0, 0.5})
			// luminance (bottom row): white, sRGB gray 50 %, black
			draw.rect(dc, {{0, 32}, {40, 64}}, WHITE)
			draw.rect(dc, {{40, 32}, {80, 64}}, draw.srgb(0.5, 0.5, 0.5))
			draw.rect(dc, {{80, 32}, {120, 64}}, BLACK)
			draw.pop_mask(dc)
		})
		testing.expectf(t, close_rgb(px(img, 20, 16), red_at(1)), "%v: opaque mask %v", current_space, px(img, 20, 16))
		testing.expectf(t, close_rgb(px(img, 60, 16), red_at(0.5)), "%v: 50%% mask %v", current_space, px(img, 60, 16))
		testing.expectf(t, close_rgb(px(img, 100, 16), red_at(0)), "%v: no mask %v", current_space, px(img, 100, 16))
		// the alpha of opaque white, gray and black is 1: an alpha mask shows the content under all three
		testing.expectf(t, close_rgb(px(img, 100, 48), red_at(1)), "%v: black is opaque for an alpha mask %v", current_space, px(img, 100, 48))
		img2 := frame(f, proc(f: ^Fx) {
			dc := &f.dc
			draw.push_mask(dc, CONTENT)
			draw.rect(dc, CONTENT, RED)
			draw.mask_layer(dc, .Luminance, .Add)
			draw.rect(dc, {{0, 0}, {40, 64}}, WHITE)
			draw.rect(dc, {{40, 0}, {80, 64}}, draw.srgb(0.5, 0.5, 0.5))
			draw.rect(dc, {{80, 0}, {120, 64}}, BLACK)
			draw.rect(dc, {{120, 0}, {160, 64}}, draw.Color{1, 1, 1, 0.5})
			draw.pop_mask(dc)
		})
		testing.expectf(t, close_rgb(px(img2, 20, 30), red_at(1)), "%v: white luminance %v", current_space, px(img2, 20, 30))
		testing.expectf(t, close_rgb(px(img2, 60, 30), red_at(0.5)), "%v: gray luminance %v", current_space, px(img2, 60, 30))
		testing.expectf(t, close_rgb(px(img2, 100, 30), red_at(0)), "%v: black luminance %v", current_space, px(img2, 100, 30))
		// half transparent white: luminance times alpha
		testing.expectf(t, close_rgb(px(img2, 140, 30), red_at(0.5)), "%v: translucent white luminance %v", current_space, px(img2, 140, 30))
	})
}

@(test)
composite_operators :: proc(t: ^testing.T) {
	spaces(t, proc(t: ^testing.T, f: ^Fx) {
		// layer A (bottom) covers x < 100, layer B (top) x >= 60; one row per operator of B over A
		@(static) op: draw.Mask_Op
		Want :: struct { op: draw.Mask_Op, left, middle, right: f32 }
		cases := [?]Want{
			{.Add, 1, 1, 1},
			{.Subtract, 0, 0, 1},
			{.Intersect, 0, 1, 0},
			{.Exclude, 1, 0, 1},
		}
		for c in cases {
			op = c.op
			img := frame(f, proc(f: ^Fx) {
				dc := &f.dc
				draw.push_mask(dc, CONTENT)
				draw.rect(dc, CONTENT, RED)
				draw.mask_layer(dc, .Alpha, .Add)
				draw.rect(dc, {{0, 0}, {100, 64}}, BLACK)
				draw.mask_layer(dc, .Alpha, op)
				draw.rect(dc, {{60, 0}, {160, 64}}, BLACK)
				draw.pop_mask(dc)
			})
			l, m, r := px(img, 30, 32), px(img, 80, 32), px(img, 130, 32)
			testing.expectf(t, close_rgb(l, red_at(c.left)) && close_rgb(m, red_at(c.middle)) && close_rgb(r, red_at(c.right)),
				"%v %v: %v %v %v", current_space, c.op, l, m, r)
		}
	})
}

@(test)
gradient_mask_opacity_clip_and_none :: proc(t: ^testing.T) {
	spaces(t, proc(t: ^testing.T, f: ^Fx) {
		img := frame(f, proc(f: ^Fx) {
			dc := &f.dc
			// a linear alpha ramp 0 -> 1 over the width, the group at 50 % opacity, cut by a clip on the right
			draw.push_clip(dc, {{0, 0}, {140, 64}})
			draw.push_mask(dc, CONTENT, {alpha = 0.5})
			draw.rect(dc, CONTENT, RED)
			draw.mask_layer(dc, .Alpha, .Add)
			stops := [2]draw.Gradient_Stop{{color = {0, 0, 0, 0}, pos = 0}, {color = BLACK, pos = 1}}
			draw.gradient(dc, CONTENT, draw.Gradient{kind = .Linear, start = {0, 0}, end = {160, 0}, stops = stops[:], space = .Srgb})
			draw.pop_mask(dc)
			draw.pop_clip(dc)
		})
		prev := -1
		for x := 4; x < 140; x += 16 {
			g := px(img, x, 32)[1]
			testing.expectf(t, prev < 0 || g <= prev, "%v: the ramp is not monotonic at x = %d", current_space, x)
			prev = g
		}
		testing.expectf(t, close_rgb(px(img, 80, 32), red_at(0.25), 4), "%v: middle of the ramp at 50 %% opacity %v", current_space, px(img, 80, 32))
		testing.expectf(t, close_rgb(px(img, 150, 32), red_at(0)), "%v: the clip cuts the group %v", current_space, px(img, 150, 32))
		// no mask layer at all: the content as it is
		img2 := frame(f, proc(f: ^Fx) {
			dc := &f.dc
			draw.push_mask(dc, CONTENT)
			draw.rect(dc, CONTENT, RED)
			draw.pop_mask(dc)
		})
		testing.expect(t, close_rgb(px(img2, 80, 32), red_at(1)))
	})
}

@(test)
text_as_mask :: proc(t: ^testing.T) {
	// background-clip: text: a gradient seen through the glyphs of a bold word
	spaces(t, proc(t: ^testing.T, f: ^Fx) {
		ui, ok := font.load_system(&f.fonts, "Arial", 900)
		if !ok { testing.fail_now(t, "no Arial") }
		@(static) face: font.Font_Id
		face = ui
		img := frame(f, proc(f: ^Fx) {
			dc := &f.dc
			draw.push_mask(dc, CONTENT)
			stops := [2]draw.Gradient_Stop{{color = {1, 0, 0, 1}, pos = 0}, {color = {0, 0, 1, 1}, pos = 1}}
			draw.gradient(dc, CONTENT, draw.Gradient{kind = .Linear, start = {0, 0}, end = {160, 0}, stops = stops[:], space = .Srgb})
			draw.mask_layer(dc, .Alpha, .Add)
			draw.text(dc, face, 56, {2, 54}, WHITE, "HIH")
			draw.pop_mask(dc)
		})
		// inside the first H's left stem: red; inside the last H's right stem: blue; between letters: white
		inside := 0
		outside_white := 0
		for y in 20 ..< 50 {
			for x in 0 ..< SIZE.x {
				p := px(img, x, y)
				if p == {255, 255, 255} { outside_white += 1; continue }
				if p[1] < 40 { inside += 1 }   // opaque gradient color: no green
			}
		}
		testing.expectf(t, inside > 400 && outside_white > 1000, "%v: %d pixels of gradient through the glyphs, %d white", current_space, inside, outside_white)
		l := px(img, 9, 35)
		testing.expectf(t, l[0] > 200 && l[2] < 80, "%v: the left stem is not red: %v", current_space, l)
		gray := 0
		for y in 20 ..< 50 { for x in 0 ..< SIZE.x { p := px(img, x, y); if abs(p[0] - p[1]) < 10 && abs(p[1] - p[2]) < 10 && p[0] < 200 { gray += 1 } } }
		testing.expectf(t, gray == 0, "%v: %d gray pixels (the text color must not show)", current_space, gray)
	})
}

@(test)
recorded_mask_falls_back :: proc(t: ^testing.T) {
	// a picture cannot hold layers: a mask recorded into one draws its content unmasked, and nothing of the mask
	current_space = .Srgb
	f := new(Fx)
	defer free(f)
	if !open(f) { testing.fail_now(t, "no offscreen renderer") }
	defer close(f)
	@(static) pic: draw.Picture
	img := frame(f, proc(f: ^Fx) {
		dc := &f.dc
		draw.picture_begin(dc, &pic)
		draw.push_mask(dc, CONTENT)
		draw.rect(dc, {{0, 0}, {80, 64}}, RED)
		draw.mask_layer(dc, .Alpha, .Add)
		draw.rect(dc, {{100, 0}, {160, 64}}, BLACK)
		draw.pop_mask(dc)
		draw.picture_end(dc)
		draw.replay(dc, &pic, draw.AFFINE_IDENTITY)
	})
	testing.expect(t, close_rgb(px(img, 40, 32), red_at(1)), "the content is drawn")
	testing.expect(t, close_rgb(px(img, 130, 32), {255, 255, 255}), "the mask is not drawn")
	draw.picture_destroy(&f.dc, &pic)
}
