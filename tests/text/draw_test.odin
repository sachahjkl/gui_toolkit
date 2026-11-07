package text_test

import "core:os"
import "core:testing"
import "../unwatched"
import "../../draw"
import "../../font"
import "../../render"

// Pixel tests of text drawn through the draw layer on an offscreen renderer (WARP).

DSIZE :: [2]int{360, 96}

Dfx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
}

@(private = "file")
open :: proc(t: ^testing.T, f: ^Dfx, space := render.Blend_Space.Srgb) -> bool {
	if !render.init_offscreen(&f.r, DSIZE, warp = true, space = space) { return false }
	font.init(&f.fonts)
	ok: bool
	f.ui, ok = font.load_system(&f.fonts, "Segoe UI")
	draw.init(&f.dc, &f.r, &f.fonts)
	return ok
}

@(private = "file")
close :: proc(f: ^Dfx) { draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

@(private = "file")
frame :: proc(f: ^Dfx, body: proc(f: ^Dfx)) -> []u8 {
	draw.begin_frame(&f.dc, {f32(DSIZE.x), f32(DSIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	body(f)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.temp_allocator)
}

@(private = "file")
pixel :: proc(img: []u8, x, y: int) -> [4]int {
	o := (y * DSIZE.x + x) * 4
	return {int(img[o]), int(img[o + 1]), int(img[o + 2]), int(img[o + 3])}
}

// Dark pixels and colored pixels in a rect.
@(private = "file")
census :: proc(img: []u8, x0, y0, x1, y1: int) -> (dark, colored: int) {
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			p := pixel(img, x, y)
			if p[0] + p[1] + p[2] < 300 { dark += 1 }
			if abs(p[0] - p[1]) > 50 || abs(p[1] - p[2]) > 50 || abs(p[0] - p[2]) > 50 { colored += 1 }
		}
	}
	return
}

// A 24-bit BMP of the frame in build/ (to look at).
@(private = "file")
save_bmp :: proc(path: string, img: []u8) {
	w, h := DSIZE.x, DSIZE.y
	row := (w * 3 + 3) &~ 3
	buf := make([]u8, 54 + row * h, context.temp_allocator)
	put32 :: proc(b: []u8, at: int, v: u32) { b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24) }
	buf[0], buf[1] = 'B', 'M'
	put32(buf, 2, u32(len(buf))); put32(buf, 10, 54); put32(buf, 14, 40)
	put32(buf, 18, u32(w)); put32(buf, 22, u32(h)); buf[26] = 1; buf[28] = 24
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := pixel(img, x, h - 1 - y)
			o := 54 + y * row + x * 3
			buf[o], buf[o + 1], buf[o + 2] = u8(p[2]), u8(p[1]), u8(p[0])
		}
	}
	_ = os.write_entire_file(path, buf)
}

// Text bigger than an atlas page is rasterized smaller and drawn stretched, not left out.
@(test)
draw_huge_text_is_stretched :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := new(Dfx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	img := frame(f, proc(f: ^Dfx) {
		// the stems of "I" at 3200 px are about 290 px wide and 2250 tall (more than a page): some cover the 360 x 96 frame
		for x := f32(-1200); x < 400; x += 150 { draw.text(&f.dc, f.ui, 3200, {x, 2000}, {0, 0, 0, 1}, "I") }
	})
	dark, _ := census(img, 0, 0, DSIZE.x, DSIZE.y)
	testing.expectf(t, dark > DSIZE.x * DSIZE.y / 10, "huge text is not drawn (%d dark pixels)", dark)
	testing.expect(t, font.atlas_page_count(&f.fonts) <= 2)
}) }

@(test)
draw_text_fallback_emoji_bidi :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := new(Dfx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	img := frame(f, proc(f: ^Dfx) {
		black := draw.Color{0, 0, 0, 1}
		draw.text(&f.dc, f.ui, 20, {4, 24}, black, "\u2190 retour office")       // arrow, ffi ligature
		draw.text(&f.dc, f.ui, 28, {4, 62}, black, "\U0001F600\U0001F44D\U0001F3FD")   // color emoji, skin tone
		draw.text(&f.dc, f.ui, 20, {130, 62}, black, "abc \u05e9\u05dc\u05d5\u05dd \u0633\u0644\u0627\u0645")
		draw.text(&f.dc, f.ui, 16, {4, 88}, black, "\u0915\u094d\u0937\u093f \u4e2d\u6587 \u0e20\u0e32\u0e29\u0e32\u0e44\u0e17\u0e22")
	})
	save_bmp("build/text_draw.bmp", img)
	dark, _ := census(img, 4, 8, 24, 30)   // the arrow
	testing.expectf(t, dark > 8, "the arrow is not drawn (%d dark pixels)", dark)
	_, colored := census(img, 4, 32, 110, 70)
	testing.expectf(t, colored > 100, "the emoji are not in color (%d colored pixels)", colored)
	dark_rtl, _ := census(img, 160, 40, 350, 70)
	testing.expect(t, dark_rtl > 50)
	dark_cjk, _ := census(img, 4, 72, 300, 95)
	testing.expect(t, dark_cjk > 50)
}) }

