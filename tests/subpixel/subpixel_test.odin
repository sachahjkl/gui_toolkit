package subpixel_test

import "core:testing"
import "../../src/draw"
import "../../src/font"
import "../../src/render"

// Text with a coverage per colour stripe, on an offscreen renderer (WARP), with the renderer's own text: the atlas on Direct3D 11,
// Slug on WebGPU. Black text has no colour of its own, so what has one is what the stripes did.

SIZE :: [2]int{240, 90}
TINT :: 12   // red and blue further apart than this: a pixel the stripes coloured (grey text has none at all)

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
}

open :: proc(f: ^Fx, stripes: font.Subpixel_Text) -> bool {
	if !render.init_offscreen(&f.r, SIZE, warp = true) { return false }
	st := font.DEFAULT_SETTINGS
	st.text_renderer = render.USE_WGPU ? .Slug : .Atlas
	st.subpixel_text = stripes
	font.init(&f.fonts, st)
	ok: bool
	f.ui, ok = font.load_system(&f.fonts, "Segoe UI")
	draw.init(&f.dc, &f.r, &f.fonts)
	return ok
}

close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

frame :: proc(f: ^Fx, body: proc(f: ^Fx), clear := [4]f32{1, 1, 1, 1}) -> []u8 {
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, clear)
	body(f)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

px :: proc(img: []u8, x, y: int) -> [3]int {
	o := (y * SIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2])}
}

tinted :: proc(img: []u8) -> (n: int) {
	for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x { p := px(img, x, y); if abs(p.x - p.z) > TINT { n += 1 } } }
	return
}

// How far from white, summed over the picture and the channels.
ink :: proc(img: []u8) -> (n: f64) {
	for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x { p := px(img, x, y); n += f64(765 - p.x - p.y - p.z) } }
	return
}

BLACK :: draw.Color{0, 0, 0, 1}

paragraph :: proc(f: ^Fx) {
	draw.text(&f.dc, f.ui, 16, {6, 22}, BLACK, "Hamburgefonstiv sphinx 0123")
	draw.text(&f.dc, f.ui, 12, {6, 44}, BLACK, "The quick brown fox jumps over the lazy dog")
	draw.text(&f.dc, f.ui, 28, {6, 80}, BLACK, "Wren")
}

// Two renderers side by side: `stripes` and grayscale.
pair :: proc(t: ^testing.T, stripes: font.Subpixel_Text = .Rgb) -> (a, b: ^Fx) {
	a, b = new(Fx), new(Fx)
	if !open(a, stripes) || !open(b, .Off) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	if !render.text_subpixel_supported(&a.r, render.USE_WGPU) { testing.fail_now(t, "this device blends no text per channel") }
	return
}

unpair :: proc(a, b: ^Fx) { close(a); close(b); free(a); free(b) }

@(test)
stripes_colour_the_edges_and_keep_the_weight :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	lcd, gray := frame(a, paragraph), frame(b, paragraph)
	testing.expect_value(t, tinted(gray), 0)
	testing.expectf(t, tinted(lcd) > 300, "the stripes coloured %d pixels", tinted(lcd))
	r := ink(lcd) / ink(gray)
	testing.expectf(t, r > 0.85 && r < 1.15, "the weight of the text moved: %.3f of grayscale's", r)
}

// The other order of the stripes is the same text, red and blue swapped.
@(test)
the_order_of_the_stripes_swaps_red_and_blue :: proc(t: ^testing.T) {
	a, b := new(Fx), new(Fx)
	defer free(a)
	defer free(b)
	if !open(a, .Rgb) || !open(b, .Bgr) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(a)
	defer close(b)
	rgb, bgr := frame(a, paragraph), frame(b, paragraph)
	worst := 0
	for y in 0 ..< SIZE.y {
		for x in 0 ..< SIZE.x {
			p, q := px(rgb, x, y), px(bgr, x, y)
			worst = max(worst, abs(p.x - q.z), abs(p.z - q.x), abs(p.y - q.y))
		}
	}
	testing.expectf(t, worst <= 2, "off by %d of 255", worst)
}

// Blending by a factor per channel is blending by the alpha for what has one coverage: nothing else moves by one bit.
@(test)
what_is_not_text_does_not_move :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	shapes :: proc(f: ^Fx) {
		draw.rect(&f.dc, {{10, 10}, {60, 40}}, draw.Color{0.2, 0.6, 0.9, 1})
		draw.rect(&f.dc, {{30, 20}, {90, 70}}, draw.Color{0.9, 0.3, 0.1, 0.4}, 12)
		draw.push_alpha(&f.dc, 0.37)
		draw.rect(&f.dc, {{100.5, 12.25}, {180, 60}}, draw.Color{0.1, 0.8, 0.3, 1}, 9)
		draw.pop_alpha(&f.dc)
		draw.rect_corners(&f.dc, {{150, 30}, {230, 85}}, {draw.Color{1, 0, 0, 1}, draw.Color{0, 1, 0, 0.5}, draw.Color{0, 0, 1, 0.7}, draw.Color{1, 1, 0, 1}}, {6, 6, 6, 6})
		// a layer, composited in the frame's target
		draw.push_layer(&f.dc, {{4, 50}, {120, 86}}, 0.6)
		draw.rect(&f.dc, {{8, 54}, {110, 82}}, draw.Color{0.7, 0.1, 0.5, 1}, 5)
		draw.pop_layer(&f.dc)
	}
	x, y := frame(a, shapes), frame(b, shapes)
	diff := 0
	for v, i in x { if v != y[i] { diff += 1 } }
	testing.expect_value(t, diff, 0)
	testing.expect(t, px(x, 60, 76) != {255, 255, 255}, "the layer was not composited")
}

