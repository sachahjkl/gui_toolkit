// Rows of controls without a window: a check box, a radio or a switch given no width is as wide as its mark and its
// label, and a click on its label toggles it; a `next` cross alignment holds through `row` / `column`.
//   odin test tests/states -vet -define:ODIN_TEST_THREADS=1
package states_test

import "core:sync"
import "core:testing"
import "../../font"
import "../../platform"
import "../../ui"

@(private = "file")
rows_lock: sync.Mutex

@(private = "file")
Rows :: struct {
	fonts:  font.State,
	theme:  ui.Theme,
	s:      ui.State,
	font:   font.Font_Id,
	on:     bool,
	sw:     bool,
	check:  ^ui.Box,
	label:  ^ui.Box,
	toggle: ^ui.Box,
	sized:  ^ui.Box,
	row:    ^ui.Box,
	child:  ^ui.Box,
	col:    ^ui.Box,
	cchild: ^ui.Box,
}

@(private = "file")
rows_open :: proc(f: ^Rows) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, ui.PALETTE_GRAPHITE)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.font = id
	return true
}

@(private = "file")
rows_close :: proc(f: ^Rows) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
rows_frame :: proc(f: ^Rows, events: []platform.Event) {
	ui.begin_build(&f.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.font, font_size = 15, text_pad = 6},
	})
	// in the flow of a row, as a form or a settings page puts them
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(600), height = ui.px(80)})
	if ui.column(id = "###form") {
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.row(id = "###r1") { f.check = ui.checkbox("###chk", "Remember me", &f.on).box }
		ui.next({width = ui.fill(), height = ui.px(40)})
		if ui.row(id = "###r2") { f.toggle = ui.toggle("###sw", "Dark", &f.sw).box }
	}
	f.label = f.check.last
	ui.next({fixed_x = 20, fixed_y = 100, width = ui.px(400), height = ui.px(30)})
	f.sized = ui.checkbox("###sized", "Sized", &f.on).box
	// a centred row and a centred column, asked for through `next`
	ui.next({fixed_x = 20, fixed_y = 200, width = ui.px(300), height = ui.px(100), cross = .Center})
	if ui.row(id = "###row") {
		f.row = ui.parent_box()
		ui.next({width = ui.px(40), height = ui.px(20)})
		f.child = ui.build_box({}, "###c")
	}
	ui.next({fixed_x = 400, fixed_y = 200, width = ui.px(300), height = ui.px(100), cross = .Center})
	if ui.column(id = "###col") {
		f.col = ui.parent_box()
		ui.next({width = ui.px(40), height = ui.px(20)})
		f.cchild = ui.build_box({}, "###cc")
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

@(test)
check_rows_fit_their_mark_and_label :: proc(t: ^testing.T) {
	sync.mutex_lock(&rows_lock)
	defer sync.mutex_unlock(&rows_lock)
	f: Rows
	if !testing.expect(t, rows_open(&f), "fonts") { return }
	defer rows_close(&f)
	rows_frame(&f, nil)
	rows_frame(&f, nil)

	// the row spans its mark and its label (it was the text size of an empty text: a few pixels)
	w := f.check.rect.max.x - f.check.rect.min.x
	testing.expectf(t, w > 100, "check box row width %v", w)
	testing.expect(t, f.label.rect.max.x <= f.check.rect.max.x + 0.5, "the label is inside the row")
	testing.expect(t, f.label.rect.max.x - f.label.rect.min.x > 50, "the label has its text's width")
	tw := f.toggle.rect.max.x - f.toggle.rect.min.x
	testing.expectf(t, tw > 60, "switch row width %v", tw)
	// a width given by `next` is kept
	testing.expect_value(t, f.sized.rect.max.x - f.sized.rect.min.x, 400)

	// a click on the label toggles it
	c := (f.label.rect.min + f.label.rect.max) * 0.5
	rows_frame(&f, {{kind = .Mouse_Move, pos = c}})
	rows_frame(&f, {{kind = .Mouse_Press, pos = c, button = .Left}})
	rows_frame(&f, {{kind = .Mouse_Release, pos = c, button = .Left}})
	testing.expect(t, f.on, "a click on the label ticks the box")
}

@(test)
next_cross_holds_through_row_and_column :: proc(t: ^testing.T) {
	sync.mutex_lock(&rows_lock)
	defer sync.mutex_unlock(&rows_lock)
	f: Rows
	if !testing.expect(t, rows_open(&f), "fonts") { return }
	defer rows_close(&f)
	rows_frame(&f, nil)
	rows_frame(&f, nil)
	// row: centred vertically (100 high, child 20: 40 from the top)
	testing.expect_value(t, f.child.rect.min.y - f.row.rect.min.y, 40)
	// column: centred horizontally (300 wide, child 40: 130 from the left)
	testing.expect_value(t, f.cchild.rect.min.x - f.col.rect.min.x, 130)
}
