// gt:ocr. The pure parts: the reading order of lines, the rule of the scale, the dark ground, the height of lines, the
// languages of a locale, a picture prepared. Then the engine of this system (Tesseract, Windows.Media.Ocr) reads text
// the test draws: the toolkit's own Roboto (src/font/data), its outlines read here and filled by gt:paint, dark on light
// and light on dark, at the size of a screen's text. With no engine or no English installed, that test says so in the
// log and passes.
//   odin test tests/ocr -vet
package ocr_test

import "core:log"
import "core:strings"
import "core:testing"
import "../../src/ascii"
import ocr "../../src/ocr"
import paint "../../src/paint"

////////////////////////////////
// The pure parts

@(private = "file")
line_at :: proc(text: string, x, y, w, h: int) -> ocr.Line {
	return {text = text, rect = {x, y, w, h}}
}

@(test)
lines_are_read_by_rows :: proc(t: ^testing.T) {
	// a column at a time, as an engine gives them: the left column, then the right one
	lines := [?]ocr.Line{
		line_at("Name", 0, 2, 60, 18),
		line_at("Size", 0, 30, 50, 18),
		line_at("report.pdf", 200, 0, 120, 20),
		line_at("12 KB", 200, 31, 70, 18),
	}
	text := ocr.reading_order(lines[:], context.temp_allocator)
	testing.expect_value(t, text, "Name\treport.pdf\nSize\t12 KB")
	testing.expect_value(t, lines[1].text, "report.pdf")
	testing.expect_value(t, lines[2].text, "Size")
}

@(test)
lines_that_overlap_little_are_two_rows :: proc(t: ^testing.T) {
	// 6 pixels of 20 in common: less than half the shorter
	lines := [?]ocr.Line{line_at("right", 100, 14, 50, 20), line_at("left", 0, 0, 50, 20)}
	testing.expect_value(t, ocr.reading_order(lines[:], context.temp_allocator), "left\nright")
	// 12 of 20: one row, read left to right
	lines = {line_at("right", 100, 8, 50, 20), line_at("left", 0, 0, 50, 20)}
	testing.expect_value(t, ocr.reading_order(lines[:], context.temp_allocator), "left\tright")
	testing.expect_value(t, ocr.reading_order(nil, context.temp_allocator), "")
}

@(test)
small_text_is_scaled_up :: proc(t: ^testing.T) {
	testing.expect_value(t, ocr.upscale_factor(8, 400, 100), 3)
	testing.expect_value(t, ocr.upscale_factor(ocr.TINY_TEXT, 400, 100), 2)
	testing.expect_value(t, ocr.upscale_factor(15, 400, 100), 2)
	testing.expect_value(t, ocr.upscale_factor(ocr.SMALL_TEXT, 400, 100), 1)
	testing.expect_value(t, ocr.upscale_factor(30, 400, 100), 1)
	testing.expect_value(t, ocr.upscale_factor(0, 400, 100), 1)   // no text seen
	// the limits: the pixels, the engine's longest side
	testing.expect_value(t, ocr.upscale_factor(8, 3000, 1000), 3)       // 3 Mpx: x3 is 27
	testing.expect_value(t, ocr.upscale_factor(8, 3000, 2000), 2)       // 6 Mpx: x3 is 54, x2 24
	testing.expect_value(t, ocr.upscale_factor(8, 5000, 3000), 1)       // 15 Mpx: x2 is 60
	testing.expect_value(t, ocr.upscale_factor(15, 600, 100, 1000), 1)
	testing.expect_value(t, ocr.upscale_factor(8, 400, 100, 1000), 2)
}

@(test)
a_dark_ground_is_seen :: proc(t: ^testing.T) {
	gray := make([]u8, 100, context.temp_allocator)
	for &v, i in gray { v = i < 85 ? 30 : 230 }
	testing.expect(t, ocr.dark_background(gray), "mostly 30: dark")
	for &v, i in gray { v = i < 85 ? 240 : 10 }
	testing.expect(t, !ocr.dark_background(gray), "mostly 240: light")
	for &v, i in gray { v = i < 85 ? 140 : 0 }
	testing.expect(t, !ocr.dark_background(gray), "mid grey: light")
}

@(test)
the_height_of_lines_is_measured :: proc(t: ^testing.T) {
	W, H :: 50, 100
	gray := make([]u8, W * H, context.temp_allocator)
	for &v in gray { v = 255 }
	ink :: proc(gray: []u8, x0, x1, y0, y1: int) {
		for y in y0 ..< y1 { for x in x0 ..< x1 { gray[y * W + x] = 0 } }
	}
	ink(gray, 5, 20, 10, 25)   // 15 rows
	ink(gray, 8, 30, 40, 54)   // 14
	ink(gray, 5, 40, 70, 86)   // 16
	ink(gray, 0, W, 95, 96)    // a rule under them: too thin to be a line
	ink(gray, 0, 1, 0, H)      // a border down the left: on every row
	testing.expect_value(t, ocr.text_height(gray, W, H), 15)
	for &v in gray { v = 255 }
	testing.expect_value(t, ocr.text_height(gray, W, H), 0)
}

