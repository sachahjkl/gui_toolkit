package platform

import "core:math"

// Cursors the system lacks (Windows has no grab, zoom, cell, copy... cursor), drawn in code at any size: shapes in a
// 32-unit design grid (the size of a cursor at 100 %), signed distance functions sampled 4 x 4 times per pixel. Every
// shape is a body of the scheme's fill colour with an outline of the other colour, as the system's cursors are: legible
// on any background. `Cursor_Scheme` follows the user's scheme (white or black pointer: cursors_win32.odin looks at
// the system's arrow).

Cursor_Scheme :: enum u8 { Light, Dark }   // Light: white fill, black outline (Windows' default); Dark: the reverse

// A drawn cursor: `size` x `size` RGBA8 pixels (straight alpha), the hotspot in pixels.
Cursor_Image :: struct {
	size:   int,
	hot:    [2]int,
	pixels: []u8,
}

// The cursors that have a drawn shape (on Windows, those the system lacks).
cursor_has_shape :: proc(c: Cursor) -> bool {
	#partial switch c {
	case .Context_Menu, .Cell, .Vertical_Text, .Alias, .Copy, .No_Drop, .Grab, .Grabbing, .Col_Resize, .Row_Resize, .Zoom_In, .Zoom_Out:
		return true
	}
	return false
}

@(private = "file") Prim_Kind :: enum u8 { Poly, Circle, Box, Capsule, Ring }

@(private = "file")
Prim :: struct {
	kind: Prim_Kind,
	pts:  [8][2]f32,   // Poly: the vertices; Box: center, half size; Capsule: the two ends; Circle / Ring: center
	n:    int,
	r:    f32,         // Circle / Capsule / Ring: radius; Box: corner radius
	w:    f32,         // Ring: thickness
}

// Body: the fill colour with an outline; Ink: the outline's colour (details over a body); Paper: the fill colour.
@(private = "file") Op_Mode :: enum u8 { Body, Ink, Paper }

@(private = "file")
Op :: struct {
	mode:  Op_Mode,
	prims: [8]Prim,
	n:     int,
}

@(private = "file")
Shape :: struct {
	ops: [8]Op,
	n:   int,
	hot: [2]f32,   // design units
}

@(private = "file") STROKE :: f32(1)   // outline width, design units

@(private = "file") poly :: proc(pts: ..[2]f32) -> (p: Prim) {
	p.kind, p.n = .Poly, len(pts)
	for v, i in pts { p.pts[i] = v }
	return
}
@(private = "file") box :: proc(lo, hi: [2]f32, r: f32 = 0) -> Prim { return {kind = .Box, pts = {0 = (lo + hi) * 0.5, 1 = (hi - lo) * 0.5}, r = r} }
@(private = "file") capsule :: proc(a, b: [2]f32, r: f32) -> Prim { return {kind = .Capsule, pts = {0 = a, 1 = b}, r = r} }
@(private = "file") circle :: proc(c: [2]f32, r: f32) -> Prim { return {kind = .Circle, pts = {0 = c}, r = r} }
@(private = "file") ring :: proc(c: [2]f32, r, w: f32) -> Prim { return {kind = .Ring, pts = {0 = c}, r = r, w = w} }

@(private = "file")
add :: proc(s: ^Shape, mode: Op_Mode, prims: ..Prim) {
	op := &s.ops[s.n]
	s.n += 1
	op.mode = mode
	for p, i in prims { op.prims[i] = p }
	op.n = len(prims)
}

@(private = "file")
transpose :: proc(p: Prim) -> Prim {
	q := p
	for &v in q.pts { v = {v.y, v.x} }
	return q
}

// The system's arrow (Windows' shape), for the cursors that add a badge to it.
@(private = "file")
arrow :: proc() -> Prim {
	return poly({2, 2}, {2, 16.6}, {5.2, 13.6}, {7.4, 18.6}, {9.4, 17.8}, {7.2, 12.9}, {11.6, 12.9})
}

