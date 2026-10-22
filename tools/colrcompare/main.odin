// Compares the COLR interpreter (font/colr.odin) with Direct2D on the glyphs of a font. For each glyph: both bitmaps on
// white, the mean and largest difference per channel (0..255), and a contact sheet PNG (Direct2D | interpreter |
// difference x4) of the worst ones.
//
//   odin run tools/colrcompare -- <font.ttf> <out dir> [size] [first codepoint hex] [last codepoint hex] [name filter...]
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"
import "../../font"
import stbi "vendor:stb/image"

Img :: struct {
	w, h:  int,
	px:    [][4]u8,   // straight RGBA on the canvas
}

bitmap :: proc(s: ^font.State, img: font.Glyph_Image) -> (b: Img, off: [2]int) {
	if img.page < 0 { return }
	Sync :: struct { stride: int, pixels: []u8 }
	sy: Sync
	font.atlas_sync_page(s, int(img.page), 0, &sy, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		(^Sync)(user)^ = Sync{stride, pixels}
	})
	b.w, b.h = int(img.size.x), int(img.size.y)
	b.px = make([][4]u8, b.w * b.h)
	for row in 0 ..< b.h {
		for col in 0 ..< b.w {
			o := (int(img.uv[1]) + row) * sy.stride + (int(img.uv[0]) + col) * 4
			b.px[row * b.w + col] = {sy.pixels[o], sy.pixels[o + 1], sy.pixels[o + 2], sy.pixels[o + 3]}
		}
	}
	return b, {int(img.offset.x), int(img.offset.y)}
}

// Both bitmaps on one canvas (white background): the image of `b` placed at its offset.
place :: proc(b: Img, off: [2]int, origin: [2]int, cw, ch: int) -> [][3]f32 {
	out := make([][3]f32, cw * ch)
	for &p in out { p = {255, 255, 255} }
	for y in 0 ..< b.h {
		for x in 0 ..< b.w {
			cx, cy := x + off.x - origin.x, y + off.y - origin.y
			if cx < 0 || cy < 0 || cx >= cw || cy >= ch { continue }
			p := b.px[y * b.w + x]
			a := f32(p[3]) / 255
			out[cy * cw + cx] = {f32(p[0]) * a + 255 * (1 - a), f32(p[1]) * a + 255 * (1 - a), f32(p[2]) * a + 255 * (1 - a)}
		}
	}
	return out
}

sub_b: int
d2d_time, own_time, again_time: time.Duration
dump_glyph: rune = -1   // COLR_DUMP=<hex>: print the paint graph of that character's glyph

