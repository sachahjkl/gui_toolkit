// Tests of color glyphs: COLR v1 paint trees (gradients, transforms, compositions, text-color paints), sbix and CBDT
// bitmaps, OT-SVG (plain and gzip-compressed), and color glyphs drawn through the draw layer (WARP). Test fonts and
// their licences: data/README.txt.
package color_glyphs_test

import "base:intrinsics"
import "core:testing"
import "../../draw"
import "../../font"
import "../../render"

COLRV1 :: #load("data/test_glyphs-glyf_colr_1.ttf")
SBIX :: #load("data/twemoji_smiley-sbix.ttf")
PICOSVG :: #load("data/twemoji_smiley-picosvg.ttf")
SVGZ :: #load("data/twemoji_smiley-untouchedsvgz.ttf")
CBDT :: #load("data/chromacheck-cbdt.ttf")

RGBA :: [4]int

// A glyph bitmap read back from its atlas page: straight-alpha sRGB RGBA (coverage as gray).
Bitmap :: struct {
	img: font.Glyph_Image,
	w, h: int,
	px: []RGBA,
}

@(private = "file")
Sync :: struct { stride: int, pixels: []u8 }

bitmap_of :: proc(s: ^font.State, img: font.Glyph_Image) -> Bitmap {
	b := Bitmap{img = img, w = int(img.size.x), h = int(img.size.y)}
	if img.page < 0 { return b }
	sy: Sync
	font.atlas_sync_page(s, int(img.page), 0, &sy, proc(user: rawptr, page: int, kind: font.Page_Kind, x, y, w, h: int, pixels: []u8, stride: int) {
		(^Sync)(user)^ = Sync{stride, pixels}
	})
	b.px = make([]RGBA, b.w * b.h, context.temp_allocator)
	for row in 0 ..< b.h {
		for col in 0 ..< b.w {
			if img.color {
				o := (int(img.uv[1]) + row) * sy.stride + (int(img.uv[0]) + col) * 4
				b.px[row * b.w + col] = {int(sy.pixels[o]), int(sy.pixels[o + 1]), int(sy.pixels[o + 2]), int(sy.pixels[o + 3])}
			} else {
				v := int(sy.pixels[(int(img.uv[1]) + row) * sy.stride + int(img.uv[0]) + col])
				b.px[row * b.w + col] = {0, 0, 0, v}
			}
		}
	}
	return b
}

at :: proc(b: Bitmap, fx, fy: f32) -> RGBA {
	x := clamp(int(fx * f32(b.w)), 0, b.w - 1)
	y := clamp(int(fy * f32(b.h)), 0, b.h - 1)
	return b.px[y * b.w + x]
}

near :: proc(p: RGBA, want: [3]int, tol: int) -> bool {
	return abs(p[0] - want[0]) <= tol && abs(p[1] - want[1]) <= tol && abs(p[2] - want[2]) <= tol && p[3] > 200
}

// Pixels of a bitmap close to a color (opaque).
count_near :: proc(b: Bitmap, want: [3]int, tol: int) -> int {
	n := 0
	for p in b.px { if near(p, want, tol) { n += 1 } }
	return n
}

Fx :: struct {
	s: font.State,
	colr, sbix, svg, svgz, cbdt: font.Font_Id,
}

@(private = "file")
open :: proc(t: ^testing.T, f: ^Fx) -> bool {
	font.init(&f.s)
	ok1, ok2, ok3, ok4, ok5: bool
	f.colr, ok1 = font.load_embedded(&f.s, COLRV1)
	f.sbix, ok2 = font.load_embedded(&f.s, SBIX)
	f.svg, ok3 = font.load_embedded(&f.s, PICOSVG)
	f.svgz, ok4 = font.load_embedded(&f.s, SVGZ)
	f.cbdt, ok5 = font.load_embedded(&f.s, CBDT)
	return ok1 && ok2 && ok3 && ok4 && ok5
}

