package tk_ocr

// What an engine reads: one byte a pixel, dark text on a light ground, its contrast stretched, scaled up when its text is
// small. Engines are trained on print: black on white, letters 20 to 30 pixels tall. A screen gives text of 10 to 16
// pixels, often light on a dark theme. Pure: tests/ocr checks each step.

import "core:math"
import "core:slice"

Prepared :: struct {
	gray:          []u8,   // width * height, row-major, no padding
	width, height: int,
	scale:         int,    // the picture given, this many times as large (1, 2 or 3)
	inverted:      bool,   // its ground was dark
}

// A line of text shorter than this many pixels (its ascenders to its descenders) is scaled by 2...
SMALL_TEXT :: 20
// ... and one shorter than this by 3.
TINY_TEXT :: 10
// A scaled picture stays under this many pixels: the scale goes down to fit (to 1 at worst).
MAX_PIXELS :: 40_000_000
// A grey darker than this is ink, once the ground is light.
INK :: 128
// A band of rows with ink thinner than this is a rule or an underline, not a line of text.
MIN_LINE :: 3
// A column with ink on more than this share of the rows is a border or a rule: text_height does not look at it.
RULE_SHARE :: 0.8

// `max_side`: the longest side the engine takes (0: no limit); the scale goes down to fit it.
prepare :: proc(pixels: []u8, width, height, stride: int, format: Format, max_side := 0, allocator := context.allocator) -> Prepared {
	gray := grayscale(pixels, width, height, stride, format, allocator)
	inverted := dark_background(gray)
	if inverted { for &v in gray { v = 255 - v } }
	stretch_contrast(gray)
	scale := upscale_factor(text_height(gray, width, height), width, height, max_side)
	if scale > 1 {
		larger := upscale(gray, width, height, scale, allocator)
		delete(gray, allocator)
		gray = larger
	}
	return {gray = gray, width = width * scale, height = height * scale, scale = scale, inverted = inverted}
}

prepared_destroy :: proc(p: ^Prepared, allocator := context.allocator) {
	delete(p.gray, allocator)
	p^ = {}
}

// The luminance of each pixel (ITU-R BT.601's weights, in 8-bit fixed point), alpha not read.
grayscale :: proc(pixels: []u8, width, height, stride: int, format: Format, allocator := context.allocator) -> []u8 {
	gray := make([]u8, width * height, allocator)
	r, b := 0, 2
	if format == .BGRA { r, b = 2, 0 }
	for y in 0 ..< height {
		row := pixels[y * stride:]
		for x in 0 ..< width {
			p := row[x * 4:]
			gray[y * width + x] = u8((77 * u32(p[r]) + 150 * u32(p[1]) + 29 * u32(p[b])) >> 8)
		}
	}
	return gray
}

// Whether the ground is dark: the most common grey, in 16 steps, is in the darker half. Text covers less of a region
// than its ground: the most common grey is the ground's.
dark_background :: proc(gray: []u8) -> bool {
	steps: [16]int
	for v in gray { steps[v >> 4] += 1 }
	most := 0
	for n, i in steps { if n > steps[most] { most = i } }
	return most < 8
}

// The greys stretched so that the darkest 1 % become black and the lightest 1 % white: a grey theme's text on its grey
// ground becomes black on white. A picture of one grey (less than 16 steps apart) stays as it is.
stretch_contrast :: proc(gray: []u8) {
	if len(gray) == 0 { return }
	counts: [256]int
	for v in gray { counts[v] += 1 }
	low, high := 0, 255
	seen := 0
	for n, v in counts {
		seen += n
		if seen * 100 > len(gray) { low = v; break }
	}
	seen = 0
	#reverse for n, v in counts {
		seen += n
		if seen * 100 > len(gray) { high = v; break }
	}
	if high - low < 16 { return }
	for &v in gray { v = u8(clamp((int(v) - low) * 255 / (high - low), 0, 255)) }
}

// The height of the picture's lines of text, in pixels: the median of the bands of rows that have ink (dark text on a
// light ground), the bands thinner than MIN_LINE and the columns of borders left out. 0: no text seen.
text_height :: proc(gray: []u8, width, height: int) -> int {
	if width <= 0 || height <= 0 { return 0 }
	column_ink := make([]int, width, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width { if gray[y * width + x] < INK { column_ink[x] += 1 } }
	}
	rule := make([]bool, width, context.temp_allocator)
	for n, x in column_ink { rule[x] = f64(n) > RULE_SHARE * f64(height) }
	bands := make([dynamic]int, context.temp_allocator)
	run := 0
	for y in 0 ..= height {
		ink := false
		if y < height {
			for x in 0 ..< width { if !rule[x] && gray[y * width + x] < INK { ink = true; break } }
		}
		if ink { run += 1; continue }
		if run >= MIN_LINE { append(&bands, run) }
		run = 0
	}
	if len(bands) == 0 { return 0 }
	// (a median, not a mean: a heading or two lines that touch do not move it)
	slice.sort(bands[:])
	return bands[len(bands) / 2]
}

// The scale an engine reads a picture at, from the height of its lines (text_height): 3 under TINY_TEXT, 2 under
// SMALL_TEXT, else 1 (and 1 when no text was seen); lowered until the picture stays under MAX_PIXELS and its sides at
// most `max_side` (0: no limit).
upscale_factor :: proc(line_height, width, height: int, max_side := 0) -> int {
	scale := 1
	if line_height > 0 && line_height < TINY_TEXT {
		scale = 3
	} else if line_height > 0 && line_height < SMALL_TEXT {
		scale = 2
	}
	for scale > 1 && (width * height * scale * scale > MAX_PIXELS || (max_side > 0 && max(width, height) * scale > max_side)) {
		scale -= 1
	}
	return scale
}

// `gray` `scale` times as large, by bilinear interpolation: the edges of letters stay smooth, which engines read better
// than the steps of nearest-neighbour pixels.
upscale :: proc(gray: []u8, width, height, scale: int, allocator := context.allocator) -> []u8 {
	w, h := width * scale, height * scale
	out := make([]u8, w * h, allocator)
	for y in 0 ..< h {
		sy := clamp((f32(y) + 0.5) / f32(scale) - 0.5, 0, f32(height - 1))
		y0 := int(sy)
		y1 := min(y0 + 1, height - 1)
		fy := sy - f32(y0)
		for x in 0 ..< w {
			sx := clamp((f32(x) + 0.5) / f32(scale) - 0.5, 0, f32(width - 1))
			x0 := int(sx)
			x1 := min(x0 + 1, width - 1)
			fx := sx - f32(x0)
			top := f32(gray[y0 * width + x0]) * (1 - fx) + f32(gray[y0 * width + x1]) * fx
			bottom := f32(gray[y1 * width + x0]) * (1 - fx) + f32(gray[y1 * width + x1]) * fx
			out[y * w + x] = u8(math.round(top * (1 - fy) + bottom * fy))
		}
	}
	return out
}