Result :: struct {
	name:        string,
	cp:          rune,
	mean, max:   f32,
	sheet:       [][3]u8,
	sw, sh:      int,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.println("usage: colrcompare <font.ttf> <out dir> [size] [first hex] [last hex]")
		os.exit(2)
	}
	path, out := os.args[1], os.args[2]
	size: f32 = 64
	first, last: rune = 0xF0000, 0xF2000
	if len(os.args) > 3 { v, _ := strconv.parse_f32(os.args[3]); size = v }
	if len(os.args) > 4 { v, _ := strconv.parse_int(os.args[4], 16); first = rune(v) }
	if len(os.args) > 5 { v, _ := strconv.parse_int(os.args[5], 16); last = rune(v) }
	if v, ok := strconv.parse_int(os.get_env("COLR_SUB", context.temp_allocator), 10); ok { sub_b = v }
	if v, ok := strconv.parse_int(os.get_env("COLR_DUMP", context.temp_allocator), 16); ok { dump_glyph = rune(v) }
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil { fmt.println("cannot read", path); os.exit(2) }
	os.make_directory(out)

	sd, sb: font.State
	font.init(&sd)
	st := sd.settings
	st.color_engine = os.get_env("COLR_A", context.temp_allocator) == "builtin" ? .Builtin : .System
	font.set_settings(&sd, st)
	font.init(&sb)
	st.color_engine = os.get_env("COLR_B", context.temp_allocator) == "system" ? .System : .Builtin
	font.set_settings(&sb, st)
	if v, ok := strconv.parse_int(os.get_env("COLR_SAMPLES", context.temp_allocator), 10); ok {
		st.colr_samples = v
		font.set_settings(&sb, st)
	}
	fmt.println("engines:", sd.settings.color_engine, sb.settings.color_engine, "samples", sb.settings.colr_samples)
	fd, ok1 := font.load_embedded(&sd, data)
	fb, ok2 := font.load_embedded(&sb, data)
	if !ok1 || !ok2 { fmt.println("font did not load"); os.exit(2) }
	cd := font.cascade(&sd, {{font = fd}}, nil, true)
	cb := font.cascade(&sb, {{font = fb}}, nil, true)

	results := make([dynamic]Result)
	seen := make(map[u16]bool)
	total, color_n, fail_n := 0, 0, 0
	for r := first; r <= last; r += 1 {
		buf: [4]u8
		n := encode(buf[:], r)
		text := string(buf[:n])
		shd := font.shape(&sd, cd, size, text, {}, context.temp_allocator)
		shb := font.shape(&sb, cb, size, text, {}, context.temp_allocator)
		if len(shd.glyphs) != 1 || len(shb.glyphs) != 1 || shd.glyphs[0].id == 0 || shd.glyphs[0].face != fd { continue }
		gid := shd.glyphs[0].id
		if seen[gid] { continue }
		seen[gid] = true
		total += 1
		t0 := time.tick_now()
		id := font.glyph_image(&sd, fd, gid, size, 0, {0, 0, 0})
		t1 := time.tick_now()
		ib := font.glyph_image(&sb, fb, gid, size, sub_b, {0, 0, 0})
		t2 := time.tick_now()
		d2d_time += time.tick_diff(t0, t1)
		own_time += time.tick_diff(t1, t2)
		ia := font.glyph_image(&sb, fb, gid, size + 0.0625, 0, {0, 0, 0})   // outlines already known
		again_time += time.tick_diff(t2, time.tick_now())
		_ = ia
		if !id.color { continue }
		color_n += 1
		if !ib.color { fail_n += 1; fmt.printf("U+%X glyph %d: interpreter did not draw it in color\n", r, gid); continue }
		a, ao := bitmap(&sd, id)
		b, bo := bitmap(&sb, ib)
		// the union of the two boxes
		x0 := min(ao.x, bo.x)
		y0 := min(ao.y, bo.y)
		x1 := max(ao.x + a.w, bo.x + b.w)
		y1 := max(ao.y + a.h, bo.y + b.h)
		cw, ch := max(x1 - x0, 1), max(y1 - y0, 1)
		pa := place(a, ao, {x0, y0}, cw, ch)
		pb := place(b, bo, {x0, y0}, cw, ch)

		sum, mx: f32
		if dump_glyph == r { fmt.println(font.colr_dump(font.colr_of(&sb, fb), gid)) }
		for i in 0 ..< cw * ch {
			for k in 0 ..< 3 {
				d := abs(pa[i][k] - pb[i][k])
				sum += d
				mx = max(mx, d)
			}
		}
		res := Result{cp = r, mean = sum / f32(cw * ch * 3), max = mx, sw = cw * 3 + 8, sh = ch}
		res.sheet = make([][3]u8, res.sw * res.sh)
		for &p in res.sheet { p = {200, 200, 255} }
		for y in 0 ..< ch {
			for x in 0 ..< cw {
				i := y * cw + x
				for k in 0 ..< 3 {
					res.sheet[y * res.sw + x][k] = u8(pa[i][k])
					res.sheet[y * res.sw + cw + 4 + x][k] = u8(pb[i][k])
					res.sheet[y * res.sw + 2 * cw + 8 + x][k] = u8(clamp(255 - abs(pa[i][k] - pb[i][k]) * 4, 0, 255))
				}
			}
		}
		append(&results, res)
	}
	slice.sort_by(results[:], proc(a, b: Result) -> bool { return a.mean > b.mean })
	fmt.printf("time per glyph: Direct2D %.3f ms, interpreter %.3f ms (%d glyphs)\n", time.duration_milliseconds(d2d_time) / f64(max(color_n, 1)), time.duration_milliseconds(own_time) / f64(max(color_n, 1)), color_n)
	fmt.printf("interpreter again with its outlines known: %.3f ms\n", time.duration_milliseconds(again_time) / f64(max(color_n, 1)))
	drawn, refused := font.colr_counts(&sb)
	fmt.printf("%d glyphs, %d in color (Direct2D), %d not drawn by the interpreter; interpreter: %d drawn, %d refused\n", total, color_n, fail_n, drawn, refused)
	mean_all, mean_max: f32
	for r in results { mean_all += r.mean }
	if len(results) > 0 { mean_all /= f32(len(results)); mean_max = results[0].mean }
	fmt.printf("mean difference %.3f /255 (worst glyph %.3f)\n", mean_all, mean_max)
	for r, i in results {
		if i >= 40 { break }
		fmt.printf("  U+%X  mean %.2f  max %.0f\n", r.cp, r.mean, r.max)
	}
	// contact sheet of the worst 24
	shown := min(len(results), 24)
	if shown > 0 {
		cols := 3
		cellw, cellh := 0, 0
		for r in results[:shown] { cellw, cellh = max(cellw, r.sw), max(cellh, r.sh) }
		cellw += 8
		cellh += 8
		rows := (shown + cols - 1) / cols
		W, H := cols * cellw, rows * cellh
		img := make([][4]u8, W * H)
		for &p in img { p = {255, 255, 255, 255} }
		for r, i in results[:shown] {
			ox, oy := (i % cols) * cellw + 4, (i / cols) * cellh + 4
			for y in 0 ..< r.sh {
				for x in 0 ..< r.sw {
					p := r.sheet[y * r.sw + x]
					img[(oy + y) * W + ox + x] = {p.r, p.g, p.b, 255}
				}
			}
		}
		name := fmt.ctprintf("%s/worst.png", out)
		stbi.write_png(name, i32(W), i32(H), 4, raw_data(img), i32(W * 4))
		fmt.println("sheet:", name)
	}
	font.destroy(&sd)
	font.destroy(&sb)
}

encode :: proc(buf: []u8, r: rune) -> int {
	c := u32(r)
	switch {
	case c < 0x80: buf[0] = u8(c); return 1
	case c < 0x800: buf[0] = u8(0xC0 | c >> 6); buf[1] = u8(0x80 | c & 0x3F); return 2
	case c < 0x10000: buf[0] = u8(0xE0 | c >> 12); buf[1] = u8(0x80 | (c >> 6) & 0x3F); buf[2] = u8(0x80 | c & 0x3F); return 3
	}
	buf[0] = u8(0xF0 | c >> 18); buf[1] = u8(0x80 | (c >> 12) & 0x3F); buf[2] = u8(0x80 | (c >> 6) & 0x3F); buf[3] = u8(0x80 | c & 0x3F)
	return 4
}
