package devtools

import "core:hash"
import "../flate"

// RGBA8 rows to a PNG (8 bits, colour type 6): each row filtered with Sub (neighbouring pixels of an interface are often
// equal: runs of zeros the deflater packs), one IDAT.
png_encode :: proc(pixels: []u8, w, h: int, allocator := context.allocator) -> []u8 {
	stride := w * 4
	raw := make([]u8, (stride + 1) * h, context.temp_allocator)
	for y in 0 ..< h {
		row := pixels[y * stride:][:stride]
		out := raw[y * (stride + 1):][:stride + 1]
		out[0] = 1   // Sub
		for x in 0 ..< stride { out[1 + x] = row[x] - (x >= 4 ? row[x - 4] : 0) }
	}
	z := flate.deflate(.Zlib, raw, context.temp_allocator)
	buf := make([dynamic]u8, 0, len(z) + 64, allocator)
	append(&buf, 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A)
	ihdr: [13]u8
	be32(ihdr[0:], u32(w))
	be32(ihdr[4:], u32(h))
	ihdr[8], ihdr[9] = 8, 6
	chunk(&buf, "IHDR", ihdr[:])
	chunk(&buf, "IDAT", z)
	chunk(&buf, "IEND", nil)
	return buf[:]
}

@(private)
be32 :: proc(b: []u8, v: u32) { b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v) }

@(private)
chunk :: proc(buf: ^[dynamic]u8, kind: string, data: []u8) {
	n: [4]u8
	be32(n[:], u32(len(data)))
	append(buf, ..n[:])
	start := len(buf)
	append(buf, ..transmute([]u8)kind)
	append(buf, ..data)
	crc := hash.crc32(buf[start:])
	be32(n[:], crc)
	append(buf, ..n[:])
}
