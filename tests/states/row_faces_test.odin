// A row's face (src/md/features/interaction-states.md, "Rows"): inset in the row and rounded as a button, its radius the
// rounding setting's (0: square, the edged finish: square, a row given radius 0: square), selected rows that touch one
// block, a zebra's stripe a ground under it, not its face.
package states_test

import "core:math"
import "core:sync"
import "core:testing"
import "gt:font"
import "gt:platform"
import "gt:ui"

@(private = "file")
row_lock: sync.Mutex

// The font size of these rows, and a row's corner of it (the theme's shape; ui.SHAPE_DEFAULT: a button's corner).
@(private = "file") EM :: f32(15)
@(private = "file") CONTROL_RADIUS :: EM * 0.45
@(private = "file") ROW_H :: f32(30)

@(test)
row_face_geometry :: proc(t: ^testing.T) {
	r := ui.Rect{{10, 100}, {310, 130}}
	f := ui.row_face_rect(r, 5, 1)
	testing.expect_value(t, f, ui.Rect{{15, 101}, {305, 129}})
	// joined to a selected row above and below: no gap there, square corners there
	j := ui.row_face_rect(r, 5, 1, {above = true, below = true})
	testing.expect_value(t, j, ui.Rect{{15, 100}, {305, 130}})
	testing.expect_value(t, ui.row_face_radii(f, 7, {above = true}), [4]f32{0, 7, 0, 7})
	testing.expect_value(t, ui.row_face_radii(f, 7, {below = true}), [4]f32{7, 0, 7, 0})
	// a pill at most: never more than half the face's height
	testing.expect_value(t, ui.row_face_radii(f, 40, {}), [4]f32{14, 14, 14, 14})
	// a row narrower than its insets: a line at its middle, never inside out
	thin := ui.row_face_rect({{0, 0}, {6, 30}}, 5, 1)
	testing.expect(t, thin.max.x >= thin.min.x && thin.min.x == 3, "a narrow row's face is not inside out")
}

@(private = "file")
Row_Run :: struct {
	fonts:  font.State,
	theme:  ui.Theme,
	s:      ui.State,
	font:   font.Font_Id,
	list:   ui.List_State,
	rows:   [6]^ui.Box,
	square: bool,   // the program asks square rows: next({radius = 0})
	zebra:  bool,
}

@(private = "file")
row_open :: proc(f: ^Row_Run, finish := ui.Finish.Machined) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	p := ui.palette_of("Graphite")
	p.finish = finish
	ui.apply_palette(&f.theme, p)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.font = id
	f.list.multi = true
	return true
}