// A layer has one alpha per pixel: the same text, averaged there.
@(test)
text_in_a_layer_has_no_stripes :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	layered :: proc(f: ^Fx) {
		draw.push_layer(&f.dc, {{0, 0}, {f32(SIZE.x), f32(SIZE.y)}}, 0.6)
		paragraph(f)
		draw.pop_layer(&f.dc)
	}
	lcd, gray := frame(a, layered), frame(b, layered)
	testing.expect_value(t, tinted(lcd), 0)
	testing.expectf(t, ink(lcd) > 0 && ink(gray) > 0, "no text in the layer: ink %.0f, in grey %.0f", ink(lcd), ink(gray))
	r := ink(lcd) / ink(gray)
	testing.expectf(t, r > 0.85 && r < 1.15, "the weight of the text moved: %.3f of grayscale's", r)
}

// Text that does not run along the rows of the screen has no stripes either, and is there.
@(test)
turned_text_has_no_stripes :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	turned :: proc(f: ^Fx) {
		draw.push_transform(&f.dc, draw.affine_around(draw.affine_rotate(0.4), {120, 45}))
		draw.text(&f.dc, f.ui, 20, {40, 50}, BLACK, "Rotated text")
		draw.pop_transform(&f.dc)
	}
	lcd, gray := frame(a, turned), frame(b, turned)
	testing.expect_value(t, tinted(lcd), 0)
	testing.expect(t, ink(gray) > 0, "no text")
	r := ink(lcd) / ink(gray)
	testing.expectf(t, r > 0.85 && r < 1.15, "the weight of the text moved: %.3f of grayscale's", r)
}

// Opacity scales all three stripes, and a clip cuts them.
@(test)
opacity_and_clips_apply_to_the_stripes :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	half :: proc(f: ^Fx) {
		draw.push_alpha(&f.dc, 0.5)
		paragraph(f)
		draw.pop_alpha(&f.dc)
	}
	faint := frame(a, half)
	r := ink(faint) / ink(frame(b, half))   // (grayscale, at the same opacity: what half of it is depends on the target's blend space)
	testing.expectf(t, r > 0.9 && r < 1.1, "at half the opacity the ink is %.3f of grayscale's", r)
	testing.expect(t, tinted(faint) > 0, "no stripes at half the opacity")
	clipped := frame(a, proc(f: ^Fx) {
		draw.push_clip(&f.dc, {{0, 0}, {60, f32(SIZE.y)}})
		paragraph(f)
		draw.pop_clip(&f.dc)
	})
	for y in 0 ..< SIZE.y { for x in 61 ..< SIZE.x { if px(clipped, x, y) != {255, 255, 255} { testing.fail_now(t, "text past the clip") } } }
}

// Light on dark: the middle of a wide stem is the colour of the text on all three channels, what is around it the background.
@(test)
light_text_on_dark_reaches_its_colour :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	img := frame(a, proc(f: ^Fx) { draw.text(&f.dc, f.ui, 60, {10, 70}, draw.Color{1, 1, 1, 1}, "H") }, {0, 0, 0, 1})
	whole := 0
	for y in 0 ..< SIZE.y { for x in 0 ..< SIZE.x { if px(img, x, y) == {255, 255, 255} { whole += 1 } } }
	testing.expectf(t, whole > 100, "%d pixels reach the text's colour", whole)
	testing.expect_value(t, px(img, 200, 10), [3]int{0, 0, 0})
}

// A picture draws what direct drawing draws, stripes included; replayed turned it is averaged, and there.
@(test)
pictures_keep_their_stripes :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	@(static) pic: draw.Picture
	draw.begin_frame(&a.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&a.r, {1, 1, 1, 1})
	draw.picture_begin(&a.dc, &pic)
	paragraph(a)
	draw.picture_end(&a.dc)
	draw.end_frame(&a.dc)
	render.frame_end(&a.r)
	direct := frame(a, paragraph)
	replayed := frame(a, proc(f: ^Fx) { draw.replay(&f.dc, &pic, draw.AFFINE_IDENTITY) })
	worst := 0
	for y in 0 ..< SIZE.y {
		for x in 0 ..< SIZE.x {
			p, q := px(direct, x, y), px(replayed, x, y)
			worst = max(worst, abs(p.x - q.x), abs(p.y - q.y), abs(p.z - q.z))
		}
	}
	testing.expectf(t, worst <= 2, "the replay differs by %d of 255", worst)
	turned := frame(a, proc(f: ^Fx) { draw.replay(&f.dc, &pic, draw.affine_around(draw.affine_rotate(0.1), {120, 45})) })
	testing.expect_value(t, tinted(turned), 0)
	r := ink(turned) / ink(direct)
	testing.expectf(t, r > 0.7 && r < 1.3, "turned, the ink is %.3f of the direct text's", r)
	draw.picture_destroy(&a.dc, &pic)
}

// The setting can change while the program runs: what was cached and recorded for the other mode is not reused.
@(test)
changing_the_setting_changes_the_text :: proc(t: ^testing.T) {
	a, b := pair(t)
	defer unpair(a, b)
	testing.expect(t, tinted(frame(a, paragraph)) > 0, "no stripes at first")
	st := a.fonts.settings
	st.subpixel_text = .Off
	font.set_settings(&a.fonts, st)
	testing.expect_value(t, tinted(frame(a, paragraph)), 0)
	st.subpixel_text = .Rgb
	font.set_settings(&a.fonts, st)
	testing.expect(t, tinted(frame(a, paragraph)) > 0, "no stripes again")
}
