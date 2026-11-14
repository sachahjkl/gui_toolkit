// The image package's transformations on small pictures: exact pixels where the operation is exact (crop, flip, rotate,
// pad, border, invert, grayscale, threshold, sepia, draw_over, pixelate, anchors), properties where it is not (blur keeps
// the sum, a flat colour stays flat through resize, blur and sharpen, round corners clear the corners and keep the centre,
// a shadow grows the picture and keeps it whole, a gradient runs its way); text drawn on the CPU lands at its anchor.
//   odin test tests/image -vet
package image_test

import "core:testing"
import font "../../src/font"
import image "../../src/image"

@(private = "file")
RED :: image.Color{255, 0, 0, 255}
@(private = "file")
GREEN :: image.Color{0, 255, 0, 255}
@(private = "file")
BLUE :: image.Color{0, 0, 255, 255}
@(private = "file")
GREY :: image.Color{128, 128, 128, 255}

// A picture of `width` columns, its pixels row after row.
@(private = "file")
picture :: proc(width: int, colors: []image.Color) -> image.Image {
	img := image.create(width, len(colors) / width, allocator = context.temp_allocator)
	for c, i in colors { pixel_set(img, i % width, i / width, c) }
	return img
}

@(private = "file")
pixel :: proc(img: image.Image, x, y: int) -> image.Color {
	p := img.pixels[(y * img.width + x) * 4:][:4]
	return {p[0], p[1], p[2], p[3]}
}

@(private = "file")
pixel_set :: proc(img: image.Image, x, y: int, c: image.Color) {
	p := img.pixels[(y * img.width + x) * 4:][:4]
	p[0], p[1], p[2], p[3] = c[0], c[1], c[2], c[3]
}

@(private = "file")
pixels_of :: proc(img: image.Image) -> []image.Color {
	out := make([]image.Color, img.width * img.height, context.temp_allocator)
	for &c, i in out { c = pixel(img, i % img.width, i / img.width) }
	return out
}

@(private = "file")
expect_pixels :: proc(t: ^testing.T, img: image.Image, width: int, want: []image.Color, what: string, loc := #caller_location) {
	if !testing.expectf(t, img.width == width && img.width * img.height == len(want), "%s: size %d x %d", what, img.width, img.height, loc = loc) { return }
	got := pixels_of(img)
	for c, i in want {
		if got[i] != c {
			testing.expectf(t, false, "%s: pixel %d, %d is %v, not %v", what, i % width, i / width, got[i], c, loc = loc)
			return
		}
	}
}

// Every pixel `c`.
@(private = "file")
flat :: proc(img: image.Image, c: image.Color) -> bool {
	for p in pixels_of(img) { if p != c { return false } }
	return true
}

@(private = "file")
A :: image.Color{10, 20, 30, 255}
@(private = "file")
B :: image.Color{40, 50, 60, 255}
@(private = "file")
C :: image.Color{70, 80, 90, 255}
@(private = "file")
D :: image.Color{100, 110, 120, 255}
@(private = "file")
E :: image.Color{130, 140, 150, 255}
@(private = "file")
F :: image.Color{160, 170, 180, 255}