@(test)
a_dark_picture_is_prepared_as_dark_on_light :: proc(t: ^testing.T) {
	W, H :: 40, 20
	pixels := make([]u8, W * H * 4, context.temp_allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			v: u8 = 20
			if y >= 5 && y < 15 && x >= 4 && x < 30 { v = 250 }   // a line of light "text", 10 rows
			p := pixels[(y * W + x) * 4:]
			p[0], p[1], p[2], p[3] = v, v, v, 255
		}
	}
	p := ocr.prepare(pixels, W, H, W * 4, .BGRA, 0, context.temp_allocator)
	testing.expect(t, p.inverted)
	testing.expect_value(t, p.scale, 2)
	testing.expect_value(t, p.width, W * 2)
	testing.expect_value(t, p.height, H * 2)
	testing.expect_value(t, p.gray[0], 255)                         // the ground, white
	testing.expect_value(t, p.gray[20 * p.width + 30], 0)           // the text, black
}

@(test)
languages_of_a_locale :: proc(t: ^testing.T) {
	testing.expect_value(t, ocr.tesseract_code("fr_FR.UTF-8"), "fra")
	testing.expect_value(t, ocr.tesseract_code("pt-BR"), "por")
	testing.expect_value(t, ocr.tesseract_code("zh_TW.UTF-8"), "chi_tra")
	testing.expect_value(t, ocr.tesseract_code("zh_CN"), "chi_sim")
	testing.expect_value(t, ocr.tesseract_code("C"), "")

	expect_list :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
		testing.expectf(t, len(got) == len(want), "%v, want %v", got, want, loc = loc)
		if len(got) != len(want) { return }
		for g, i in got { testing.expectf(t, g == want[i], "%v, want %v", got, want, loc = loc) }
	}
	expect_list(t, ocr.default_languages("de_DE.UTF-8", {"deu", "eng", "osd"}, context.temp_allocator), {"deu", "eng"})
	expect_list(t, ocr.default_languages("fr_FR", {"eng", "osd"}, context.temp_allocator), {"eng"})
	expect_list(t, ocr.default_languages("en_US.UTF-8", {"eng"}, context.temp_allocator), {"eng"})
	expect_list(t, ocr.default_languages("", {"osd", "spa"}, context.temp_allocator), {"spa"})
	expect_list(t, ocr.default_languages("fr", {"osd"}, context.temp_allocator), {})
}

@(test)
a_bad_picture_is_refused :: proc(t: ^testing.T) {
	pixels := make([]u8, 10 * 10 * 4, context.temp_allocator)
	_, err := ocr.recognize(pixels, 10, 10, 30, .RGBA)    // stride under 4 bytes a pixel
	testing.expect_value(t, err, ocr.Error.Bad_Picture)
	_, err = ocr.recognize(pixels, 10, 11, 40, .RGBA)     // a row more than the pixels hold
	testing.expect_value(t, err, ocr.Error.Bad_Picture)
}

////////////////////////////////
// The engine, on text the test draws

@(test)
the_engine_reads_screen_text :: proc(t: ^testing.T) {
	engine, ok := ocr.available()
	if !ok {
		log.infof("no OCR engine with a language on this system (%v): the engine's test is skipped", engine)
		return
	}
	language := english(ocr.languages(context.temp_allocator))
	if language == "" {
		log.infof("%v has no English installed: the engine's test is skipped", engine)
		return
	}
	cases := [?]struct { text: string, ink, ground: u32, size: f32 }{
		{"Hello World 2026", 0x202020, 0xFFFFFF, 14},   // a light theme
		{"Settings and Preferences", 0xE0E0E0, 0x1E1E1E, 13},   // a dark theme
	}
	for c in cases {
		W, H :: 360, 40
		pixels := draw_text(c.text, c.size, 10, 26, W, H, c.ink, c.ground)
		r, err := ocr.recognize(pixels, W, H, W * 4, .RGBA, {languages = {language}})
		testing.expectf(t, err == .None, "%q: %v", c.text, err)
		if err != .None { continue }
		defer ocr.result_destroy(&r)
		testing.expect_value(t, r.engine, engine)
		testing.expectf(t, ascii.contains_fold(r.text, c.text), "%q read as %q", c.text, r.text)
		testing.expectf(t, len(r.lines) == 1, "%q: %d lines", c.text, len(r.lines))
		for l in r.lines {
			// (the rectangles are in the picture's pixels, around where the text was drawn)
			testing.expectf(t, l.rect.x >= 0 && l.rect.y >= 0 && l.rect.x + l.rect.width <= W && l.rect.y + l.rect.height <= H, "%v", l.rect)
			testing.expectf(t, l.rect.x < 20 && l.rect.y < 20 && l.rect.y + l.rect.height > 20, "%q at %v", l.text, l.rect)
			testing.expectf(t, len(l.words) >= 2, "%q: words %v", l.text, l.words)
		}
	}
}

