// A board of emoji drawn by the COLR interpreter and by Chrome / Edge from the same font file: conformance of the
// interpreter against the browser that defines how COLR v1 looks on the web.
//
//   colrboard write   <font> <list> <out dir> <css size> <scale>     board.html (for the browser) and mine.png
//   colrboard compare <font> <list> <edge png> <out dir> <css size> <scale>   side.png (browser | interpreter | difference) + numbers
//
// <list>: one emoji per line, code points in hex separated by spaces (emoji-test.txt order). The browser draws each as
// text of <css size> px at <scale> device pixels per CSS pixel; the interpreter's glyph is shaped by the toolkit
// (DirectWrite, the font as the only face) and drawn at the same device size. Tiles are compared after the best integer
// shift in -4 ..= 4 pixels (where the browser puts the baseline is its own line layout); the shift is reported.
// tools\emoji_board.ps1 runs the three steps.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../../font"
import stbi "vendor:stb/image"

COLS :: 12

Board :: struct {
	font_path: string,
	items:     [dynamic]string,   // UTF-8
	css_size:  int,
	scale:     f32,
	cell_w, cell_h: int,          // CSS px, multiples of 4
	rows:      int,
}

main :: proc() {
	if len(os.args) < 2 { usage() }
	mode := os.args[1]
	b: Board
	switch mode {
	case "write":
		if len(os.args) < 7 { usage() }
		setup(&b, os.args[2], os.args[3], os.args[5], os.args[6])
		out := os.args[4]
		os.make_directory(out)
		write_html(&b, out)
		img, w, h := render_mine(&b)
		write_png(fmt.tprintf("%s/mine.png", out), img, w, h)
		fmt.println("wrote", out)
	case "compare":
		if len(os.args) < 8 { usage() }
		setup(&b, os.args[2], os.args[3], os.args[6], os.args[7])
		compare(&b, os.args[4], os.args[5])
	case: usage()
	}
}

usage :: proc() {
	fmt.println("usage: colrboard write <font> <list> <out> <css size> <scale> | compare <font> <list> <edge.png> <out> <css size> <scale>")
	os.exit(2)
}

setup :: proc(b: ^Board, font_path, list_path, size, scale: string) {
	b.font_path = font_path
	b.css_size, _ = strconv.parse_int(size)
	sc, _ := strconv.parse_f32(scale)
	b.scale = sc
	b.cell_w = (b.css_size * 9 / 5 + 3) &~ 3
	b.cell_h = (b.css_size * 8 / 5 + 3) &~ 3
	data, err := os.read_entire_file(list_path, context.allocator)
	if err != nil { fmt.println("cannot read", list_path); os.exit(2) }
	for line in strings.split_lines(string(data)) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		sb := strings.builder_make()
		for tok in strings.fields(l) {
			v, _ := strconv.parse_int(tok, 16)
			strings.write_rune(&sb, rune(v))
		}
		append(&b.items, strings.to_string(sb))
	}
	b.rows = (len(b.items) + COLS - 1) / COLS
}

dev :: proc(b: ^Board, css: int) -> int { return int(math.round(f32(css) * b.scale)) }

write_html :: proc(b: ^Board, out: string) {
	sb := strings.builder_make()
	path, _ := strings.replace_all(b.font_path, "\\", "/", context.temp_allocator)
	fmt.sbprintf(&sb, "<!doctype html><meta charset=utf-8><style>@font-face{{font-family:N;src:url('file:///%s')}}\nbody{{margin:0;background:#fff}}\n", path)
	fmt.sbprintf(&sb, ".c{{position:absolute;width:%dpx;height:%dpx;font:%dpx/%dpx N;white-space:nowrap;overflow:visible}}</style><body>\n", b.cell_w, b.cell_h, b.css_size, b.cell_h)
	for it, i in b.items {
		fmt.sbprintf(&sb, "<div class=c style=\"left:%dpx;top:%dpx\">", (i % COLS) * b.cell_w, (i / COLS) * b.cell_h)
		for r in it { fmt.sbprintf(&sb, "&#x%X;", u32(r)) }
		fmt.sbprintf(&sb, "</div>\n")
	}
	if err := os.write_entire_file(fmt.tprintf("%s/board.html", out), transmute([]u8)strings.to_string(sb)); err != nil {
		fmt.println("cannot write board.html:", err)
		os.exit(2)
	}
}