@(private = "file")
shape_of :: proc(c: Cursor) -> (s: Shape, ok: bool) {
	#partial switch c {
	case .Copy:
		add(&s, .Body, arrow())
		add(&s, .Body, box({12, 17}, {21, 26}, 0.8))
		add(&s, .Ink, box({14, 21}, {19, 22}), box({16, 19}, {17, 24}))
		s.hot = {1.4, 1.4}
	case .Alias:
		add(&s, .Body, arrow())
		add(&s, .Body, box({12, 17}, {21, 26}, 0.8))
		add(&s, .Ink, box({14, 21}, {15, 24.5}), box({14, 21}, {17.5, 22}), poly({17, 19}, {20, 21.5}, {17, 24}))
		s.hot = {1.4, 1.4}
	case .Context_Menu:
		add(&s, .Body, arrow())
		add(&s, .Body, box({12, 14}, {22, 26}, 0.8))
		add(&s, .Ink, box({14, 16}, {20, 17}), box({14, 19}, {20, 20}), box({14, 22}, {20, 23}))
		s.hot = {1.4, 1.4}
	case .No_Drop:
		add(&s, .Body, arrow())
		add(&s, .Body, circle({17, 21.5}, 5))
		add(&s, .Ink, ring({17, 21.5}, 3.4, 1.5), capsule({14.7, 19.2}, {19.3, 23.8}, 0.75))
		s.hot = {1.4, 1.4}
	case .Cell:
		add(&s, .Body, box({7, 12}, {22, 17}), box({12, 7}, {17, 22}))
		s.hot = {14, 14}
	case .Vertical_Text:
		add(&s, .Body, box({8, 14}, {21, 15}), box({7, 10}, {9, 19}, 0.5), box({20, 10}, {22, 19}, 0.5))
		s.hot = {14, 14}
	case .Col_Resize, .Row_Resize:
		prims := [?]Prim{
			box({12, 8}, {13, 21}), box({16, 8}, {17, 21}),
			poly({4, 14.5}, {9, 9.5}, {9, 19.5}), box({8, 14}, {12, 15}),
			poly({25, 14.5}, {20, 9.5}, {20, 19.5}), box({17, 14}, {21, 15}),
		}
		if c == .Row_Resize { for &p in prims { p = transpose(p) } }
		add(&s, .Body, ..prims[:])
		s.hot = {14, 14}
	case .Zoom_In, .Zoom_Out:
		add(&s, .Body, capsule({17, 17}, {23, 23}, 2.4))
		add(&s, .Ink, capsule({17, 17}, {23, 23}, 1.3))
		add(&s, .Body, circle({12, 12}, 7))
		if c == .Zoom_In { add(&s, .Ink, box({8, 11}, {16, 13}), box({11, 8}, {13, 16})) } else { add(&s, .Ink, box({8, 11}, {16, 13})) }
		s.hot = {12, 12}
	case .Grab:
		add(&s, .Body,
			capsule({8.5, 7}, {8.5, 15}, 1.5), capsule({12.5, 4.5}, {12.5, 15}, 1.5),
			capsule({16.5, 5.5}, {16.5, 15}, 1.5), capsule({20.5, 8}, {20.5, 15}, 1.5),
			box({7, 12}, {22, 25}, 4), capsule({9.5, 20.5}, {4, 14.5}, 1.6))
		s.hot = {14, 15}
	case .Grabbing:
		add(&s, .Body,
			capsule({8.5, 10}, {8.5, 13}, 1.5), capsule({12.5, 9.5}, {12.5, 13}, 1.5),
			capsule({16.5, 9.5}, {16.5, 13}, 1.5), capsule({20.5, 10.5}, {20.5, 13}, 1.5),
			box({7, 12}, {22, 25}, 4), capsule({9.5, 20.5}, {5.5, 16}, 1.6))
		s.hot = {14, 15}
	case:
		return {}, false
	}
	return s, true
}

@(private = "file")
dot2 :: #force_inline proc(a, b: [2]f32) -> f32 { return a.x * b.x + a.y * b.y }

@(private = "file")
length2 :: #force_inline proc(a: [2]f32) -> f32 { return math.sqrt(a.x * a.x + a.y * a.y) }

// Signed distance from p to the primitive (negative inside).
@(private = "file")
sdf :: proc(pr: ^Prim, p: [2]f32) -> f32 {
	switch pr.kind {
	case .Circle: return length2(p - pr.pts[0]) - pr.r
	case .Ring:   return abs(length2(p - pr.pts[0]) - pr.r) - pr.w * 0.5
	case .Capsule:
		pa, ba := p - pr.pts[0], pr.pts[1] - pr.pts[0]
		h := clamp(dot2(pa, ba) / max(dot2(ba, ba), 1e-6), 0, 1)
		return length2(pa - ba * h) - pr.r
	case .Box:
		q := [2]f32{abs(p.x - pr.pts[0].x), abs(p.y - pr.pts[0].y)} - pr.pts[1] + pr.r
		return length2({max(q.x, 0), max(q.y, 0)}) + min(max(q.x, q.y), 0) - pr.r
	case .Poly:
		v := pr.pts[:pr.n]
		d := dot2(p - v[0], p - v[0])
		s: f32 = 1
		for i, j := 0, len(v) - 1; i < len(v); j, i = i, i + 1 {
			e, w := v[j] - v[i], p - v[i]
			b := w - e * clamp(dot2(w, e) / dot2(e, e), 0, 1)
			d = min(d, dot2(b, b))
			c1, c2, c3 := p.y >= v[i].y, p.y < v[j].y, e.x * w.y > e.y * w.x
			if (c1 && c2 && c3) || (!c1 && !c2 && !c3) { s = -s }
		}
		return s * math.sqrt(d)
	}
	return 1e9
}