// The engine's code of English: Tesseract's "eng", Windows' "en-US" or another "en-" tag.
@(private = "file")
english :: proc(installed: []string) -> string {
	for l in installed { if l == "eng" || l == "en-US" { return l } }
	for l in installed { if strings.has_prefix(l, "en-") { return l } }
	return ""
}

////////////////////////////////
// Text drawn from Roboto's outlines (TrueType: cmap format 4, loca, glyf, hmtx), filled by gt:paint

@(private = "file")
ROBOTO := #load("../../src/font/data/Roboto-Regular.ttf", []u8)

@(private = "file")
Face :: struct {
	data:                          []u8,
	units_per_em:                  f32,
	long_loca:                     bool,
	cmap, loca, glyf, hmtx:        int,   // offsets of the tables (cmap: of its format 4 subtable)
	metrics:                       int,   // hhea.numberOfHMetrics
}

@(private = "file") be16 :: proc(d: []u8, at: int) -> int { return int(d[at]) << 8 | int(d[at + 1]) }
@(private = "file") be16s :: proc(d: []u8, at: int) -> int { return int(i16(u16(be16(d, at)))) }
@(private = "file") be32 :: proc(d: []u8, at: int) -> int { return be16(d, at) << 16 | be16(d, at + 2) }

@(private = "file")
table :: proc(d: []u8, tag: string) -> int {
	for i in 0 ..< be16(d, 4) {
		record := 12 + 16 * i
		if string(d[record:record + 4]) == tag { return be32(d, record + 8) }
	}
	return -1
}

@(private = "file")
face_open :: proc(d: []u8) -> (f: Face) {
	f.data = d
	head := table(d, "head")
	f.units_per_em = f32(be16(d, head + 18))
	f.long_loca = be16s(d, head + 50) == 1
	f.loca, f.glyf, f.hmtx = table(d, "loca"), table(d, "glyf"), table(d, "hmtx")
	f.metrics = be16(d, table(d, "hhea") + 34)
	cmap := table(d, "cmap")
	for i in 0 ..< be16(d, cmap + 2) {
		record := cmap + 4 + 8 * i
		platform, encoding := be16(d, record), be16(d, record + 2)
		sub := cmap + be32(d, record + 4)
		if ((platform == 3 && encoding == 1) || platform == 0) && be16(d, sub) == 4 { f.cmap = sub; break }
	}
	return
}

@(private = "file")
glyph_index :: proc(f: Face, c: rune) -> int {
	d, sub := f.data, f.cmap
	segments := be16(d, sub + 6) / 2
	ends := sub + 14
	starts := ends + 2 * segments + 2
	deltas := starts + 2 * segments
	ranges := deltas + 2 * segments
	for i in 0 ..< segments {
		if int(c) > be16(d, ends + 2 * i) { continue }
		start := be16(d, starts + 2 * i)
		if int(c) < start { return 0 }
		delta := be16(d, deltas + 2 * i)
		offset := be16(d, ranges + 2 * i)
		if offset == 0 { return (int(c) + delta) & 0xFFFF }
		g := be16(d, ranges + 2 * i + offset + 2 * (int(c) - start))
		return g == 0 ? 0 : (g + delta) & 0xFFFF
	}
	return 0
}

@(private = "file")
advance :: proc(f: Face, g: int) -> f32 { return f32(be16(f.data, f.hmtx + 4 * min(g, f.metrics - 1))) }