// The interpreter's board: RGBA, white background.
render_mine :: proc(b: ^Board) -> (img: [][4]u8, w, h: int) {
	data, err := os.read_entire_file(b.font_path, context.allocator)
	if err != nil { fmt.println("cannot read", b.font_path); os.exit(2) }
	s: font.State
	font.init(&s)
	defer font.destroy(&s)
	st := s.settings
	st.color_engine = .Builtin
	font.set_settings(&s, st)
	id, ok := font.load_embedded(&s, data)
	if !ok { fmt.println("font did not load"); os.exit(2) }
	cas := font.cascade(&s, {{font = id}}, nil, true)
	size := f32(b.css_size) * b.scale
	m := font.metrics(&s, id, size)
	// where a browser puts the baseline of a line of line-height cell_h: centered half-leading
	asc, desc := math.round(m.ascent), math.round(m.descent)
	base := (f32(dev(b, b.cell_h)) - (asc + desc)) / 2 + asc
	w, h = dev(b, b.cell_w) * COLS, dev(b, b.cell_h) * b.rows
	img = make([][4]u8, w * h)
	for &p in img { p = {255, 255, 255, 255} }
	for it, i in b.items {
		x0 := f32((i % COLS) * dev(b, b.cell_w))
		y0 := (i / COLS) * dev(b, b.cell_h)
		sh := font.shape(&s, cas, size, it, {}, context.temp_allocator)
		for g in sh.glyphs {
			ix, sub := font.subpixel(&s, x0 + g.x)
			gi := font.glyph_image(&s, g.face, g.id, size, sub, {0, 0, 0})
			if gi.page < 0 { continue }
			blit(&s, gi, img, w, h, int(ix + gi.offset.x), y0 + int(math.round(base)) + int(gi.offset.y))
		}
	}
	d, r := font.colr_counts(&s)
	fmt.printf("%d emoji, %d glyphs drawn by the interpreter, %d refused\n", len(b.items), d, r)
	return
}

blit :: proc(s: ^font.State, gi: font.Glyph_Image, img: [][4]u8, w, h: int, dx, dy: int) {
	Sync :: struct { stride: int, pixels: []u8 }
	sy: Sync
	font.atlas_sync_page(s, int(gi.page), 0, &sy, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		(^Sync)(user)^ = Sync{stride, pixels}
	})
	gw, gh := int(gi.size.x), int(gi.size.y)
	for row in 0 ..< gh {
		for col in 0 ..< gw {
			x, y := dx + col, dy + row
			if x < 0 || y < 0 || x >= w || y >= h { continue }
			o := (int(gi.uv[1]) + row) * sy.stride + (int(gi.uv[0]) + col) * 4
			a := f32(sy.pixels[o + 3]) / 255
			if a <= 0 { continue }
			p := &img[y * w + x]
			for k in 0 ..< 3 { p[k] = u8(clamp(f32(sy.pixels[o + k]) * a + f32(p[k]) * (1 - a) + 0.5, 0, 255)) }
		}
	}
}

write_png :: proc(path: string, img: [][4]u8, w, h: int) {
	stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), i32(w), i32(h), 4, raw_data(img), i32(w * 4))
}

Tile_Result :: struct {
	index:  int,
	mean:   f32,   // best shift
	shift:  [2]int,
	mean0:  f32,   // no shift
}