// Draws cursor `c` at `size` x `size` pixels (the design grid is 32 units: size / 32 pixels per unit). ok = false
// for a cursor without a drawn shape (cursor_has_shape).
cursor_draw :: proc(c: Cursor, size: int, scheme := Cursor_Scheme.Light, allocator := context.allocator) -> (img: Cursor_Image, ok: bool) {
	s, has := shape_of(c)
	if !has || size <= 0 { return {}, false }
	fill, line := u8(255), u8(0)
	if scheme == .Dark { fill, line = 0, 255 }
	img.size = size
	img.pixels = make([]u8, size * size * 4, allocator)
	unit := 32 / f32(size)   // design units per pixel
	SS :: 4
	for y in 0 ..< size {
		for x in 0 ..< size {
			n_fill, n_line := 0, 0
			for sy in 0 ..< SS {
				for sx in 0 ..< SS {
					p := [2]f32{(f32(x) + (f32(sx) + 0.5) / SS) * unit, (f32(y) + (f32(sy) + 0.5) / SS) * unit}
					color := -1   // -1 nothing, 0 fill, 1 line
					for oi in 0 ..< s.n {
						op := &s.ops[oi]
						d := f32(1e9)
						for pi in 0 ..< op.n { d = min(d, sdf(&op.prims[pi], p)) }
						switch op.mode {
						case .Body:
							if d < 0 { color = 0 } else if d < STROKE { color = 1 }
						case .Ink:   if d < 0 { color = 1 }
						case .Paper: if d < 0 { color = 0 }
						}
					}
					if color == 0 { n_fill += 1 } else if color == 1 { n_line += 1 }
				}
			}
			covered := n_fill + n_line
			if covered == 0 { continue }
			v := u8((int(fill) * n_fill + int(line) * n_line) / covered)
			o := (y * size + x) * 4
			img.pixels[o], img.pixels[o + 1], img.pixels[o + 2] = v, v, v
			img.pixels[o + 3] = u8(covered * 255 / (SS * SS))
		}
	}
	img.hot = {clamp(int(s.hot.x / unit), 0, size - 1), clamp(int(s.hot.y / unit), 0, size - 1)}
	return img, true
}

cursor_image_destroy :: proc(img: ^Cursor_Image, allocator := context.allocator) {
	delete(img.pixels, allocator)
	img^ = {}
}

// RGBA8 (straight alpha) `src` of sw x sh pixels resampled to dw x dh: a tent filter as wide as a source pixel when
// enlarging (bilinear), as wide as the reduction when reducing (every source pixel counts), in premultiplied alpha.
cursor_resample :: proc(src: []u8, sw, sh, dw, dh: int, allocator := context.allocator) -> []u8 {
	if sw <= 0 || sh <= 0 || dw <= 0 || dh <= 0 || len(src) < sw * sh * 4 { return nil }
	out := make([]u8, dw * dh * 4, allocator)
	if sw == dw && sh == dh { copy(out, src[:sw * sh * 4]); return out }
	pre := make([][4]f32, sw * sh, context.temp_allocator)
	for i in 0 ..< sw * sh {
		a := f32(src[i * 4 + 3]) / 255
		pre[i] = {f32(src[i * 4]) * a, f32(src[i * 4 + 1]) * a, f32(src[i * 4 + 2]) * a, a * 255}
	}
	// horizontal pass: sh rows of dw, then vertical: dh rows of dw
	mid := make([][4]f32, dw * sh, context.temp_allocator)
	pass :: proc(n_src, n_dst: int, sample: proc(data: rawptr, line, i: int) -> [4]f32, data: rawptr, line: int, put: [][4]f32, put_stride: int) {
		ratio := f32(n_src) / f32(n_dst)
		radius := max(ratio, 1)
		for d in 0 ..< n_dst {
			center := (f32(d) + 0.5) * ratio
			lo := max(int(math.floor(center - radius)), 0)
			hi := min(int(math.ceil(center + radius)), n_src - 1)
			acc: [4]f32
			wsum: f32
			for s in lo ..= hi {
				w := max(0, 1 - abs(f32(s) + 0.5 - center) / radius)
				if w <= 0 { continue }
				acc += sample(data, line, s) * w
				wsum += w
			}
			if wsum > 0 { acc /= wsum }
			put[d * put_stride] = acc
		}
	}
	Img :: struct { px: [][4]f32, w: int }
	src_img := Img{pre, sw}
	for y in 0 ..< sh {
		pass(sw, dw, proc(data: rawptr, line, i: int) -> [4]f32 { im := (^Img)(data); return im.px[line * im.w + i] }, &src_img, y, mid[y * dw:], 1)
	}
	res := make([][4]f32, dw * dh, context.temp_allocator)
	mid_img := Img{mid, dw}
	for x in 0 ..< dw {
		pass(sh, dh, proc(data: rawptr, line, i: int) -> [4]f32 { im := (^Img)(data); return im.px[i * im.w + line] }, &mid_img, x, res[x:], dw)
	}
	for i in 0 ..< dw * dh {
		v := res[i]
		a := clamp(v[3], 0, 255)
		if a < 0.5 { continue }
		k := 255 / a
		out[i * 4] = u8(clamp(v[0] * k + 0.5, 0, 255))
		out[i * 4 + 1] = u8(clamp(v[1] * k + 0.5, 0, 255))
		out[i * 4 + 2] = u8(clamp(v[2] * k + 0.5, 0, 255))
		out[i * 4 + 3] = u8(a + 0.5)
	}
	return out
}