@(private = "file") strip_count: int

// Text in a narrow clip makes instances for the glyphs in it only, and the same pixels there as unclipped: text drawn again in
// strips (a find's matches: the text in each piece of its rows) made every glyph in every strip, hundreds of MB of instances.
@(test)
draw_text_outside_the_clip_makes_no_instance :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := new(Dfx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	LINE :: "hamburgefonts hamburgefonts hamburgefonts"
	_ = frame(f, proc(f: ^Dfx) { draw.text(&f.dc, f.ui, 20, {4, 40}, {0, 0, 0, 1}, LINE) })   // (the glyphs rasterized)
	whole := frame(f, proc(f: ^Dfx) { draw.text(&f.dc, f.ui, 20, {4, 40}, {0, 0, 0, 1}, LINE); strip_count = len(f.dc.insts) })
	all := strip_count
	strip := frame(f, proc(f: ^Dfx) {
		draw.push_clip(&f.dc, {{0, 0}, {48, f32(DSIZE.y)}})
		draw.text(&f.dc, f.ui, 20, {4, 40}, {0, 0, 0, 1}, LINE)
		draw.pop_clip(&f.dc)
		strip_count = len(f.dc.insts)
	})
	testing.expectf(t, all > 30, "the line's glyphs: %d", all)
	testing.expectf(t, strip_count < all / 4, "only the strip's glyphs: %d of %d", strip_count, all)
	for y in 0 ..< DSIZE.y {
		for x in 0 ..< 48 {
			if pixel(whole, x, y) != pixel(strip, x, y) { testing.expectf(t, false, "the strip differs at %d,%d", x, y); return }
		}
	}
}) }

// A frame that drew a hundred times what frames draw leaves no buffer at its size: the instance list (and the renderer's buffer)
// goes back down after frames that used little of it.
@(test)
draw_instances_shrink_after_a_peak :: proc(t: ^testing.T) { unwatched.run(t, proc(t: ^testing.T) {
	f := new(Dfx)
	defer free(f)
	if !open(t, f) { testing.fail_now(t, "no offscreen renderer or Segoe UI") }
	defer close(f)
	_ = frame(f, proc(f: ^Dfx) { for i in 0 ..< 200_000 { draw.rect(&f.dc, {{f32(i % 300), 0}, {f32(i % 300) + 1, 1}}, {0, 0, 0, 1}) } })
	peak := cap(f.dc.insts)
	testing.expectf(t, peak >= 200_000, "the peak: %d", peak)
	for _ in 0 ..< render.SHRINK_FRAMES + 2 { _ = frame(f, proc(f: ^Dfx) { draw.rect(&f.dc, {{0, 0}, {10, 10}}, {0, 0, 0, 1}) }) }
	testing.expectf(t, cap(f.dc.insts) < peak / 8, "back down: %d of %d", cap(f.dc.insts), peak)
	// and drawing goes on as before
	img := frame(f, proc(f: ^Dfx) { draw.rect(&f.dc, {{0, 0}, {10, 10}}, {0, 0, 0, 1}) })
	testing.expect_value(t, pixel(img, 5, 5), [4]int{0, 0, 0, 255})
}) }

@(test)
a_buffer_shrinks_after_frames_that_use_little_of_it :: proc(t: ^testing.T) {
	low := 0
	room := render.SHRINK_MIN_ELEMS * 64
	for _ in 0 ..< render.SHRINK_FRAMES - 1 { testing.expect(t, !render.shrink_due(room, 10, &low), "not yet") }
	testing.expect(t, render.shrink_due(room, 10, &low), "now")
	// one frame that uses it starts the count again
	for _ in 0 ..< render.SHRINK_FRAMES - 1 { _ = render.shrink_due(room, 10, &low) }
	testing.expect(t, !render.shrink_due(room, room / 2, &low), "used")
	testing.expect_value(t, low, 0)
	// a small buffer stays
	for _ in 0 ..< render.SHRINK_FRAMES * 2 { testing.expect(t, !render.shrink_due(render.SHRINK_MIN_ELEMS, 0, &low), "small") }
}
