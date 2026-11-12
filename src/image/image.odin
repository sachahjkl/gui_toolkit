// image: transformations of RGBA8 pictures on the CPU, for a screenshot before it is saved or sent: crop, resize, rotate,
// margins, borders, rounded corners, a shadow, a background, colour adjustments, blur, sharpen, pixelate, one picture
// over another, a watermark. Pure Odin, any target, deterministic. Every procedure blocks for the time of a pass over the
// pixels: a program calls them on a worker. See docs/image.md.
//
// Pixels are packed RGBA8 with straight alpha, as png.decode and capture give them. A procedure that returns an Image
// makes a new one in its allocator and leaves its input alone; a procedure that returns nothing changes its input.
package tk_image

import "base:runtime"

// A picture: width * height pixels, 4 bytes each (red, green, blue, alpha; alpha not premultiplied), row after row, no
// padding. Its pixels belong to the allocator that made them.
Image :: struct {
	pixels:        []u8,
	width, height: int,
}

// A colour: red, green, blue, alpha, 0 to 255, alpha not premultiplied.
Color :: [4]u8

TRANSPARENT :: Color{}
BLACK :: Color{0, 0, 0, 255}
WHITE :: Color{255, 255, 255, 255}

// 0xRRGGBB and an alpha of 0 to 255, as a Color.
hex :: proc(rgb: u32, alpha: u8 = 255) -> Color {
	return {u8(rgb >> 16), u8(rgb >> 8), u8(rgb), alpha}
}

// A rectangle of pixels.
Rect :: struct {
	x, y, w, h: int,
}

// A picture of `width` x `height` filled with `color` (transparent by default). A size below 1 gives an empty picture.
create :: proc(width, height: int, color := TRANSPARENT, allocator := context.allocator) -> Image {
	if width <= 0 || height <= 0 { return {} }
	img := Image{pixels = make([]u8, width * height * 4, allocator), width = width, height = height}
	if color != TRANSPARENT { fill_rect(img, {0, 0, width, height}, color) }
	return img
}

// A copy of `img`.
clone :: proc(img: Image, allocator := context.allocator) -> Image {
	if img.width <= 0 || img.height <= 0 { return {} }
	out := Image{pixels = make([]u8, img.width * img.height * 4, allocator), width = img.width, height = img.height}
	copy(out.pixels, img.pixels)
	return out
}

// Frees the pixels (made in `allocator`) and empties the picture.
destroy :: proc(img: ^Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// The pixels as 32-bit words, one per pixel, for the loops that move whole pixels.
@(private)
words :: #force_inline proc "contextless" (img: Image) -> []u32 {
	return transmute([]u32)runtime.Raw_Slice{data = raw_data(img.pixels), len = img.width * img.height}
}

@(private)
word_of :: #force_inline proc "contextless" (c: Color) -> u32 {
	return transmute(u32)c
}

// `r` cut to the picture.
@(private)
clip_rect :: proc(img: Image, r: Rect) -> Rect {
	x0, y0 := max(r.x, 0), max(r.y, 0)
	x1, y1 := min(r.x + r.w, img.width), min(r.y + r.h, img.height)
	if x1 <= x0 || y1 <= y0 { return {} }
	return {x0, y0, x1 - x0, y1 - y0}
}

// Every pixel of `r` (cut to the picture) becomes `color`.
fill_rect :: proc(img: Image, r: Rect, color: Color) #no_bounds_check {
	c := clip_rect(img, r)
	if c.w == 0 { return }
	px := words(img)
	v := word_of(color)
	for y in c.y ..< c.y + c.h {
		row := px[y * img.width + c.x:][:c.w]
		for &p in row { p = v }
	}
}

// Whether `img` has the size its pixels claim: the procedures do nothing with (or return an empty copy of) one that does not.
@(private)
valid :: proc(img: Image) -> bool {
	return img.width > 0 && img.height > 0 && len(img.pixels) >= img.width * img.height * 4
}
