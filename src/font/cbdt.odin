#+build !windows
package font

import "base:runtime"
import "core:image"
import "core:image/png"
import "core:math"

// Bitmap color glyphs off Windows: the CBLC / CBDT tables (Noto Color Emoji as most Linux systems ship it), PNG images at
// fixed sizes. The nearest strike at or above the size asked for is decoded and scaled. Windows has Direct2D for these.
// Everything read is bounds-checked: a font is untrusted input, and a glyph that does not read is no color glyph.

@(private = "file") CBLC_HEADER_BYTES :: 8
@(private = "file") BITMAP_SIZE_BYTES :: 48
@(private = "file") INDEX_ARRAY_ENTRY_BYTES :: 8
@(private = "file") INDEX_HEADER_BYTES :: 8
@(private = "file") BIG_METRICS_BYTES :: 8
@(private = "file") SMALL_METRICS_BYTES :: 5
@(private = "file") CBDT_PNG_MAX_BYTES :: 8 * 1024 * 1024
@(private = "file") CBDT_SCALED_MAX_PX :: 1024

@(private = "file")
be16 :: proc(d: []u8, o: int) -> (v: int, ok: bool) {
	if o < 0 || o + 2 > len(d) { return }
	return int(d[o]) << 8 | int(d[o + 1]), true
}

@(private = "file")
be32 :: proc(d: []u8, o: int) -> (v: int, ok: bool) {
	if o < 0 || o + 4 > len(d) { return }
	return int(d[o]) << 24 | int(d[o + 1]) << 16 | int(d[o + 2]) << 8 | int(d[o + 3]), true
}

@(private = "file")
Cbdt_Metrics :: struct { w, h, bx, by: int }

@(private = "file")
Cbdt_Glyph :: struct {
	png:     []u8,
	metrics: Cbdt_Metrics,
	ppem:    int,
}

// The strike to draw `size` from: the smallest at or above it, else the largest. -1: none.
@(private = "file")
cbdt_strike :: proc(cblc: []u8, size: f32) -> int {
	n, ok := be32(cblc, 4)
	if !ok { return -1 }
	best, best_ppem := -1, 0
	for i in 0 ..< n {
		o := CBLC_HEADER_BYTES + i * BITMAP_SIZE_BYTES
		if o + BITMAP_SIZE_BYTES > len(cblc) { break }
		ppem := int(cblc[o + 45])
		if best < 0 { best, best_ppem = i, ppem; continue }
		above, best_above := f32(ppem) >= size, f32(best_ppem) >= size
		if (above && (!best_above || ppem < best_ppem)) || (!above && !best_above && ppem > best_ppem) { best, best_ppem = i, ppem }
	}
	return best
}

// Where glyph `gid` lies in CBDT: its offset and length in the table, and its metrics when the index holds them.
@(private = "file")
cbdt_locate :: proc(cblc: []u8, strike, gid: int) -> (offset, length, format: int, big: Cbdt_Metrics, found: bool) {
	s := CBLC_HEADER_BYTES + strike * BITMAP_SIZE_BYTES
	array := be32(cblc, s) or_return
	count := be32(cblc, s + 8) or_return
	for i in 0 ..< count {
		e := array + i * INDEX_ARRAY_ENTRY_BYTES
		first := be16(cblc, e) or_return
		last := be16(cblc, e + 2) or_return
		if gid < first || gid > last { continue }
		add := be32(cblc, e + 4) or_return
		h := array + add
		kind := be16(cblc, h) or_return
		format = be16(cblc, h + 2) or_return
		base := be32(cblc, h + 4) or_return
		at := h + INDEX_HEADER_BYTES
		metrics :: proc(d: []u8, o: int) -> (m: Cbdt_Metrics, ok: bool) {
			if o < 0 || o + BIG_METRICS_BYTES > len(d) { return }
			return {int(d[o + 1]), int(d[o]), int(i8(d[o + 2])), int(i8(d[o + 3]))}, true
		}
		switch kind {
		case 1:
			a := be32(cblc, at + (gid - first) * 4) or_return
			b := be32(cblc, at + (gid - first + 1) * 4) or_return
			return base + a, b - a, format, {}, b > a
		case 3:
			a := be16(cblc, at + (gid - first) * 2) or_return
			b := be16(cblc, at + (gid - first + 1) * 2) or_return
			return base + a, b - a, format, {}, b > a
		case 2:
			size := be32(cblc, at) or_return
			big = metrics(cblc, at + 4) or_return
			return base + (gid - first) * size, size, format, big, size > 0
		case 4:
			n := be32(cblc, at) or_return
			for k in 0 ..< n {
				p := at + 4 + k * 4
				g := be16(cblc, p) or_return
				if g != gid { continue }
				a := be16(cblc, p + 2) or_return
				b := be16(cblc, p + 6) or_return
				return base + a, b - a, format, {}, b > a
			}
			return
		case 5:
			size := be32(cblc, at) or_return
			big = metrics(cblc, at + 4) or_return
			n := be32(cblc, at + 4 + BIG_METRICS_BYTES) or_return
			ids := at + 8 + BIG_METRICS_BYTES
			for k in 0 ..< n {
				g := be16(cblc, ids + k * 2) or_return
				if g == gid { return base + k * size, size, format, big, size > 0 }
			}
			return
		}
		return
	}
	return
}