@(private = "file")
row_close :: proc(f: ^Row_Run) {
	ui.list_state_destroy(&f.list)
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

@(private = "file")
row_frame :: proc(f: ^Row_Run, events: []platform.Event = nil) {
	ui.begin_build(&f.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = false, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(ROW_H)}, font = f.font, font_size = EM, text_pad = 6},
	})
	f.list.zebra = f.zebra
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(300), height = ui.px(400)})
	if ui.list("###rows", &f.list) {
		for i in 0 ..< len(f.rows) {
			m := ui.Style_Mod{height = ui.px(ROW_H)}
			if f.square { m.radius = 0 }
			ui.next(m)
			f.rows[i] = ui.list_row(&f.list, i, "row").box
		}
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

// Rows 1, 2 and 3 selected: one block. Row 5 alone.
@(private = "file")
row_select :: proc(f: ^Row_Run) {
	row_frame(f)
	ui.use(&f.s)
	for i in ([]int{1, 2, 3, 5}) { ui.list_set_selected(&f.list, i) }
	row_frame(f)
	row_frame(f)
	ui.use(&f.s)
}

@(test)
rows_face_is_inset_and_rounded_as_a_button :: proc(t: ^testing.T) {
	sync.mutex_lock(&row_lock)
	defer sync.mutex_unlock(&row_lock)
	f: Row_Run
	if !testing.expect(t, row_open(&f), "fonts") { return }
	defer row_close(&f)
	row_select(&f)

	b := f.rows[0]
	testing.expect(t, .Row in b.flags && .Chosen not_in b.flags, "a row, not selected")
	face, radii, _, _, _ := ui.row_face_of(&f.s, b)
	// the box runs across the list (its content where it was); the face is inset in it
	testing.expect_value(t, b.rect.max.x - b.rect.min.x, 300)
	testing.expect_value(t, face.min.x - b.rect.min.x, math.round(EM * ui.ROW_FACE_INSET_EM))
	testing.expect_value(t, b.rect.max.x - face.max.x, math.round(EM * ui.ROW_FACE_INSET_EM))
	testing.expect_value(t, face.min.y - b.rect.min.y, ui.ROW_FACE_GAP_PX)
	// rounded as a button: the same radius, through the same path
	testing.expect(t, math.abs(radii[0] - CONTROL_RADIUS) < 1e-3 && radii == radii.xxxx, "a button's corners")

	// the rounding setting scales it: 0 squares it, 2 doubles it (a pill at most)
	ui.set_rounding(&f.s, 0)
	_, radii, _, _, _ = ui.row_face_of(&f.s, b)
	testing.expect_value(t, radii, [4]f32{})
	ui.set_rounding(&f.s, 2)
	face, radii, _, _, _ = ui.row_face_of(&f.s, b)
	testing.expect(t, math.abs(radii[0] - min(2 * CONTROL_RADIUS, (face.max.y - face.min.y) * 0.5)) < 1e-3, "rounding 2: twice the corner")
	ui.set_rounding(&f.s, 1)

	// a program asks square rows as it asks a square button: radius 0
	f.square = true
	row_frame(&f)
	ui.use(&f.s)
	_, radii, _, _, _ = ui.row_face_of(&f.s, f.rows[0])
	testing.expect_value(t, radii, [4]f32{})
}

@(test)
rows_are_square_in_the_edged_finish :: proc(t: ^testing.T) {
	sync.mutex_lock(&row_lock)
	defer sync.mutex_unlock(&row_lock)
	f: Row_Run
	if !testing.expect(t, row_open(&f, .Edged), "fonts") { return }
	defer row_close(&f)
	row_select(&f)
	_, radii, _, _, _ := ui.row_face_of(&f.s, f.rows[0])
	testing.expect_value(t, radii, [4]f32{})
}

// Selected rows that touch are one block: each knows the block's rect, its own edges joined where a selected row meets it.
@(test)
selected_rows_that_touch_are_one_block :: proc(t: ^testing.T) {
	sync.mutex_lock(&row_lock)
	defer sync.mutex_unlock(&row_lock)
	f: Row_Run
	if !testing.expect(t, row_open(&f), "fonts") { return }
	defer row_close(&f)
	row_select(&f)
	for i in ([]int{1, 2, 3, 5}) { testing.expectf(t, .Chosen in f.rows[i].flags, "row %d is selected", i) }

	gap := f32(ui.ROW_FACE_GAP_PX)
	_, top_radii, run1, _, j1 := ui.row_face_of(&f.s, f.rows[1])
	_, mid_radii, run2, run_radii, j2 := ui.row_face_of(&f.s, f.rows[2])
	_, _, run3, _, j3 := ui.row_face_of(&f.s, f.rows[3])
	testing.expect_value(t, j1, ui.Row_Joins{below = true})
	testing.expect_value(t, j2, ui.Row_Joins{above = true, below = true})
	testing.expect_value(t, j3, ui.Row_Joins{above = true})
	// the same block for each of its rows: from the first one's top to the last one's bottom, rounded at its ends
	testing.expect(t, run1 == run2 && run2 == run3, "one block")
	testing.expect_value(t, run2.min.y, f.rows[1].rect.min.y + gap)
	testing.expect_value(t, run2.max.y, f.rows[3].rect.max.y - gap)
	testing.expect(t, run_radii[0] > 0 && run_radii[1] > 0, "the block is rounded at its ends")
	testing.expect(t, top_radii[0] > 0 && top_radii[1] == 0, "its first row: rounded at its top, square where it joins")
	testing.expect_value(t, mid_radii, [4]f32{})

	// a selected row alone (5, under the unselected 4) is its own face
	face5, _, run5, _, j5 := ui.row_face_of(&f.s, f.rows[5])
	testing.expect_value(t, j5, ui.Row_Joins{})
	testing.expect_value(t, run5, face5)
}

// A zebra's stripe is the row's ground: square under its face, not its face (it has none at rest).
@(test)
a_zebra_stripe_is_ground_not_face :: proc(t: ^testing.T) {
	sync.mutex_lock(&row_lock)
	defer sync.mutex_unlock(&row_lock)
	f: Row_Run
	if !testing.expect(t, row_open(&f), "fonts") { return }
	defer row_close(&f)
	f.zebra = true
	row_frame(&f)
	row_frame(&f)
	ui.use(&f.s)
	z := f.rows[1]
	testing.expect(t, .Draw_Background in z.flags && .Chosen not_in z.flags, "a stripe, not a selection")
	testing.expect_value(t, ui.row_face(&f.s, z).color.a, 0)
	// under the pointer its face appears over the stripe, opaque
	c := (z.rect.min + z.rect.max) * 0.5
	row_frame(&f, {{kind = .Mouse_Move, pos = c}})
	row_frame(&f)
	ui.use(&f.s)
	testing.expect_value(t, ui.row_face(&f.s, f.rows[1]).color.a, 1)
}
