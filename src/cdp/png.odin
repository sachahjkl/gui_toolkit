package tk_cdp

// The pictures of a run: PNG read and written (the toolkit's png package), two compared, one made smaller.

import "core:os"
import png "../png"

// RGBA, 8 bits a channel, rows from the top.
Picture :: struct {
	width, height: int,
	pixels:        []u8,
}

picture_destroy :: proc(p: ^Picture) {
	delete(p.pixels)
	p^ = {}
}

// A PNG's pixels as RGBA8, whatever its own format (grey, RGB, a palette, 16 bits).
png_decode :: proc(data: []byte, allocator := context.allocator) -> (p: Picture, ok: bool) {
	p.pixels, p.width, p.height = png.decode(data, allocator) or_return
	return p, true
}

png_read :: proc(path: string, allocator := context.allocator) -> (p: Picture, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	return png_decode(data, allocator)
}

// RGBA8 as a PNG, png.encode's .Small: what is kept should be small.
png_encode :: proc(p: Picture, allocator := context.allocator) -> (data: []byte, ok: bool) {
	data = png.encode(p.pixels, p.width, p.height, .Small, allocator)
	return data, data != nil
}

png_write :: proc(path: string, p: Picture) -> bool {
	data, ok := png_encode(p, context.temp_allocator)
	return ok && os.write_entire_file(path, data) == nil
}

Comparison :: struct {
	size_differs: bool,
	share:        f64,       // of the pixels that differ by more than the delta on a channel
	diff:         Picture,   // where: red; the rest the first picture's green, dimmed (the caller's to destroy)
}

// How two pictures differ: the share of their pixels that differ by more than `delta` (of 255) on a colour channel.
compare :: proc(a, b: Picture, delta: int, allocator := context.allocator) -> (r: Comparison) {
	if a.width != b.width || a.height != b.height { r.size_differs = true; return }
	r.diff = {a.width, a.height, make([]u8, len(a.pixels), allocator)}
	n := 0
	for i := 0; i < len(a.pixels); i += 4 {
		d := max(abs(int(a.pixels[i]) - int(b.pixels[i])), abs(int(a.pixels[i + 1]) - int(b.pixels[i + 1])), abs(int(a.pixels[i + 2]) - int(b.pixels[i + 2])))
		if d > delta {
			n += 1
			r.diff.pixels[i], r.diff.pixels[i + 3] = 255, 255
		} else {
			g := a.pixels[i + 1] >> 2
			r.diff.pixels[i], r.diff.pixels[i + 1], r.diff.pixels[i + 2], r.diff.pixels[i + 3] = g, g, g, 255
		}
	}
	r.share = f64(n) / f64(max(a.width * a.height, 1))
	return
}

// The picture `width` pixels wide, each pixel the mean of the area of the original it covers (a box filter: what a picture
// made smaller needs, with no ringing). A picture as wide or narrower is copied.
shrink :: proc(p: Picture, width: int, allocator := context.allocator) -> Picture {
	if width <= 0 || width >= p.width {
		out := Picture{p.width, p.height, make([]u8, len(p.pixels), allocator)}
		copy(out.pixels, p.pixels)
		return out
	}
	height := max(1, int(f64(p.height) * f64(width) / f64(p.width) + 0.5))
	out := Picture{width, height, make([]u8, width * height * 4, allocator)}
	sx := f64(p.width) / f64(width)
	sy := f64(p.height) / f64(height)
	for y in 0 ..< height {
		y0, y1 := f64(y) * sy, f64(y + 1) * sy
		for x in 0 ..< width {
			x0, x1 := f64(x) * sx, f64(x + 1) * sx
			sum: [4]f64
			for yy := int(y0); f64(yy) < y1 && yy < p.height; yy += 1 {
				wy := min(f64(yy + 1), y1) - max(f64(yy), y0)
				for xx := int(x0); f64(xx) < x1 && xx < p.width; xx += 1 {
					w := wy * (min(f64(xx + 1), x1) - max(f64(xx), x0))
					at := (yy * p.width + xx) * 4
					a := f64(p.pixels[at + 3]) / 255
					// (colour weighted by its alpha: a transparent pixel's colour does not bleed)
					sum[0] += f64(p.pixels[at]) * a * w
					sum[1] += f64(p.pixels[at + 1]) * a * w
					sum[2] += f64(p.pixels[at + 2]) * a * w
					sum[3] += a * w
				}
			}
			at := (y * width + x) * 4
			area := sx * sy
			alpha := sum[3] / area
			for ch in 0 ..< 3 { out.pixels[at + ch] = alpha > 0 ? u8(clamp(sum[ch] / sum[3] + 0.5, 0, 255)) : 0 }
			out.pixels[at + 3] = u8(clamp(alpha * 255 + 0.5, 0, 255))
		}
	}
	return out
}
