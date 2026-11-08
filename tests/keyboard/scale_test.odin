// What is drawn in pixels of its own follows the scale: at 200 % as thick as twice 100 %.
package keyboard_test

import "core:sync"
import "core:testing"
import "../../src/draw"
import "../../src/font"
import "../../src/render"
import "../../src/ui"

@(private = "file") SIZE :: [2]int{400, 200}
@(private = "file") lock: sync.Mutex

@(private = "file")
Sx :: struct {
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	theme: ui.Theme,
	s:     ui.State,
	ui_font: font.Font_Id,
}

@(private = "file")
picture :: proc(f: ^Sx, dpi: f32, body: proc(user: rawptr), user: rawptr) -> []u8 {
	for _ in 0 ..< 2 {
		ui.begin_build(&f.s, {
			window_size = {f32(SIZE.x), f32(SIZE.y)}, dt = 1.0 / 60, animations = false, dpi_scale = dpi,
			base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.ui_font, font_size = 15, text_pad = 6},
		})
		body(user)
		ui.end_build()
		free_all(context.temp_allocator)
	}
	draw.begin_frame(&f.dc, {f32(SIZE.x), f32(SIZE.y)})
	render.frame_begin(&f.r, {0, 0, 0, 1})
	ui.draw_tree(&f.s, &f.dc)
	draw.end_frame(&f.dc)
	render.frame_end(&f.r)
	return render.read_pixels(&f.r, context.allocator)
}

@(private = "file")
differs :: proc(a, b: []u8, x, y: int) -> bool {
	k := (y * SIZE.x + x) * 4
	return a[k] != b[k] || a[k + 1] != b[k + 1] || a[k + 2] != b[k + 2]
}

@(private = "file")
Tab_Run :: struct { sel: int }

@(test)
sizes_follow_the_scale :: proc(t: ^testing.T) {
	sync.mutex_lock(&lock)
	defer sync.mutex_unlock(&lock)
	f := new(Sx)
	defer free(f)
	if !testing.expect(t, render.init_offscreen(&f.r, SIZE, warp = true), "WARP") { return }
	font.init(&f.fonts)
	f.ui_font, _ = font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	draw.init(&f.dc, &f.r, &f.fonts)
	ui.apply_palette(&f.theme, ui.PALETTE_MIDNIGHT)
	ui.init(&f.s, &f.fonts, &f.theme)
	defer { ui.destroy(&f.s); ui.theme_destroy(&f.theme); draw.destroy(&f.dc); render.destroy(&f.r); font.destroy(&f.fonts) }

	// a tab's underline: the rows of a column of its left padding (no text there) that its being selected changes
	tabs :: proc(user: rawptr) {
		r := (^Tab_Run)(user)
		ui.next({width = ui.fill(), height = ui.px(ui.scale() * 40), axis = .X})
		if ui.row() { ui.tabs("###t", {"One", "Two"}, nil, &r.sel) }
	}
	underline :: proc(f: ^Sx, dpi: f32) -> int {
		on, off := Tab_Run{0}, Tab_Run{1}
		a := picture(f, dpi, tabs, &on)
		defer delete(a)
		b := picture(f, dpi, tabs, &off)
		defer delete(b)
		n := 0
		for y in 0 ..< SIZE.y { if differs(a, b, int(4 * dpi), y) { n += 1 } }
		return n
	}
	testing.expect_value(t, underline(f, 1), 3)
	testing.expect_value(t, underline(f, 2), 6)

	// a radio's ring: the pixels of the row through its middle, from its left edge in, that differ from no radio at all
	ring :: proc(f: ^Sx, dpi: f32) -> int {
		none := picture(f, dpi, proc(user: rawptr) {}, nil)
		defer delete(none)
		mark := picture(f, dpi, proc(user: rawptr) {
			@(static) sel: int
			sel = 1
			ui.next({height = ui.px(ui.scale() * 40)})
			ui.radio("###r", "", &sel, 0)
		}, nil)
		defer delete(mark)
		y := int(20 * dpi)
		x := 0
		for x < SIZE.x && !differs(none, mark, x, y) { x += 1 }
		n := 0
		for x + n < SIZE.x && differs(none, mark, x + n, y) { n += 1 }
		return n
	}
	one, two := ring(f, 1), ring(f, 2)
	testing.expectf(t, one >= 1 && two >= one + 1, "the ring: %d pixels at 100 %%, %d at 200 %%", one, two)
}