@(test)
geometry_is_exact :: proc(t: ^testing.T) {
	// A B C
	// D E F
	img := picture(3, {A, B, C, D, E, F})
	a := context.temp_allocator

	expect_pixels(t, image.crop(img, 1, 0, 2, 2, a), 2, {B, C, E, F}, "crop")
	expect_pixels(t, image.crop(img, -5, 1, 7, 9, a), 2, {D, E}, "crop past the edges")
	testing.expect_value(t, image.crop(img, 5, 5, 2, 2, a).width, 0)

	expect_pixels(t, image.flip(img, true, a), 3, {C, B, A, F, E, D}, "flip across")
	expect_pixels(t, image.flip(img, false, a), 3, {D, E, F, A, B, C}, "flip down")

	expect_pixels(t, image.rotate(img, 1, a), 2, {D, A, E, B, F, C}, "a quarter turn clockwise")
	expect_pixels(t, image.rotate(img, 2, a), 3, {F, E, D, C, B, A}, "a half turn")
	expect_pixels(t, image.rotate(img, 3, a), 2, {C, F, B, E, A, D}, "a quarter turn counterclockwise")
	expect_pixels(t, image.rotate(img, -1, a), 2, {C, F, B, E, A, D}, "-1 is 3")
	expect_pixels(t, image.rotate(image.rotate(img, 1, a), 3, a), 3, {A, B, C, D, E, F}, "a turn and back")

	// a picture larger than a tile turns as a small one does
	big := image.create(150, 70, allocator = a)
	for y in 0 ..< 70 { for x in 0 ..< 150 { pixel_set(big, x, y, {u8(x), u8(y), u8(x ~ y), 255}) } }
	turned := image.rotate(big, 1, a)
	testing.expect_value(t, turned.width, 70)
	testing.expect_value(t, turned.height, 150)
	testing.expect_value(t, pixel(turned, 69 - 5, 9), pixel(big, 9, 5))
	testing.expect_value(t, pixel(image.rotate(turned, 3, a), 140, 66), pixel(big, 140, 66))

	T := image.TRANSPARENT
	expect_pixels(t, image.pad(img, 1, 0, 0, 1, allocator = a), 4, {T, A, B, C, T, D, E, F, T, T, T, T}, "pad")
	expect_pixels(t, image.border(img, 1, RED, allocator = a), 5, {
		RED, RED, RED, RED, RED,
		RED, A, B, C, RED,
		RED, D, E, F, RED,
		RED, RED, RED, RED, RED,
	}, "a border around")
	expect_pixels(t, image.border(picture(3, {A, B, C, D, E, F, A, B, C}), 1, RED, inside = true, allocator = a), 3, {
		RED, RED, RED, RED, E, RED, RED, RED, RED,
	}, "a border inside")

	testing.expect_value(t, image.anchor_point({100, 50}, {10, 4}, .Top_Left, 3), [2]int{3, 3})
	testing.expect_value(t, image.anchor_point({100, 50}, {10, 4}, .Center, 3), [2]int{45, 23})
	testing.expect_value(t, image.anchor_point({100, 50}, {10, 4}, .Bottom_Right, 3), [2]int{87, 43})
	testing.expect_value(t, image.anchor_point({100, 50}, {10, 4}, .Top, 3), [2]int{45, 3})
}

@(test)
cut_out_joins_the_sides :: proc(t: ^testing.T) {
	// A B C
	// D E F
	img := picture(3, {A, B, C, D, E, F})
	a := context.temp_allocator
	expect_pixels(t, image.cut_out(img, 1, 1, true, a), 2, {A, C, D, F}, "the middle column")
	expect_pixels(t, image.cut_out(img, 0, 1, false, a), 3, {D, E, F}, "the first row")
	expect_pixels(t, image.cut_out(img, 2, 9, true, a), 2, {A, B, D, E}, "a band past the edge")
	expect_pixels(t, image.cut_out(img, 1, 0, true, a), 3, {A, B, C, D, E, F}, "no band")
	testing.expect_value(t, image.cut_out(img, 0, 3, true, a).width, 0)
}

@(test)
trim_bounds_finds_what_is_not_the_border :: proc(t: ^testing.T) {
	// a 5 x 4 picture of A with B and C inside: (1, 1) and (3, 2)
	img := image.create(5, 4, A, context.temp_allocator)
	pixel_set(img, 1, 1, B)
	pixel_set(img, 3, 2, C)
	testing.expect_value(t, image.trim_bounds(img), image.Rect{1, 1, 3, 2})
	// (B is 30 from A in each channel: within a tolerance of 30 only C is left)
	testing.expect_value(t, image.trim_bounds(img, 30), image.Rect{3, 2, 1, 1})
	testing.expect_value(t, image.trim_bounds(image.create(4, 4, A, context.temp_allocator)), image.Rect{})
	// (a corner that is not the border's colour: nothing is trimmed)
	pixel_set(img, 0, 0, B)
	testing.expect_value(t, image.trim_bounds(img), image.Rect{0, 0, 5, 4})
}

@(test)
edge_mean_averages_the_edge :: proc(t: ^testing.T) {
	// a 4 x 4 picture of A with an inside of RED: the edge of the whole picture is A alone
	img := image.create(4, 4, A, context.temp_allocator)
	image.fill_rect(img, {1, 1, 2, 2}, RED)
	testing.expect_value(t, image.edge_mean(img, {0, 0, 4, 4}), A)
	// (the edge of the 2 x 2 inside is RED; of a 3 x 3 from the corner: 5 of A, 3 of RED)
	testing.expect_value(t, image.edge_mean(img, {1, 1, 2, 2}), RED)
	m := image.edge_mean(img, {0, 0, 3, 3})
	testing.expect_value(t, m[3], 255)
	testing.expect_value(t, m[0], u8((5 * 10 + 3 * 255 + 4) / 8))
	testing.expect_value(t, image.edge_mean(img, {9, 9, 2, 2}), image.TRANSPARENT)
}

