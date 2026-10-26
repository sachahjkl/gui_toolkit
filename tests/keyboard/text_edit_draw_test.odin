// text_edit_caret_rect against what is drawn: the editor is drawn on an offscreen renderer (WARP) with its caret at the
// start, then at the end of the first (wrapped) line; the pixels that change are the two caret bars, which must lie in
// the rectangles text_edit_caret_rect gave for each frame.
package keyboard_test

import "core:sync"
import "core:testing"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

@(private = "file") SIZE :: [2]int{320, 160}

@(private = "file")
Dfx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	theme: ui.Theme,
	s:     ui.State,
	ui_font: font.Font_Id,
	area:  ui.Text_Area,
}

@(private = "file")
lock: sync.Mutex

@(private = "file")
frame :: proc(f: ^Dfx, events: []platform.Event) -> []u8 {
	ui.begin_build(&f.s, {
		window_size = {f32(SIZE.x), f32(SIZE.y)}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
	})
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(200)})
	ui.text_edit("###d", &f.area, wrap = true, auto_height = true, max_lines = 4)
	ui.end_build()
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {1, 1, 1, 1})
	ui.draw_tree(&f.s, &f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	px := render.read_pixels(&f.r, context.allocator)
	free_all(context.temp_allocator)
	return px
}

@(test)
caret_rect_is_where_the_caret_is_drawn :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Dfx)
	defer free(f)
	if !render.init_offscreen(&f.r, SIZE, warp = true) { testing.fail_now(t, "no D3D11 device (WARP)") }
	font.init(&f.fonts)
	ok: bool
	f.ui_font, ok = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer {
		ui.area_destroy(&f.area)
		ui.destroy(&f.s); ui.theme_destroy(&f.theme)
		draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts)
	}
	if !testing.expect(t, ok, "font") { return }
	delete(frame(f, nil))
	delete(frame(f, nil))
	ui.set_focus(ui.box_from_key(ui.key_from_string(ui.key_from_string(0, "root"), "###d")).key)
	ui.area_set(&f.area, "the caret moves along a line that wraps in this narrow box")
	f.area.cursor, f.area.mark = 0, 0
	delete(frame(f, nil))
	a := frame(f, {{kind = .Key_Press, key = .Home}})
	defer delete(a)
	ra, _, oka := ui.text_edit_caret_rect(&f.area)
	b := frame(f, {{kind = .Key_Press, key = .End}})
	defer delete(b)
	rb, _, okb := ui.text_edit_caret_rect(&f.area)
	testing.expect(t, oka && okb, "drawn")
	testing.expectf(t, rb.min.x > ra.min.x + 50 && abs(rb.min.y - ra.min.y) < 0.5, "End: same line, to the right (%v, %v)", ra, rb)
	inside :: proc(r: ui.Rect, x, y: int) -> bool {
		return f32(x) >= r.min.x - 1 && f32(x) < r.max.x + 1 && f32(y) >= r.min.y - 1 && f32(y) < r.max.y + 1
	}
	in_a, in_b, outside := 0, 0, 0
	for y in 0 ..< SIZE.y {
		for x in 0 ..< SIZE.x {
			o := (y * SIZE.x + x) * 4
			if a[o] == b[o] && a[o + 1] == b[o + 1] && a[o + 2] == b[o + 2] { continue }
			switch {
			case inside(ra, x, y): in_a += 1
			case inside(rb, x, y): in_b += 1
			case: outside += 1
			}
		}
	}
	testing.expectf(t, in_a > 5 && in_b > 5, "both caret bars drawn in their rectangles (%d, %d pixels)", in_a, in_b)
	testing.expectf(t, outside == 0, "nothing else changed (%d pixels outside the two rectangles)", outside)
}
