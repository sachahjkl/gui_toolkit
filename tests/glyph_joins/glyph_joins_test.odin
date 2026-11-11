package glyph_joins_test

// The joins of a letter survive its rasterization: the eye of an "e" (its bar meets its bowl) stays closed at every size of
// interface text, at every horizontal position a glyph takes (font.Settings.subpixel_steps), in grey and per colour stripe.
// Dark text on a light page, as a toast of a light theme is: there a faint join pixel is lost first.
//
// A letter is cut a quarter of the way from the page to the ink; the holes of what is dark are counted (light regions the
// edge of its cell does not reach). An "e" has one.

import "core:fmt"
import "core:os"
import "core:testing"
import "../../src/draw"
import "../../src/font"
import "../../src/png"
import "../../src/render"

HANKEN_600 :: #load("data/hanken-grotesk-600.ttf")
HANKEN_400 :: #load("data/hanken-grotesk-400.ttf")

SIZES :: [?]f32{13, 14, 15, 16, 17, 18, 19, 20, 22}
PHASES :: 4
CELL :: 32
IMAGE :: [2]int{CELL * PHASES * 2, CELL * len(SIZES)}   // a row per size; four phases of the bold, then four of the regular

INK_CUT :: 0.25   // what darker than the page by this share of the contrast is ink (holes)
PAGE :: draw.Color{0.99, 0.95, 0.84, 1}   // a light toast's cream
INK  :: draw.Color{0.10, 0.09, 0.08, 1}

Fx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	bold, regular: font.Font_Id,
}

open :: proc(f: ^Fx, stripes: font.Subpixel_Text, grid: font.Grid_Fit) -> bool {
	if !render.init_offscreen(&f.r, IMAGE, warp = true) { fmt.eprintln("no offscreen renderer"); return false }
	st := font.DEFAULT_SETTINGS
	st.text_renderer = render.USE_WGPU ? .Slug : .Atlas
	st.subpixel_text = stripes
	st.grid_fit = grid
	font.init(&f.fonts, st)
	ok1, ok2: bool
	f.bold, ok1 = font.load_embedded(&f.fonts, HANKEN_600)
	f.regular, ok2 = font.load_embedded(&f.fonts, HANKEN_400)
	draw.init(&f.dc, &f.r, &f.fonts)
	if !ok1 || !ok2 { fmt.eprintln("the faces:", ok1, ok2) }
	return ok1 && ok2
}

close :: proc(f: ^Fx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

// Every size, every phase, both weights: an "e" in each cell.
@(private = "file")
letters :: proc(f: ^Fx) -> []u8 {
	draw.begin_frame(&f.dc, {f32(IMAGE.x), f32(IMAGE.y)})
	render.frame_begin(&f.r, {PAGE.r, PAGE.g, PAGE.b, 1})
	for size, row in SIZES {
		for col in 0 ..< PHASES * 2 {
			face := col < PHASES ? f.bold : f.regular
			phase := f32(col % PHASES) / PHASES
			draw.text(&f.dc, face, size, {f32(col * CELL + 8) + phase, f32(row * CELL + 24)}, INK, "e")
		}
	}
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

// The holes of the dark part of a cell: light regions not reached from its edge.
holes :: proc(img: []u8, cx, cy: int) -> int {
	lum :: proc(img: []u8, x, y: int) -> f32 {
		o := (y * IMAGE.x + x) * 4
		return (0.2126 * f32(img[o]) + 0.7152 * f32(img[o + 1]) + 0.0722 * f32(img[o + 2])) / 255
	}
	// (ink: a quarter of the way from the page to the ink, at least: a join of partial coverage is still a join, and the eye is
	// what stays near the page)
	page := 0.2126 * PAGE.r + 0.7152 * PAGE.g + 0.0722 * PAGE.b
	cut := page - INK_CUT * (page - (0.2126 * INK.r + 0.7152 * INK.g + 0.0722 * INK.b))
	light: [CELL][CELL]bool
	seen: [CELL][CELL]bool
	for y in 0 ..< CELL { for x in 0 ..< CELL { light[y][x] = lum(img, cx * CELL + x, cy * CELL + y) > cut } }
	fill :: proc(light, seen: ^[CELL][CELL]bool, x0, y0: int) {
		stack: [CELL * CELL][2]int
		n := 0
		stack[0] = {x0, y0}; n = 1
		seen[y0][x0] = true
		for n > 0 {
			n -= 1
			p := stack[n]
			for d in ([4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
				x, y := p.x + d.x, p.y + d.y
				if x < 0 || y < 0 || x >= CELL || y >= CELL || seen[y][x] || !light[y][x] { continue }
				seen[y][x] = true
				stack[n] = {x, y}; n += 1
			}
		}
	}
	for i in 0 ..< CELL {
		for e in ([4][2]int{{i, 0}, {i, CELL - 1}, {0, i}, {CELL - 1, i}}) {
			if light[e.y][e.x] && !seen[e.y][e.x] { fill(&light, &seen, e.x, e.y) }
		}
	}
	n := 0
	for y in 0 ..< CELL { for x in 0 ..< CELL { if light[y][x] && !seen[y][x] { n += 1; fill(&light, &seen, x, y) } } }
	return n
}

// The survey: the holes of every "e", each way of drawing them, and a picture of each in build/session/glyph_joins.
@(test)
the_eye_of_an_e_stays_closed :: proc(t: ^testing.T) {
	os.make_directory_all("build/session/glyph_joins")
	open_eyes := 0
	for stripes in ([]font.Subpixel_Text{.Rgb, .Off}) {
		for grid in ([]font.Grid_Fit{.Default, .Disabled}) {
			f := new(Fx)
			defer free(f)
			if !testing.expect(t, open(f, stripes, grid), "a renderer and the faces") { return }
			defer close(f)
			img := letters(f)
			name := fmt.tprintf("build/session/glyph_joins/%v_%v.png", stripes, grid)
			_ = os.write_entire_file(name, png.encode(img, IMAGE.x, IMAGE.y, allocator = context.temp_allocator))
			for size, row in SIZES {
				line := fmt.tprintf("%v %v %4.0f px  bold", stripes, grid, size)
				for col in 0 ..< PHASES * 2 {
					if col == PHASES { line = fmt.tprintf("%s  regular", line) }
					h := holes(img, col, row)
					if h != 1 { open_eyes += 1 }
					line = fmt.tprintf("%s %d", line, h)
				}
				fmt.println(line)
			}
		}
	}
	testing.expectf(t, open_eyes == 0, "%d letters with their eye open (the table above: a hole per e)", open_eyes)
}