// The PNG of a glyph at the strike for `size`.
@(private = "file")
cbdt_glyph :: proc(fc: ^Face_Colr, gid: u16, size: f32) -> (g: Cbdt_Glyph, ok: bool) {
	strike := cbdt_strike(fc.cblc, size)
	if strike < 0 { return }
	off, length, format, big := cbdt_locate(fc.cblc, strike, int(gid)) or_return
	d := fc.cbdt
	if off < 0 || length <= 0 || off + length > len(d) { return }
	entry := d[off:off + length]
	g.ppem = int(fc.cblc[CBLC_HEADER_BYTES + strike * BITMAP_SIZE_BYTES + 45])
	at: int
	switch format {
	case 17:
		if len(entry) < SMALL_METRICS_BYTES { return }
		g.metrics = {int(entry[1]), int(entry[0]), int(i8(entry[2])), int(i8(entry[3]))}
		at = SMALL_METRICS_BYTES
	case 18:
		if len(entry) < BIG_METRICS_BYTES { return }
		g.metrics = {int(entry[1]), int(entry[0]), int(i8(entry[2])), int(i8(entry[3]))}
		at = BIG_METRICS_BYTES
	case 19:
		g.metrics = big
	case:
		return
	}
	n := be32(entry, at) or_return
	at += 4
	if n <= 0 || n > CBDT_PNG_MAX_BYTES || at + n > len(entry) { return }
	g.png = entry[at:at + n]
	return g, g.ppem > 0
}

// Whether the face has a bitmap for this glyph.
@(private)
cbdt_has :: proc(fc: ^Face_Colr, gid: u16) -> bool {
	if fc == nil || len(fc.cbdt) == 0 || len(fc.cblc) == 0 { return false }
	_, ok := cbdt_glyph(fc, gid, 0)
	return ok
}

// The glyph at `size` pixels: straight-alpha RGBA on the heap (the bitmap of a COLR glyph has the same form: colr_put).
@(private)
cbdt_draw :: proc(fc: ^Face_Colr, gid: u16, size: f32) -> (bm: Colr_Bitmap, ok: bool) {
	if fc == nil || size <= 0 { return }
	g := cbdt_glyph(fc, gid, size) or_return
	heap := runtime.heap_allocator()
	img, err := png.load_from_bytes(g.png, {.alpha_add_if_missing}, heap)
	if err != nil || img == nil { return }
	defer image.destroy(img, heap)
	if img.channels != 4 || img.depth != 8 || img.width <= 0 || img.height <= 0 { return }
	k := size / f32(g.ppem)
	w, h := max(int(math.round(f32(img.width) * k)), 1), max(int(math.round(f32(img.height) * k)), 1)
	if w > CBDT_SCALED_MAX_PX || h > CBDT_SCALED_MAX_PX { return }
	src := img.pixels[:]
	if len(src) < img.width * img.height * 4 { return }
	px := make([]u8, w * h * 4, heap)
	// each pixel the average of what it covers, weighted by alpha so that transparent colors do not bleed in
	for y in 0 ..< h {
		y0 := y * img.height / h
		y1 := max((y + 1) * img.height / h, y0 + 1)
		for x in 0 ..< w {
			x0 := x * img.width / w
			x1 := max((x + 1) * img.width / w, x0 + 1)
			r, gr, b, a, n: u32
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					p := src[(sy * img.width + sx) * 4:][:4]
					pa := u32(p[3])
					r += u32(p[0]) * pa; gr += u32(p[1]) * pa; b += u32(p[2]) * pa; a += pa
					n += 1
				}
			}
			o := px[(y * w + x) * 4:][:4]
			if a > 0 { o[0], o[1], o[2] = u8(r / a), u8(gr / a), u8(b / a) }
			o[3] = u8(a / n)
		}
	}
	return Colr_Bitmap{px = px, w = w, h = h, origin = {int(math.round(-f32(g.metrics.bx) * k)), int(math.round(f32(g.metrics.by) * k))}}, true
}