@(test)
colours_are_exact :: proc(t: ^testing.T) {
	half_red := image.Color{255, 0, 0, 128}
	img := picture(2, {RED, half_red, image.WHITE, image.BLACK})
	image.invert(img)
	expect_pixels(t, img, 2, {{0, 255, 255, 255}, {0, 255, 255, 128}, image.BLACK, image.WHITE}, "invert keeps alpha")

	img = picture(2, {RED, GREEN, BLUE, image.WHITE})
	image.grayscale(img)
	// (77, 150, 29 out of 256)
	expect_pixels(t, img, 2, {{77, 77, 77, 255}, {149, 149, 149, 255}, {29, 29, 29, 255}, image.WHITE}, "grayscale")

	img = picture(2, {RED, GREEN, BLUE, image.WHITE})
	image.threshold(img, 100)
	expect_pixels(t, img, 2, {image.BLACK, image.WHITE, image.BLACK, image.WHITE}, "threshold")

	img = picture(1, {image.WHITE})
	image.sepia(img)
	expect_pixels(t, img, 1, {{255, 255, 239, 255}}, "sepia of white")

	colours := []image.Color{A, B, C, D, RED, GREEN, BLUE, {200, 100, 50, 77}}
	img = picture(4, colours)
	image.saturation(img, 1)
	image.hue_rotate(img, 0)
	image.brightness_contrast(img, 0, 0)
	expect_pixels(t, img, 4, colours, "the adjustments that change nothing")

	img = picture(2, {RED, GREEN})
	image.saturation(img, 0)
	p := pixel(img, 0, 0)
	testing.expectf(t, p[0] == p[1] && p[1] == p[2], "no saturation is grey: %v", p)

	img = picture(2, {GREY, image.BLACK})
	image.brightness_contrast(img, 0.25, 0)
	testing.expect_value(t, pixel(img, 0, 0), image.Color{192, 192, 192, 255})
	image.brightness_contrast(img, 0, -1)
	testing.expect_value(t, pixel(img, 1, 0)[0], 128)
}

@(test)
draw_over_blends :: proc(t: ^testing.T) {
	a := context.temp_allocator
	dst := image.create(3, 1, image.BLACK, a)
	src := picture(2, {image.WHITE, {255, 255, 255, 128}})
	image.draw_over(dst, src, 1, 0)
	expect_pixels(t, dst, 3, {image.BLACK, image.WHITE, {128, 128, 128, 255}}, "over black")

	dst = image.create(2, 1, image.BLACK, a)
	image.draw_over(dst, picture(1, {image.WHITE}), 1, 0, 0.5)
	expect_pixels(t, dst, 2, {image.BLACK, {128, 128, 128, 255}}, "at half opacity")

	dst = image.create(1, 1, allocator = a)
	image.draw_over(dst, picture(1, {{200, 10, 10, 100}}), 0, 0)
	testing.expect_value(t, pixel(dst, 0, 0), image.Color{200, 10, 10, 100})

	dst = image.create(2, 2, image.BLACK, a)
	image.draw_over(dst, image.create(2, 2, image.WHITE, a), -1, 1)
	expect_pixels(t, dst, 2, {image.BLACK, image.BLACK, image.WHITE, image.BLACK}, "clipped")

	big := image.create(20, 10, image.BLACK, a)
	image.watermark(big, image.create(2, 2, image.WHITE, a), .Bottom_Right, 1, 1)
	testing.expect_value(t, pixel(big, 17, 7), image.WHITE)
	testing.expect_value(t, pixel(big, 18, 8), image.WHITE)
	testing.expect_value(t, pixel(big, 19, 9), image.BLACK)
	testing.expect_value(t, pixel(big, 16, 7), image.BLACK)
}