// The glyph of `r` in `id` (no fallback: the test fonts must have it).
@(private = "file")
glyph_of :: proc(f: ^Fx, id: font.Font_Id, r: rune, size: f32, fg := [3]u8{0, 0, 0}) -> Bitmap {
	buf: [4]u8
	n := 0
	c := u32(r)
	switch {
	case c < 0x80: buf[0] = u8(c); n = 1
	case c < 0x800: buf[0] = u8(0xC0 | c >> 6); buf[1] = u8(0x80 | c & 0x3F); n = 2
	case c < 0x10000: buf[0] = u8(0xE0 | c >> 12); buf[1] = u8(0x80 | (c >> 6) & 0x3F); buf[2] = u8(0x80 | c & 0x3F); n = 3
	case: buf[0] = u8(0xF0 | c >> 18); buf[1] = u8(0x80 | (c >> 12) & 0x3F); buf[2] = u8(0x80 | (c >> 6) & 0x3F); buf[3] = u8(0x80 | c & 0x3F); n = 4
	}
	cas := font.cascade(&f.s, {{font = id}}, nil, true)
	sh := font.shape(&f.s, cas, size, string(buf[:n]), {}, context.temp_allocator)
	if len(sh.glyphs) != 1 || sh.glyphs[0].face != id { return {} }
	return bitmap_of(&f.s, font.glyph_image(&f.s, id, sh.glyphs[0].id, size, 0, fg))
}

@(test)
colrv1_linear_gradient :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	if !font.color_renderable(&f.s, f.colr) { testing.fail_now(t, "COLR v1 paint trees need Windows 11 22H2 (ID2D1DeviceContext7)") }
	// linear_repeat_0_1: red at x = 100, blue at x = 900 (font units), a 800 x 700 box
	b := glyph_of(f, f.colr, 0xF0100, 64)
	testing.expect(t, b.img.color && b.img.page >= 0, "not drawn as a color glyph")
	if b.w == 0 { return }
	left, right, mid := at(b, 0.02, 0.5), at(b, 0.98, 0.5), at(b, 0.5, 0.5)
	testing.expectf(t, near(left, {255, 0, 0}, 40), "left edge %v, want red", left)
	testing.expectf(t, near(right, {0, 0, 255}, 40), "right edge %v, want blue", right)
	// interpolated on sRGB values (premultiplied, opaque): half red, half blue
	testing.expectf(t, near(mid, {128, 0, 128}, 40), "middle %v, want purple", mid)
	// the clip box: 800 x 700 units of 1000 -> 51 x 45 px (the box is the glyph's ink)
	testing.expectf(t, abs(b.w - 51) <= 2 && abs(b.h - 45) <= 2, "size %d x %d, want 51 x 45", b.w, b.h)
}

@(test)
colrv1_sweep_radial_composite_transform :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	if !font.color_renderable(&f.s, f.colr) { testing.fail_now(t, "COLR v1 paint trees need Windows 11 22H2") }
	// sweep: the four quadrants around the center differ
	sw := glyph_of(f, f.colr, 0xF0200, 64)
	q := [4]RGBA{at(sw, 0.3, 0.3), at(sw, 0.7, 0.3), at(sw, 0.3, 0.7), at(sw, 0.7, 0.7)}
	differ := 0
	for i in 0 ..< 4 { for j in i + 1 ..< 4 { if abs(q[i][0] - q[j][0]) + abs(q[i][1] - q[j][1]) + abs(q[i][2] - q[j][2]) > 60 { differ += 1 } } }
	testing.expectf(t, differ >= 5, "sweep quadrants %v are not distinct", q)
	// radial_contained_gradient_extend_mode_pad: a small green circle inside, red padded around it
	rad := glyph_of(f, f.colr, 0xF0503, 64)
	red, greenish := 0, 0
	for p in rad.px {
		if near(p, {255, 0, 0}, 30) { red += 1 }
		if p[3] > 200 && p[1] > p[0] + 40 { greenish += 1 }
	}
	testing.expectf(t, red > len(rad.px) / 2 && greenish > 10, "radial: %d red, %d green pixels", red, greenish)
	// PaintComposite SRC_IN: a filled box
	comp := glyph_of(f, f.colr, 0xF0A05, 48)
	opaque := 0
	for p in comp.px { if p[3] > 200 { opaque += 1 } }
	testing.expectf(t, comp.img.color && opaque > 100, "composite: %d opaque pixels", opaque)
	// PaintRotate, PaintSkew, PaintTransform: a fixed blue cross and an orange one transformed
	for r in ([?]rune{0xF0600, 0xF0700, 0xF0800}) {
		b := glyph_of(f, f.colr, r, 48)
		orange, blue := 0, 0
		for p in b.px {
			if p[3] > 100 && p[0] > 180 && p[2] < 120 { orange += 1 }
			if p[3] > 100 && p[2] > 180 && p[0] < 180 { blue += 1 }
		}
		testing.expectf(t, b.img.color && orange > 5 && blue > 5, "glyph U+%X: %d orange, %d blue pixels", r, orange, blue)
	}
	// (not tested here: the PaintColrGlyph cycle U+F1100. DirectWrite detects it by throwing a C++ exception it
	// catches itself, which the test runner's vectored exception handler takes for a crash; outside tests the glyph
	// translates to DWRITE_E_NOCOLOR and is drawn as its outline.)
}

