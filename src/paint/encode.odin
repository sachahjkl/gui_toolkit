package tk_paint

import "core:encoding/endian"
import "core:hash"
import "core:image/png"
import "core:math"
import "core:os"
import "../flate"

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

// PNG: what a file holds besides the compressed rows.
@(private = "file") PNG_SIGNATURE :: [8]u8{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}
@(private = "file") PNG_IHDR_BYTES :: 13
@(private = "file") PNG_BIT_DEPTH :: 8
@(private = "file") PNG_COLOR_RGBA :: 6
@(private = "file") PNG_FILTERS :: 5   // None, Sub, Up, Average, Paeth

// The canvas as a PNG file (8-bit RGBA). Each row takes the filter whose bytes add up least as signed values (the
// usual guess at what compresses best), then flate.deflate.
png_encode :: proc(c: Canvas, allocator := context.allocator) -> []u8 {
	pixels := to_rgba8(c, context.temp_allocator)
	stride := c.width * 4
	raw := make([]u8, (stride + 1) * c.height, context.temp_allocator)
	trial := make([]u8, stride, context.temp_allocator)
	zero := make([]u8, stride, context.temp_allocator)
	for y in 0 ..< c.height {
		row := pixels[y * stride:][:stride]
		up := y > 0 ? pixels[(y - 1) * stride:][:stride] : zero
		out := raw[y * (stride + 1):][:stride + 1]
		best := max(int)
		for f in 0 ..< PNG_FILTERS {
			score := 0
			for x in 0 ..< stride {
				a := x >= 4 ? row[x - 4] : 0
				b := up[x]
				cc := x >= 4 ? up[x - 4] : 0
				v: u8
				switch f {
				case 0: v = row[x]
				case 1: v = row[x] - a
				case 2: v = row[x] - b
				case 3: v = row[x] - u8((int(a) + int(b)) / 2)
				case 4: v = row[x] - paeth(a, b, cc)
				}
				trial[x] = v
				score += int(abs(i8(v)))
			}
			if score < best {
				best = score
				out[0] = u8(f)
				copy(out[1:], trial)
			}
		}
	}
	z := flate.deflate(.Zlib, raw, context.temp_allocator)
	buf := make([dynamic]u8, 0, len(z) + 64, allocator)
	signature := PNG_SIGNATURE
	append(&buf, ..signature[:])
	ihdr: [PNG_IHDR_BYTES]u8
	endian.put_u32(ihdr[0:], .Big, u32(c.width))
	endian.put_u32(ihdr[4:], .Big, u32(c.height))
	ihdr[8], ihdr[9] = PNG_BIT_DEPTH, PNG_COLOR_RGBA
	chunk(&buf, "IHDR", ihdr[:])
	chunk(&buf, "IDAT", z)
	chunk(&buf, "IEND", nil)
	return buf[:]
}

@(private = "file")
paeth :: proc(a, b, c: u8) -> u8 {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
	if pa <= pb && pa <= pc { return a }
	if pb <= pc { return b }
	return c
}

@(private = "file")
chunk :: proc(buf: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	endian.put_u32(n[:], .Big, u32(len(data)))
	append(buf, ..n[:])
	start := len(buf)
	append(buf, kind)
	append(buf, ..data)
	endian.put_u32(n[:], .Big, hash.crc32(buf[start:]))
	append(buf, ..n[:])
}

// A PNG file (any colour type core:image/png reads) as a canvas.
png_decode :: proc(data: []u8, allocator := context.allocator) -> (c: Canvas, ok: bool) {
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing})
	if err != nil { return }
	defer png.destroy(img)
	if img.depth != 8 || img.channels != 4 { return }
	return from_rgba8(img.pixels[:], img.width, img.height, allocator), true
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