@(test)
combine_lays_out :: proc(t: ^testing.T) {
	a := context.temp_allocator
	wide := picture(2, {RED, RED})
	tall := picture(1, {GREEN, GREEN, GREEN})
	side := image.combine({wide, {}, tall}, gap = 1, background = BLUE, allocator = a)
	testing.expect_value(t, side.width, 4)
	testing.expect_value(t, side.height, 3)
	// (the short picture centred across, the gap and the margins of the background)
	expect_pixels(t, side, 4, {
		BLUE, BLUE, BLUE, GREEN,
		RED, RED, BLUE, GREEN,
		BLUE, BLUE, BLUE, GREEN,
	}, "side by side")

	stack := image.combine({wide, picture(1, {GREEN})}, vertical = true, allocator = a)
	expect_pixels(t, stack, 2, {RED, RED, GREEN, image.TRANSPARENT}, "stacked")

	none := image.combine({{}, {}}, allocator = a)
	testing.expect(t, none.pixels == nil && none.width == 0, "nothing to combine is empty")
}

@(test)
pixelate_averages :: proc(t: ^testing.T) {
	img := picture(4, {
		image.BLACK, image.WHITE, A, A,
		image.WHITE, image.BLACK, A, A,
		B, B, C, C,
		B, B, C, C,
	})
	image.pixelate(img, 2)
	m := image.Color{128, 128, 128, 255}
	expect_pixels(t, img, 4, {m, m, A, A, m, m, A, A, B, B, C, C, B, B, C, C}, "cells of 2")

	img = picture(3, {image.BLACK, image.WHITE, image.BLACK, image.WHITE, image.BLACK, image.WHITE})
	image.pixelate(img, 2, image.Rect{1, 0, 2, 1})
	expect_pixels(t, img, 3, {image.BLACK, m, m, image.WHITE, image.BLACK, image.WHITE}, "a rectangle")

	// a transparent pixel lends no colour
	img = picture(2, {RED, image.TRANSPARENT})
	image.pixelate(img, 2)
	testing.expect_value(t, pixel(img, 1, 0), image.Color{255, 0, 0, 128})
}

@(test)
resize_keeps_flat_colours :: proc(t: ^testing.T) {
	a := context.temp_allocator
	c := image.Color{10, 200, 30, 255}
	img := image.create(37, 23, c, a)
	sizes := [][2]int{{10, 7}, {80, 50}, {37, 5}, {1, 1}, {100, 23}}
	for filter in image.Filter {
		for size in sizes {
			out := image.resize(img, size.x, size.y, filter, a)
			testing.expectf(t, out.width == size.x && out.height == size.y, "%v %v: %d x %d", filter, size, out.width, out.height)
			testing.expectf(t, flat(out, c), "%v %v: flat", filter, size)
		}
	}
	// the colour of a half transparent picture stays: alpha weighs, it does not darken
	ghost := image.create(16, 16, {200, 100, 0, 100}, a)
	testing.expect(t, flat(image.resize(ghost, 5, 7, .Lanczos3, a), {200, 100, 0, 100}))

	// a box halves 2 x 2 blocks into their colours
	blocks := picture(4, {A, A, B, B, A, A, B, B, C, C, D, D, C, C, D, D})
	expect_pixels(t, image.resize(blocks, 2, 2, .Box, a), 2, {A, B, C, D}, "box halves")

	s := image.scale(img, 0.5, allocator = a)
	testing.expect_value(t, s.width, 19)
	testing.expect_value(t, s.height, 12)
	testing.expect_value(t, image.resize(img, 0, 5, allocator = a).width, 0)
}

@(test)
blur_keeps_the_sum :: proc(t: ^testing.T) {
	a := context.temp_allocator
	img := image.create(61, 61, image.BLACK, a)
	for y in 28 ..< 33 { for x in 28 ..< 33 { pixel_set(img, x, y, image.WHITE) } }
	out := image.blur(img, 8, a)
	sum, before := 0, 25 * 255
	for p in pixels_of(out) { sum += int(p[0]) }
	testing.expectf(t, abs(sum - before) < before / 50, "the sum: %d, was %d", sum, before)
	centre := pixel(out, 30, 30)[0]
	testing.expectf(t, centre > 0 && centre < 255, "spread: %d", centre)
	testing.expect_value(t, pixel(out, 30, 30)[3], 255)
	testing.expect_value(t, pixel(out, 0, 0), image.BLACK)
	testing.expectf(t, pixel(out, 22, 30)[0] < pixel(out, 26, 30)[0], "fades outward")

	flat_colour := image.Color{90, 60, 30, 255}
	testing.expect(t, flat(image.blur(image.create(30, 20, flat_colour, a), 5, a), flat_colour))

	sharp := image.create(30, 20, flat_colour, a)
	image.sharpen(sharp, 1)
	testing.expect(t, flat(sharp, flat_colour), "sharpen leaves a flat picture")

	edge := image.create(20, 4, GREY, a)
	for y in 0 ..< 4 { for x in 10 ..< 20 { pixel_set(edge, x, y, {200, 200, 200, 255}) } }
	image.sharpen(edge, 1)
	testing.expectf(t, pixel(edge, 9, 1)[0] < 128 && pixel(edge, 10, 1)[0] > 200, "the edge is steeper: %v %v", pixel(edge, 9, 1), pixel(edge, 10, 1))
	testing.expect_value(t, pixel(edge, 0, 1), GREY)
}