compare :: proc(b: ^Board, edge_png, out: string) {
	mine, w, h := render_mine(b)
	cs := strings.clone_to_cstring(edge_png, context.temp_allocator)
	ew, eh, ch: i32
	edge_px := stbi.load(cs, &ew, &eh, &ch, 4)
	if edge_px == nil { fmt.println("cannot read", edge_png); os.exit(2) }
	defer stbi.image_free(edge_px)
	edge := ([^][4]u8)(edge_px)[:int(ew) * int(eh)]
	fmt.printf("board %d x %d, browser capture %d x %d\n", w, h, ew, eh)
	tw, th := dev(b, b.cell_w), dev(b, b.cell_h)
	results := make([dynamic]Tile_Result)
	at :: proc(img: [][4]u8, w, h, x, y: int) -> [3]f32 {
		if x < 0 || y < 0 || x >= w || y >= h { return {255, 255, 255} }
		p := img[y * w + x]
		return {f32(p[0]), f32(p[1]), f32(p[2])}
	}
	for i in 0 ..< len(b.items) {
		tx, ty := (i % COLS) * tw, (i / COLS) * th
		best := Tile_Result{index = i, mean = max(f32)}
		for sy in -4 ..= 4 {
			for sx in -4 ..= 4 {
				sum: f32
				for y in 0 ..< th {
					for x in 0 ..< tw {
						a := at(edge, int(ew), int(eh), tx + x, ty + y)
						m := at(mine, w, h, tx + x - sx, ty + y - sy)
						sum += abs(a.r - m.r) + abs(a.g - m.g) + abs(a.b - m.b)
					}
				}
				mean := sum / f32(tw * th * 3)
				if sx == 0 && sy == 0 { best.mean0 = mean }
				if mean < best.mean { best.mean, best.shift = mean, {sx, sy} }
			}
		}
		append(&results, best)
	}
	// the shift most tiles agree on (the baseline's place), then every tile at that shift
	votes := make(map[[2]int]int)
	for r in results { votes[r.shift] += 1 }
	common: [2]int
	top := 0
	for k, v in votes { if v > top { common, top = k, v } }
	total, total_all: f32
	diff_img := make([][4]u8, w * h)
	side := make([][4]u8, w * 3 * h)
	for i in 0 ..< len(b.items) {
		tx, ty := (i % COLS) * tw, (i / COLS) * th
		sum: f32
		for y in 0 ..< th {
			for x in 0 ..< tw {
				a := at(edge, int(ew), int(eh), tx + x, ty + y)
				m := at(mine, w, h, tx + x - common.x, ty + y - common.y)
				d := abs(a.r - m.r) + abs(a.g - m.g) + abs(a.b - m.b)
				sum += d
				v := u8(clamp(255 - d, 0, 255))
				diff_img[(ty + y) * w + tx + x] = {v, v, v, 255}
				side[(ty + y) * (w * 3) + tx + x] = {u8(a.r), u8(a.g), u8(a.b), 255}
				side[(ty + y) * (w * 3) + w + tx + x] = {u8(m.r), u8(m.g), u8(m.b), 255}
				side[(ty + y) * (w * 3) + 2 * w + tx + x] = {v, v, v, 255}
			}
		}
		results[i].mean = sum / f32(tw * th * 3)
		total += results[i].mean
	}
	for r in results { total_all += r.mean0 }
	n := f32(len(results))
	slice.sort_by(results[:], proc(a, b: Tile_Result) -> bool { return a.mean > b.mean })
	fmt.printf("common shift (%d, %d) px (%d of %d tiles agree)\n", common.x, common.y, top, len(results))
	fmt.printf("mean absolute difference per channel: %.3f /255 over the board's tiles (%.3f without the shift)\n", total / n, total_all / n)
	fmt.printf("median tile %.3f, worst tile %.3f\n", results[len(results) / 2].mean, results[0].mean)
	for r, i in results {
		if i >= 12 { break }
		cps := make([dynamic]string, context.temp_allocator)
		for c in b.items[r.index] { append(&cps, fmt.tprintf("%X", u32(c))) }
		fmt.printf("  tile %3d  %.2f  best shift (%d,%d)  %s\n", r.index, r.mean, r.shift.x, r.shift.y, strings.join(cps[:], " ", context.temp_allocator))
	}
	write_png(fmt.tprintf("%s/diff.png", out), diff_img, w, h)
	stbi.write_png(strings.clone_to_cstring(fmt.tprintf("%s/side.png", out), context.temp_allocator), i32(w * 3), i32(h), 4, raw_data(side), i32(w * 3 * 4))
	fmt.println("wrote", out)
}