// The outline of glyph `g` added to `path`: (x, y) in font units goes to (x0 + x * s, baseline - y * s).
@(private = "file")
add_glyph :: proc(f: Face, path: ^paint.Path, g: int, x0, baseline, s: f32, dx: f32 = 0, dy: f32 = 0) {
	d := f.data
	start, end: int
	if f.long_loca {
		start, end = be32(d, f.loca + 4 * g), be32(d, f.loca + 4 * g + 4)
	} else {
		start, end = 2 * be16(d, f.loca + 2 * g), 2 * be16(d, f.loca + 2 * g + 2)
	}
	if end <= start { return }   // (a space)
	at := f.glyf + start
	contours := be16s(d, at)
	if contours < 0 {
		// a composite: its parts, moved by their offsets (no scale in the letters drawn here)
		p := at + 10
		for {
			flags, part := be16(d, p), be16(d, p + 2)
			p += 4
			ox, oy: int
			if flags & 0x1 != 0 { ox, oy = be16s(d, p), be16s(d, p + 2); p += 4 } else { ox, oy = int(i8(d[p])), int(i8(d[p + 1])); p += 2 }
			if flags & 0x8 != 0 { p += 2 } else if flags & 0x40 != 0 { p += 4 } else if flags & 0x80 != 0 { p += 8 }
			add_glyph(f, path, part, x0, baseline, s, dx + f32(ox), dy + f32(oy))
			if flags & 0x20 == 0 { break }
		}
		return
	}
	ends := make([]int, contours, context.temp_allocator)
	for i in 0 ..< contours { ends[i] = be16(d, at + 10 + 2 * i) }
	count := contours > 0 ? ends[contours - 1] + 1 : 0
	p := at + 10 + 2 * contours
	p += 2 + be16(d, p)   // the instructions
	flags := make([]u8, count, context.temp_allocator)
	for i := 0; i < count; {
		flag := d[p]; p += 1
		flags[i] = flag; i += 1
		if flag & 0x8 != 0 {
			repeat := int(d[p]); p += 1
			for _ in 0 ..< repeat { if i < count { flags[i] = flag; i += 1 } }
		}
	}
	points := make([][2]f32, count, context.temp_allocator)
	v := 0
	for i in 0 ..< count {
		if flags[i] & 0x2 != 0 { v += flags[i] & 0x10 != 0 ? int(d[p]) : -int(d[p]); p += 1 } else if flags[i] & 0x10 == 0 { v += be16s(d, p); p += 2 }
		points[i].x = x0 + (f32(v) + dx) * s
	}
	v = 0
	for i in 0 ..< count {
		if flags[i] & 0x4 != 0 { v += flags[i] & 0x20 != 0 ? int(d[p]) : -int(d[p]); p += 1 } else if flags[i] & 0x20 == 0 { v += be16s(d, p); p += 2 }
		points[i].y = baseline - (f32(v) + dy) * s
	}
	first := 0
	for e in ends {
		add_contour(path, points[first:e + 1], flags[first:e + 1])
		first = e + 1
	}
}

// One closed contour of on- and off-curve points: two off-curve points in a row have an on-curve one between them.
@(private = "file")
add_contour :: proc(path: ^paint.Path, points: [][2]f32, flags: []u8) {
	n := len(points)
	if n == 0 { return }
	on :: proc(flags: []u8, i: int) -> bool { return flags[i] & 0x1 != 0 }
	first := -1
	for i in 0 ..< n { if on(flags, i) { first = i; break } }
	start: [2]f32
	from, steps: int
	if first >= 0 {
		start, from, steps = points[first], first + 1, n - 1
	} else {
		start, from, steps = (points[n - 1] + points[0]) / 2, 0, n
	}
	paint.move_to(path, start.x, start.y)
	control: [2]f32
	pending := false
	for k in 0 ..< steps {
		i := (from + k) % n
		pt := points[i]
		if on(flags, i) {
			if pending { paint.quad_to(path, control.x, control.y, pt.x, pt.y) } else { paint.line_to(path, pt.x, pt.y) }
			pending = false
		} else {
			if pending {
				mid := (control + pt) / 2
				paint.quad_to(path, control.x, control.y, mid.x, mid.y)
			}
			control, pending = pt, true
		}
	}
	if pending { paint.quad_to(path, control.x, control.y, start.x, start.y) } else { paint.line_to(path, start.x, start.y) }
	paint.close(path)
}

// `text` in Roboto at `size` pixels an em, its baseline at (x, baseline), `ink` on `ground` (0xRRGGBB): RGBA pixels.
@(private = "file")
draw_text :: proc(text: string, size: f32, x, baseline: f32, width, height: int, ink, ground: u32) -> []u8 {
	f := face_open(ROBOTO)
	s := size / f.units_per_em
	c := paint.canvas_make(width, height, context.temp_allocator)
	paint.clear(&c, paint.hex(ground))
	path: paint.Path
	defer paint.path_destroy(&path)
	pen := x
	for r in text {
		g := glyph_index(f, r)
		add_glyph(f, &path, g, pen, baseline, s)
		pen += advance(f, g) * s
	}
	paint.fill(&c, path, paint.solid(paint.hex(ink)))
	out := make([]u8, width * height * 4, context.temp_allocator)
	for px, i in c.pixels {
		for k in 0 ..< 4 { out[i * 4 + k] = u8(clamp(px[k] * 255 + 0.5, 0, 255)) }
	}
	return out
}