@(test)
looks_have_their_shape :: proc(t: ^testing.T) {
	a := context.temp_allocator
	img := image.create(40, 30, RED, a)

	round := image.round_corners(img, 10, a)
	testing.expect_value(t, pixel(round, 0, 0)[3], 0)
	testing.expect_value(t, pixel(round, 39, 29)[3], 0)
	testing.expect_value(t, pixel(round, 39, 0)[3], 0)
	testing.expect_value(t, pixel(round, 20, 15), RED)
	testing.expect_value(t, pixel(round, 20, 0), RED)
	testing.expect_value(t, pixel(round, 0, 15), RED)
	// (its centre 9.9 pixels from the arc's: on the edge)
	edge := pixel(round, 2, 3)[3]
	testing.expectf(t, edge > 0 && edge < 255, "antialiased: %d", edge)

	shadow := image.drop_shadow(img, {4, 6}, 10, {0, 0, 0, 200}, a)
	testing.expectf(t, shadow.width > 44 && shadow.height > 36, "the shadow's room: %d x %d", shadow.width, shadow.height)
	// the picture whole, where the shadow left it room
	x0, y0 := -1, -1
	for p, i in pixels_of(shadow) { if p == RED { x0, y0 = i % shadow.width, i / shadow.width; break } }
	testing.expect(t, x0 >= 0)
	for y in 0 ..< 30 { for x in 0 ..< 40 { if pixel(shadow, x0 + x, y0 + y) != RED { testing.expect(t, false, "the picture is whole"); return } } }
	below := pixel(shadow, x0 + 20, y0 + 31)
	testing.expectf(t, below[3] > 0 && below[0] == 0, "the shadow below: %v", below)
	testing.expect_value(t, pixel(shadow, 0, 0)[3], 0)

	back := image.background(img, 5, image.solid(BLUE), a)
	testing.expect_value(t, back.width, 50)
	testing.expect_value(t, back.height, 40)
	testing.expect_value(t, pixel(back, 0, 0), BLUE)
	testing.expect_value(t, pixel(back, 25, 20), RED)

	gradient := image.background(img, 20, {from = image.BLACK, to = image.WHITE, angle = 90}, a)
	l, r := pixel(gradient, 0, 0), pixel(gradient, gradient.width - 1, 0)
	testing.expectf(t, l[0] < 10 && r[0] > 245, "left to right: %v %v", l, r)
	testing.expect_value(t, pixel(gradient, 2, 0), pixel(gradient, 2, gradient.height - 1))
	up := image.background(img, 20, {from = image.BLACK, to = image.WHITE, angle = 0}, a)
	testing.expectf(t, pixel(up, 0, 0)[0] > 245 && pixel(up, 0, up.height - 1)[0] < 10, "upward")
}

@(test)
text_is_drawn_at_its_anchor :: proc(t: ^testing.T) {
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	face, ok := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "the embedded face") { return }
	a := context.temp_allocator

	mark := image.text_image(&fonts, face, "cliche", 20, image.WHITE, a)
	testing.expectf(t, mark.width > 30 && mark.height >= 20, "its size: %d x %d", mark.width, mark.height)
	inked := 0
	for p in pixels_of(mark) { if p[3] > 128 { inked += 1 } }
	testing.expectf(t, inked > 40, "the letters: %d", inked)
	testing.expect_value(t, image.text_image(nil, face, "cliche", 20, image.WHITE, a).width, 0)

	img := image.create(300, 100, image.BLACK, a)
	image.watermark_text(img, &fonts, face, "cliche", 20, image.WHITE, .Bottom_Right, 10, 1)
	left, top := img.width, img.height
	for p, i in pixels_of(img) {
		if p[0] > 128 { left, top = min(left, i % img.width), min(top, i / img.width) }
	}
	testing.expectf(t, left > 150 && top > 50, "at the bottom right: from %d, %d", left, top)
}