@(test)
colrv1_text_color :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	if !font.color_renderable(&f.s, f.colr) { testing.fail_now(t, "COLR v1 paint trees need Windows 11 22H2") }
	// foreground_color_solid_alpha_1: the whole box in the text color
	g := glyph_of(f, f.colr, 0xF0B06, 40, {0, 160, 0})
	testing.expect(t, g.img.uses_fg, "a text-color paint must make the glyph depend on the text color")
	testing.expectf(t, near(at(g, 0.5, 0.5), {0, 160, 0}, 8), "green text: %v", at(g, 0.5, 0.5))
	b := glyph_of(f, f.colr, 0xF0B06, 40, {20, 40, 220})
	testing.expectf(t, near(at(b, 0.5, 0.5), {20, 40, 220}, 8), "blue text: %v", at(b, 0.5, 0.5))
	testing.expect(t, g.img.uv != b.img.uv, "one bitmap per text color")
	again := glyph_of(f, f.colr, 0xF0B06, 40, {0, 160, 0})
	testing.expect(t, again.img.uv == g.img.uv, "the green bitmap is reused")
	// foreground_color_linear_alpha_1: orange at the ends, the text color in the middle
	l := glyph_of(f, f.colr, 0xF0B00, 64, {0, 0, 255})
	testing.expectf(t, near(at(l, 0.02, 0.5), {255, 165, 0}, 40), "linear end %v, want orange", at(l, 0.02, 0.5))
	testing.expectf(t, near(at(l, 0.5, 0.5), {0, 0, 255}, 50), "linear middle %v, want the text color", at(l, 0.5, 0.5))
	// a glyph without text-color paints is shared by every text color
	r1 := glyph_of(f, f.colr, 0xF0100, 40, {0, 0, 0})
	r2 := glyph_of(f, f.colr, 0xF0100, 40, {255, 255, 255})
	testing.expect(t, !r1.img.uses_fg && r1.img.uv == r2.img.uv)
}

// Twemoji's smiling face: a yellow disc (#FFCC4D) with a dark brown mouth and eyes (#664500).
@(private = "file")
check_smiley :: proc(t: ^testing.T, what: string, b: Bitmap) {
	testing.expectf(t, b.img.color && b.img.page >= 0, "%s: not drawn as a color glyph", what)
	yellow := count_near(b, {255, 204, 77}, 30)
	brown := count_near(b, {102, 69, 0}, 40)
	testing.expectf(t, yellow > b.w * b.h / 3, "%s: %d yellow pixels of %d", what, yellow, b.w * b.h)
	testing.expectf(t, brown > 20, "%s: %d brown pixels", what, brown)
	testing.expectf(t, b.w >= 40 && b.w <= 64 && b.h >= 40 && b.h <= 64, "%s: size %d x %d", what, b.w, b.h)
}

@(test)
bitmap_and_svg_glyphs :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	check_smiley(t, "sbix", glyph_of(f, f.sbix, 0x1F603, 48))
	check_smiley(t, "OT-SVG", glyph_of(f, f.svg, 0x1F603, 48))
	check_smiley(t, "OT-SVG gzip", glyph_of(f, f.svgz, 0x1F603, 48))
	// CBDT: ChromaCheck's glyph 1 is a filled square bitmap
	cb := bitmap_of(&f.s, font.glyph_image(&f.s, f.cbdt, 1, 40, 0))
	testing.expect(t, cb.img.color && cb.w >= 30 && cb.h >= 30, "CBDT glyph not drawn as a bitmap")
	if cb.w > 0 {
		p := at(cb, 0.5, 0.5)
		testing.expectf(t, p[3] == 255 && p[0] > p[1] + 40, "CBDT center %v", p)
	}
	// bitmaps never use the text color
	s2 := glyph_of(f, f.sbix, 0x1F603, 48, {255, 0, 0})
	testing.expect(t, !s2.img.uses_fg)
}

