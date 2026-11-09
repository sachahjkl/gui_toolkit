package tk_paint

import "core:encoding/endian"
import "core:math"
import "core:os"
import png "../png"

// The canvas as 8-bit RGBA, not premultiplied, row by row from the top. A transparent pixel is all zeros.
to_rgba8 :: proc(c: Canvas, allocator := context.allocator) -> []u8 {
	out := make([]u8, c.width * c.height * 4, allocator)
	for p, i in c.pixels {
		a := clamp(p.a, 0, 1)
		a8 := u8(math.round(a * 255))
		if a8 == 0 { continue }
		for k in 0 ..< 3 { out[i * 4 + k] = u8(math.round(clamp(p[k] / a, 0, 1) * 255)) }
		out[i * 4 + 3] = a8
	}
	return out
}

// 8-bit RGBA, not premultiplied, as a canvas.
from_rgba8 :: proc(rgba: []u8, width, height: int, allocator := context.allocator) -> Canvas {
	c := canvas_make(width, height, allocator)
	for &p, i in c.pixels {
		a := f32(rgba[i * 4 + 3]) / 255
		p = {f32(rgba[i * 4]) / 255 * a, f32(rgba[i * 4 + 1]) / 255 * a, f32(rgba[i * 4 + 2]) / 255 * a, a}
	}
	return c
}

// The canvas as a PNG file (8-bit RGBA, png.encode's .Small: a file to keep).
png_encode :: proc(c: Canvas, allocator := context.allocator) -> []u8 {
	return png.encode(to_rgba8(c, context.temp_allocator), c.width, c.height, .Small, allocator)
}

// A PNG file (any colour type, bit depth or palette png.decode reads) as a canvas.
png_decode :: proc(data: []u8, allocator := context.allocator) -> (c: Canvas, ok: bool) {
	rgba, w, h, decoded := png.decode(data, context.temp_allocator)
	if !decoded { return }
	return from_rgba8(rgba, w, h, allocator), true
}

// The canvas as a PNG file at `path`.
write_png :: proc(c: Canvas, path: string) -> bool {
	data := png_encode(c, context.temp_allocator)
	return os.write_entire_file(path, data) == nil
}

// A picture of an .ico file: a PNG file (png_encode) or a classic DIB (dib_encode), `size` pixels square.
Ico_Entry :: struct {
	size: int,
	data: []u8,
}

@(private = "file") ICO_HEADER :: 6
@(private = "file") ICO_ENTRY :: 16
@(private = "file") ICO_TYPE_ICON :: 1
@(private = "file") ICO_PLANES :: 1
@(private = "file") ICO_BITS :: 32

// An .ico file of the pictures, in their order: a header, a 16-byte entry each (a size of 256 or more is said 0), the data.
ico_encode :: proc(entries: []Ico_Entry, allocator := context.allocator) -> []u8 {
	total := ICO_HEADER + ICO_ENTRY * len(entries)
	for e in entries { total += len(e.data) }
	out := make([]u8, total, allocator)
	endian.put_u16(out[0:], .Little, 0)
	endian.put_u16(out[2:], .Little, ICO_TYPE_ICON)
	endian.put_u16(out[4:], .Little, u16(len(entries)))
	offset := ICO_HEADER + ICO_ENTRY * len(entries)
	for e, i in entries {
		d := out[ICO_HEADER + ICO_ENTRY * i:]
		dim := e.size >= 256 ? 0 : u8(e.size)
		d[0], d[1], d[2], d[3] = dim, dim, 0, 0
		endian.put_u16(d[4:], .Little, ICO_PLANES)
		endian.put_u16(d[6:], .Little, ICO_BITS)
		endian.put_u32(d[8:], .Little, u32(len(e.data)))
		endian.put_u32(d[12:], .Little, u32(offset))
		copy(out[offset:], e.data)
		offset += len(e.data)
	}
	return out
}

@(private = "file") BITMAPINFOHEADER_BYTES :: 40

// The canvas as the classic picture of an .ico: a BITMAPINFOHEADER (the height doubled for the mask), BGRA rows from the
// bottom, not premultiplied, then an empty AND mask (rows of whole 32-bit words).
dib_encode :: proc(c: Canvas, allocator := context.allocator) -> []u8 {
	rgba := to_rgba8(c, context.temp_allocator)
	mask_row := (c.width + 31) / 32 * 4
	out := make([]u8, BITMAPINFOHEADER_BYTES + c.width * c.height * 4 + mask_row * c.height, allocator)
	endian.put_u32(out[0:], .Little, BITMAPINFOHEADER_BYTES)
	endian.put_i32(out[4:], .Little, i32(c.width))
	endian.put_i32(out[8:], .Little, i32(2 * c.height))
	endian.put_u16(out[12:], .Little, 1)
	endian.put_u16(out[14:], .Little, ICO_BITS)
	at := BITMAPINFOHEADER_BYTES
	for y := c.height - 1; y >= 0; y -= 1 {
		for x in 0 ..< c.width {
			p := rgba[(y * c.width + x) * 4:]
			out[at], out[at + 1], out[at + 2], out[at + 3] = p[2], p[1], p[0], p[3]
			at += 4
		}
	}
	return out
}