@(test)
color_glyphs_off :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	st := f.s.settings
	st.color_glyphs = false
	font.set_settings(&f.s, st)
	b := glyph_of(f, f.colr, 0xF0100, 40)
	testing.expect(t, !b.img.color, "with color glyphs off a COLR v1 glyph is its outline")
}

@(test)
async_color_glyphs :: proc(t: ^testing.T) {
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	st := f.s.settings
	st.color_async = true
	font.set_settings(&f.s, st)
	@(static) calls: int
	calls = 0
	font.set_color_ready_callback(&f.s, proc(user: rawptr) { sync_add(&calls) }, nil)
	cas := font.cascade(&f.s, {{font = f.colr}}, nil, true)
	sh := font.shape(&f.s, cas, 40, "\U000F0100\U000F0B06", {}, context.temp_allocator)
	testing.expect_value(t, len(sh.glyphs), 2)
	gen := font.color_ready_generation(&f.s)
	a := font.glyph_image(&f.s, f.colr, sh.glyphs[0].id, 40, 0)
	b := font.glyph_image(&f.s, f.colr, sh.glyphs[1].id, 40, 0, {0, 160, 0})
	testing.expect(t, a.pending && b.pending && a.page < 0, "the first lookups do not wait")
	again := font.glyph_image(&f.s, f.colr, sh.glyphs[0].id, 40, 0)
	testing.expect(t, again.pending, "asked again while pending: still pending, not queued twice")
	font.color_wait(&f.s)
	testing.expect(t, font.color_ready_generation(&f.s) - gen == 2, "two requests drawn")
	testing.expect(t, sync_load(&calls) >= 1, "the ready callback was called")
	a2 := bitmap_of(&f.s, font.glyph_image(&f.s, f.colr, sh.glyphs[0].id, 40, 0))
	testing.expect(t, !a2.img.pending && a2.img.color && near(at(a2, 0.02, 0.5), {255, 0, 0}, 40), "the gradient glyph after it was drawn")
	b2 := bitmap_of(&f.s, font.glyph_image(&f.s, f.colr, sh.glyphs[1].id, 40, 0, {0, 160, 0}))
	testing.expect(t, b2.img.uses_fg && near(at(b2, 0.5, 0.5), {0, 160, 0}, 8), "the text-color glyph in green")
	// another text color for a glyph known to use it: queued again, for that color
	c := font.glyph_image(&f.s, f.colr, sh.glyphs[1].id, 40, 0, {200, 0, 0})
	testing.expect(t, c.pending)
	font.color_wait(&f.s)
	c2 := bitmap_of(&f.s, font.glyph_image(&f.s, f.colr, sh.glyphs[1].id, 40, 0, {200, 0, 0}))
	testing.expect(t, near(at(c2, 0.5, 0.5), {200, 0, 0}, 8), "the same glyph in red")
	// a face unloaded with a request queued: the request is dropped
	_ = font.glyph_image(&f.s, f.sbix, 2, 30, 0)
	font.unload(&f.s, f.sbix)
	font.color_wait(&f.s)
}

@(private = "file")
sync_add :: proc(p: ^int) { intrinsics.atomic_add(p, 1) }
@(private = "file")
sync_load :: proc(p: ^int) -> int { return intrinsics.atomic_load(p) }

// A picture recorded while a color glyph is pending is stale when it is ready, then replays with it.
@(test)
async_glyphs_in_pictures :: proc(t: ^testing.T) {
	r: render.Renderer
	if !render.init_offscreen(&r, DSIZE, warp = true, space = .Srgb) { testing.fail_now(t, "no offscreen renderer") }
	defer render.destroy(&r)
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	st := f.s.settings
	st.color_async = true
	font.set_settings(&f.s, st)
	dc: draw.Context
	draw.init(&dc, &r, &f.s)
	defer draw.destroy(&dc)
	pic: draw.Picture
	defer draw.picture_destroy(&dc, &pic)
	colr := font.cascade(&f.s, {{font = f.colr}}, nil, true)
	record_and_replay :: proc(dc: ^draw.Context, r: ^render.Renderer, pic: ^draw.Picture, colr: font.Font_Id, record: bool) -> (draw.Replay_Result, []u8) {
		draw.begin_frame(dc, {f32(DSIZE.x), f32(DSIZE.y)})
		render.frame_begin(r, {1, 1, 1, 1})
		if record {
			draw.picture_begin(dc, pic)
			draw.text(dc, colr, 48, {10, 60}, draw.Color{0, 0, 0, 1}, "\U000F0100")
			draw.picture_end(dc)
		}
		res := draw.replay(dc, pic, draw.AFFINE_IDENTITY)
		draw.end_frame(dc)
		render.frame_end(r)
		return res, render.read_pixels(r, context.temp_allocator)
	}
	px :: proc(img: []u8, x, y: int) -> RGBA {
		o := (y * DSIZE.x + x) * 4
		return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
	}
	_, first := record_and_replay(&dc, &r, &pic, colr, true)
	testing.expect(t, pic.glyphs_pending, "recorded while the glyph was pending")
	testing.expect(t, px(first, 17, 40) == {255, 255, 255, 255}, "nothing drawn yet")
	font.color_wait(&f.s)
	res, _ := record_and_replay(&dc, &r, &pic, colr, false)
	testing.expect_value(t, res, draw.Replay_Result.Stale)
	_, after := record_and_replay(&dc, &r, &pic, colr, true)
	l := px(after, 17, 40)
	testing.expectf(t, !pic.glyphs_pending && l[0] > 200 && l[2] < 60, "recorded again with the glyph: %v", l)
	res2, _ := record_and_replay(&dc, &r, &pic, colr, false)
	testing.expect_value(t, res2, draw.Replay_Result.Drawn)
}

////////////////////////////////
// Through the draw layer

DSIZE :: [2]int{320, 80}

@(test)
color_glyphs_drawn :: proc(t: ^testing.T) {
	r: render.Renderer
	if !render.init_offscreen(&r, DSIZE, warp = true, space = .Srgb) { testing.fail_now(t, "no offscreen renderer") }
	defer render.destroy(&r)
	f := new(Fx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "test fonts did not load") }
	defer font.destroy(&f.s)
	dc: draw.Context
	draw.init(&dc, &r, &f.s)
	defer draw.destroy(&dc)
	colr := font.cascade(&f.s, {{font = f.colr}}, nil, true)
	sbix := font.cascade(&f.s, {{font = f.sbix}}, nil, true)
	draw.begin_frame(&dc, {f32(DSIZE.x), f32(DSIZE.y)})
	render.frame_begin(&r, {1, 1, 1, 1})
	green := draw.srgb(0, 160 / 255.0, 0)
	draw.text(&dc, colr, 48, {10, 60}, green, "\U000F0100\U000F0B06")
	draw.text(&dc, sbix, 48, {200, 60}, green, "\U0001F603")
	draw.end_frame(&dc)
	render.frame_end(&r)
	img := render.read_pixels(&r, context.temp_allocator)
	px :: proc(img: []u8, x, y: int) -> RGBA {
		o := (y * DSIZE.x + x) * 4
		return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
	}
	// the linear gradient's ends, the text-color glyph in the text color, the smiley's yellow
	l, rr := px(img, 17, 40), px(img, 50, 40)
	testing.expectf(t, l[0] > 200 && l[2] < 60, "gradient start on screen %v", l)
	testing.expectf(t, rr[2] > 200 && rr[0] < 60, "gradient end on screen %v", rr)
	g := px(img, 80, 40)
	testing.expectf(t, abs(g[0] - 0) < 10 && abs(g[1] - 160) < 10 && abs(g[2] - 0) < 10, "text color glyph on screen %v", g)
	y := px(img, 224, 30)
	testing.expectf(t, y[0] > 220 && y[1] > 170 && y[2] < 120, "smiley on screen %v", y)
}
