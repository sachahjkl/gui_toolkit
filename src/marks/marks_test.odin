// The model of marks on a picture with no window: the state machine, the undo steps, the figures and the flattening.
// Ported from cliche's editor_model_test.odin, adapted to gt:marks. What breaks first: a click that leaves an undo
// step; a slider that leaves one step a frame; a pen whose ink is not made again after a move; a flattened box whose
// pixels are not the box's colour.
//   odin run tools/run_tests -- marks
package tk_marks

import "core:strings"
import "core:testing"
import ink "../ink"

// A font of fixed width: half its size a character (bold: three quarters), its size and a fifth tall.
@(private = "file")
measure_fixed :: proc(user: rawptr, text: string, size: f32, bold: bool) -> Vec {
	return {f32(len(text)) * size * (bold ? 0.75 : 0.5), size * 1.2}
}

// A model on a 1000 x 800 picture shown at 1:1 from the window's origin: window and picture pixels are the same.
@(private = "file")
model_make :: proc(m: ^Model) {
	init(m, {1000, 800}, {measure = measure_fixed})
	m.view = {canvas = {{0, 0}, {1000, 800}}, zoom = 1}
}

@(private = "file")
drag :: proc(m: ^Model, from, to: Vec, shift := false) {
	step(m, Press{at = from, button = .Left, shift = shift, time = 0})
	step(m, Move{at = (from + to) * 0.5, shift = shift, time = 16})
	step(m, Release{at = to, button = .Left, shift = shift})
}

@(private = "file")
near :: proc(a, b: Vec, eps: f32 = 0.01) -> bool { return abs(a.x - b.x) < eps && abs(a.y - b.y) < eps }

@(test)
draws_an_arrow_by_default :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	testing.expect_value(t, m.tool, Tool.Arrow)
	drag(&m, {100, 100}, {300, 200})
	testing.expect_value(t, len(m.doc.shapes), 1)
	s := m.doc.shapes[0]
	testing.expect_value(t, s.kind, Kind.Arrow)
	testing.expect_value(t, s.a, Vec{100, 100})
	testing.expect_value(t, s.b, Vec{300, 200})
	testing.expect_value(t, s.style, STYLE_DEFAULT)
	testing.expect_value(t, m.doc.selected, 0)   // (drawn: selected, its handles shown)
	testing.expect(t, idle(&m))
}

@(test)
the_options_choose_the_tool_and_styles :: proc(t: ^testing.T) {
	m: Model
	styles: [Tool]Style
	styles[.Rectangle] = Style{color = 0x1E88E5, width = 9}
	init(&m, {100, 100}, {tool = .Rectangle, styles = styles, scale = 2})
	defer destroy(&m)
	testing.expect_value(t, m.tool, Tool.Rectangle)
	testing.expect_value(t, m.styles[.Rectangle].color, u32(0x1E88E5))
	testing.expect_value(t, m.styles[.Arrow], STYLE_DEFAULT)   // (a zero style: the toolkit's)
	testing.expect_value(t, m.styles[.Highlighter].color, u32(HIGHLIGHT_COLOR))
	testing.expect_value(t, m.doc.scale, f32(2))
}

@(test)
a_click_draws_nothing :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {101, 102})
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !changed(&m))   // (no undo step for nothing)
}

@(test)
shift_constrains :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Ellipse)
	drag(&m, {100, 100}, {300, 150}, shift = true)
	testing.expect_value(t, m.doc.shapes[0].b, Vec{300, 300})   // (a circle)
	tool_set(&m, .Line)
	drag(&m, {0, 0}, {100, 10}, shift = true)
	b := m.doc.shapes[1].b
	testing.expect(t, abs(b.y) < 0.001)   // (flat: 6° snaps to 0°)
	testing.expect(t, abs(b.x - 100.4988) < 0.01)
}

@(test)
hit_tests_strokes_and_fills :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	tol := f32(HIT_PX)
	testing.expect_value(t, hit(&m.doc, {100, 200}, tol), 0)   // (on its left side)
	testing.expect_value(t, hit(&m.doc, {105, 200}, tol), 0)   // (near it)
	testing.expect_value(t, hit(&m.doc, {200, 200}, tol), -1)  // (inside an outline: not it)
	m.doc.shapes[0].style.fill_color = OPAQUE | 0x1E88E5
	testing.expect_value(t, hit(&m.doc, {200, 200}, tol), 0)
	// (the topmost first)
	tool_set(&m, .Line)
	drag(&m, {50, 200}, {350, 200})
	testing.expect_value(t, hit(&m.doc, {200, 202}, tol), 1)
	testing.expect_value(t, hit(&m.doc, {200, 260}, tol), 0)
	testing.expect_value(t, hit(&m.doc, {600, 600}, tol), -1)
}

@(test)
select_moves_and_resizes :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {200, 200})
	tool_set(&m, .Select)
	testing.expect_value(t, m.doc.selected, 0)   // (Select keeps the selection)
	drag(&m, {100, 130}, {150, 150})   // (on its left side, away from its handles: moved)
	s := m.doc.shapes[0]
	testing.expect_value(t, box_of(s.a, s.b), Box{{150, 120}, {250, 220}})
	drag(&m, {250, 220}, {300, 300})   // (its bottom right handle)
	s = m.doc.shapes[0]
	testing.expect_value(t, box_of(s.a, s.b), Box{{150, 120}, {300, 300}})
	step(&m, Press{at = {600, 600}, button = .Left})   // (nothing there: no selection)
	step(&m, Release{at = {600, 600}, button = .Left})
	testing.expect_value(t, m.doc.selected, -1)
	testing.expect_value(t, len(m.doc.history.undo), 3)   // (drawn, moved, resized)
}

@(test)
undo_and_redo :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	drag(&m, {10, 200}, {100, 300})
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect(t, delete_selection(&m))
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect(t, undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect(t, undo(&m))
	testing.expect(t, undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !undo(&m))
	testing.expect(t, redo(&m))
	testing.expect(t, redo(&m))
	testing.expect_value(t, len(m.doc.shapes), 2)
	testing.expect_value(t, m.doc.shapes[1].a, Vec{10, 200})
	// (a new change drops what could be redone)
	drag(&m, {500, 500}, {600, 600})
	testing.expect(t, !redo(&m))
}

@(test)
crop_is_clamped_and_undone :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Crop)
	drag(&m, {900, 700}, {1200, 1000})
	testing.expect(t, m.doc.has_crop)
	x, y, w, h := output_box(&m.doc)
	testing.expect_value(t, [4]int{x, y, w, h}, [4]int{900, 700, 100, 100})
	testing.expect(t, undo(&m))
	testing.expect(t, !m.doc.has_crop)
	x, y, w, h = output_box(&m.doc)
	testing.expect_value(t, [4]int{x, y, w, h}, [4]int{0, 0, 1000, 800})
}

@(test)
text_is_typed_and_given_up :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Text)
	step(&m, Press{at = {100, 100}, button = .Left})
	_, typing := m.mode.(Typing)
	testing.expect(t, typing)
	step(&m, Typed{text = "abcd"})
	step(&m, Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect_value(t, m.doc.shapes[0].text, "abcd")
	b := m.doc.shapes[0].b   // (4 characters of 12 at 24 px)
	testing.expect(t, near(b, {148, 128.8}))
	testing.expect_value(t, len(m.doc.history.undo), 1)
	// (Escape gives back the text as it was; an empty new text is no text)
	step(&m, Press{at = {110, 110}, button = .Left})
	step(&m, Typed{text = "changed"})
	step(&m, Type_End{keep = false})
	testing.expect_value(t, m.doc.shapes[0].text, "abcd")
	testing.expect_value(t, len(m.doc.history.undo), 1)
	step(&m, Press{at = {500, 500}, button = .Left})
	step(&m, Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect_value(t, len(m.doc.history.undo), 1)
}

@(test)
property_changes_the_selection :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	colors := COLORS
	drag(&m, {10, 10}, {100, 100})
	style, props := style_shown(&m)
	testing.expect(t, .Width in props && .Fill not_in props)
	style.color = colors[4]
	testing.expect(t, style_set(&m, style))
	testing.expect_value(t, m.doc.shapes[0].style.color, colors[4])
	testing.expect_value(t, m.styles[.Arrow].color, colors[4])   // (the next arrow too)
	testing.expect(t, undo(&m))
	testing.expect(t, undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
}

// A slider runs through many widths: one undo step for them all, then a colour is a step of its own.
@(test)
widths_in_a_row_are_one_step :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	colors := COLORS
	drag(&m, {10, 10}, {100, 100})
	style, _ := style_shown(&m)
	for w in ([]f32{5, 9, 14, 17}) {
		style.width = w
		testing.expect(t, style_set(&m, style))
	}
	testing.expect_value(t, len(m.doc.history.undo), 2)   // the arrow drawn, then its widths
	style.color = colors[4]
	testing.expect(t, style_set(&m, style))
	style.width = 3
	testing.expect(t, style_set(&m, style))
	testing.expect_value(t, len(m.doc.history.undo), 4)   // (a width after a colour: a step again)
	testing.expect(t, undo(&m))
	testing.expect(t, undo(&m))
	testing.expect_value(t, m.doc.shapes[0].style.width, 17)
	testing.expect(t, undo(&m))
	testing.expect_value(t, m.doc.shapes[0].style.width, STYLE_DEFAULT.width)
}

@(test)
zoom_keeps_the_point_under_the_pointer :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	at := Vec{400, 300}
	before := to_picture(m.view, at)
	step(&m, Wheel{at = at, delta = {0, -2}, zoom = true})
	testing.expect(t, m.view.zoom > 1.5)
	after := to_picture(m.view, at)
	testing.expect(t, near(after, before))
	view_fit(&m)
	testing.expect(t, m.view.fit && abs(m.view.zoom - FIT_MARGIN) < 0.0001)
	view_zoom_to(&m, 2)
	testing.expect(t, abs(m.view.zoom - 2) < 0.0001 && !m.view.fit)
}

@(test)
pans_with_the_middle_button :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	step(&m, Press{at = {100, 100}, button = .Middle})
	step(&m, Move{at = {150, 120}})
	step(&m, Release{at = {160, 130}, button = .Middle})
	testing.expect_value(t, m.view.offset, Vec{60, 30})
	testing.expect(t, !m.view.fit && idle(&m))
	testing.expect(t, !changed(&m))
}

// A fill colour of its own, with "none": a filled box is taken inside, an outline only on its edge.
@(test)
fill_colour_is_its_own :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	_, filled := fill_of(m.doc.shapes[0].style)
	testing.expect(t, !filled)
	style, props := style_shown(&m)
	testing.expect(t, .Fill in props)
	style.fill_color = OPAQUE | 0xFDD835
	testing.expect(t, style_set(&m, style))
	rgb, has := fill_of(m.doc.shapes[0].style)
	testing.expect(t, has && rgb == 0xFDD835)
	testing.expect_value(t, m.doc.shapes[0].style.color, STYLE_DEFAULT.color)   // (the stroke keeps its colour)
	testing.expect_value(t, hit(&m.doc, {200, 200}, HIT_PX), 0)
	// (the picker's drag through fill colours: one undo step; alpha 0 is no fill)
	for c in ([]u32{0x80FDD835, 0x40FDD835, 0x00FDD835}) {
		style.fill_color = c
		testing.expect(t, style_set(&m, style))
	}
	testing.expect_value(t, len(m.doc.history.undo), 2)   // the box drawn, then its fill
	testing.expect_value(t, hit(&m.doc, {200, 200}, HIT_PX), -1)
	testing.expect(t, undo(&m))
	_, filled = fill_of(m.doc.shapes[0].style)
	testing.expect(t, !filled)
}

// Shift+Enter's lines: as wide as the longest, as tall as all of them, an empty last one too; bold and a box measure again.
@(test)
text_has_lines_and_looks :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Text)
	step(&m, Press{at = {100, 100}, button = .Left})
	step(&m, Typed{text = "ab\nlonger\n"})
	step(&m, Type_End{keep = true})
	s := &m.doc.shapes[0]
	testing.expect_value(t, s.text, "ab\nlonger\n")
	// (6 characters of 12 at 24 px; 3 lines of 28.8)
	testing.expect(t, near(s.b, {172, 100 + 3 * 28.8}))
	style, props := style_shown(&m)
	testing.expect(t, .Bold in props && .Text_Look in props && .Fill in props)
	style.bold = true
	testing.expect(t, style_set(&m, style))
	testing.expect(t, abs(m.doc.shapes[0].b.x - 208) < 0.01)   // (bold: 18 a character)
	style.text_look = .Background
	testing.expect(t, style_set(&m, style))
	r := shape_box(&m.doc, &m.doc.shapes[0])
	testing.expect(t, abs(r.min.x - (100 - 24 * TEXT_BOX_PAD)) < 0.01)   // (the box reaches past the letters)
	testing.expect_value(t, len(m.doc.history.undo), 3)
	// (a text of blanks only is no text)
	step(&m, Press{at = {600, 600}, button = .Left})
	step(&m, Typed{text = " \n "})
	step(&m, Type_End{keep = true})
	testing.expect_value(t, len(m.doc.shapes), 1)
}

@(test)
scale_handle_scales :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Select)
	add(&m, {kind = .Text, a = {100, 100}, text = strings.clone("abcd"), style = STYLE_DEFAULT})
	at, has := handles(&m.doc, &m.doc.shapes[0])
	testing.expect(t, has == {.Scale})
	testing.expect(t, near(at[.Scale], {148, 128.8}))
	drag(&m, at[.Scale], at[.Scale] + {48, 28.8})   // (twice as far from its top left)
	s := m.doc.shapes[0]
	testing.expect(t, abs(s.style.text_size - 48) < 0.01)
	testing.expect_value(t, s.a, Vec{100, 100})
	testing.expect(t, abs(s.b.x - 196) < 0.01)   // (measured again)

	pen := Shape{kind = .Pen, style = STYLE_DEFAULT}
	append(&pen.samples, ink.Sample{at = {0, 0}}, ink.Sample{at = {50, 0}}, ink.Sample{at = {100, 50}})
	add(&m, pen)
	at, _ = handles(&m.doc, &m.doc.shapes[1])
	testing.expect_value(t, at[.Scale], Vec{100, 50})
	drag(&m, at[.Scale], {200, 100})
	p := m.doc.shapes[1].samples
	testing.expect_value(t, p[1].at, Vec{100, 0})
	testing.expect_value(t, p[2].at, Vec{200, 100})
	testing.expect_value(t, len(m.doc.history.undo), 4)   // (two added, two scaled)
	testing.expect(t, undo(&m))
	testing.expect_value(t, m.doc.shapes[1].samples[2].at, Vec{100, 50})
}

// A right press on a shape selects it (the widget opens its menu), with no undo step; elsewhere it means nothing.
@(test)
right_press_selects :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	deselect(&m)
	testing.expect(t, step(&m, Press{at = {100, 200}, button = .Right}))
	testing.expect_value(t, m.doc.selected, 0)
	testing.expect(t, idle(&m))
	testing.expect_value(t, len(m.doc.history.undo), 1)
	testing.expect(t, !step(&m, Press{at = {700, 700}, button = .Right}))
	testing.expect_value(t, m.doc.selected, 0)
}

@(test)
order_and_delete_all :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	drag(&m, {10, 10}, {100, 100})
	drag(&m, {10, 200}, {100, 300})
	drag(&m, {10, 400}, {100, 500})
	select(&m, 0)
	testing.expect(t, !can_order(&m, .Back) && !can_order(&m, .Backward))
	testing.expect(t, order(&m, .Front))
	testing.expect_value(t, m.doc.selected, 2)
	testing.expect_value(t, m.doc.shapes[2].a, Vec{10, 10})
	testing.expect(t, !order(&m, .Forward))
	testing.expect(t, order(&m, .Backward))
	testing.expect_value(t, m.doc.selected, 1)
	testing.expect_value(t, m.doc.shapes[1].a, Vec{10, 10})
	testing.expect(t, order(&m, .Back))
	testing.expect_value(t, m.doc.shapes[0].a, Vec{10, 10})
	testing.expect(t, undo(&m))
	testing.expect_value(t, m.doc.shapes[1].a, Vec{10, 10})
	testing.expect(t, delete_all(&m))
	testing.expect_value(t, len(m.doc.shapes), 0)
	testing.expect(t, !delete_all(&m))
	testing.expect(t, undo(&m))   // (one step brings them all back)
	testing.expect_value(t, len(m.doc.shapes), 3)
}

@(test)
blur_and_pixelate_draw_boxes :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Blur)
	drag(&m, {100, 100}, {101, 101})   // (a click: nothing)
	testing.expect_value(t, len(m.doc.shapes), 0)
	drag(&m, {100, 100}, {300, 200})
	s := m.doc.shapes[0]
	testing.expect_value(t, s.kind, Kind.Blur)
	testing.expect_value(t, blur_px(&m.doc, s.style), 8)
	_, props := style_shown(&m)
	testing.expect(t, props == {.Blur_Radius})
	tool_set(&m, .Pixelate)
	_, props = style_shown(&m)
	testing.expect(t, props == {.Pixel_Size})
	testing.expect_value(t, pixel_cell(&m.doc, m.styles[.Pixelate]), 12)
}

@(test)
corners_dashes_and_heads :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Rectangle)
	drag(&m, {100, 100}, {300, 300})
	style, props := style_shown(&m)
	testing.expect(t, .Radius in props && .Dash in props && .Heads not_in props)
	for r in ([]f32{2, 6, 11}) {
		style.radius = r
		testing.expect(t, style_set(&m, style))
	}
	testing.expect_value(t, len(m.doc.history.undo), 2)   // the box, then its corners
	style.dash = .Dotted
	testing.expect(t, style_set(&m, style))
	testing.expect_value(t, m.doc.shapes[0].style.dash, Dash.Dotted)
	testing.expect_value(t, m.styles[.Rectangle].radius, f32(11))   // (the next box too)
	tool_set(&m, .Arrow)
	_, props = style_shown(&m)
	testing.expect(t, .Heads in props && .Dash in props)
}

@(test)
multi_select :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	colors := COLORS
	add(&m, {kind = .Rectangle, a = {10, 10}, b = {100, 100}, style = STYLE_DEFAULT})
	add(&m, {kind = .Rectangle, a = {200, 10}, b = {300, 100}, style = STYLE_DEFAULT})
	add(&m, {kind = .Arrow, a = {10, 300}, b = {100, 400}, style = STYLE_DEFAULT})
	tool_set(&m, .Select)
	drag(&m, {0, 0}, {350, 150})
	testing.expect_value(t, selection_count(&m), 2)
	testing.expect(t, m.doc.shapes[0].picked && m.doc.shapes[1].picked && !m.doc.shapes[2].picked)
	testing.expect_value(t, handle_hit(&m.doc, {300, 100}, 7), Handle.None)   // (no handles for two)
	drag(&m, {55, 350}, {55, 350}, shift = true)
	testing.expect_value(t, selection_count(&m), 3)
	// (what an arrow and a box share: no fill, no corners)
	_, props := style_shown(&m)
	testing.expect(t, .Color in props && .Width in props && .Fill not_in props && .Radius not_in props)
	drag(&m, {55, 350}, {55, 350}, shift = true)
	testing.expect_value(t, selection_count(&m), 2)
	testing.expect_value(t, len(m.doc.history.undo), 3)   // (picking is no change)
	drag(&m, {10, 50}, {30, 60})
	testing.expect_value(t, m.doc.shapes[0].a, Vec{30, 20})
	testing.expect_value(t, m.doc.shapes[1].a, Vec{220, 20})
	testing.expect_value(t, m.doc.shapes[2].a, Vec{10, 300})
	style, _ := style_shown(&m)
	style.color = colors[4]
	testing.expect(t, style_set(&m, style))
	testing.expect(t, m.doc.shapes[0].style.color == colors[4] && m.doc.shapes[1].style.color == colors[4])
	testing.expect_value(t, m.doc.shapes[2].style.color, STYLE_DEFAULT.color)
	testing.expect(t, order(&m, .Front))
	testing.expect_value(t, m.doc.shapes[0].kind, Kind.Arrow)   // (the two above it, in their order)
	testing.expect_value(t, m.doc.shapes[1].a, Vec{30, 20})
	testing.expect(t, !can_order(&m, .Forward))
	testing.expect(t, delete_selection(&m))
	testing.expect_value(t, len(m.doc.shapes), 1)
	testing.expect(t, undo(&m))
	testing.expect_value(t, len(m.doc.shapes), 3)
	testing.expect(t, select_all(&m))
	testing.expect_value(t, selection_count(&m), 3)
	testing.expect(t, duplicate(&m))
	testing.expect_value(t, len(m.doc.shapes), 6)
	testing.expect(t, !m.doc.shapes[0].picked && m.doc.shapes[5].picked)
	testing.expect(t, nudge(&m, {1, 0}))
	testing.expect_value(t, m.doc.shapes[5].a.x, m.doc.shapes[2].a.x + DUPLICATE_PX + 1)
}

@(test)
crop_handles_adjust_it :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Crop)
	drag(&m, {100, 100}, {300, 300})
	_, has := crop_handles(&m.doc)
	testing.expect(t, has == BOX_HANDLES)
	drag(&m, {300, 300}, {400, 2000})
	testing.expect_value(t, m.doc.crop, Box{{100, 100}, {400, 800}})
	drag(&m, {100, 450}, {150, 450})   // (its left side's handle, half way down)
	testing.expect_value(t, m.doc.crop.min, Vec{150, 100})
	testing.expect_value(t, len(m.doc.history.undo), 3)
	testing.expect(t, !crop_set(&m, {{0, 0}, {1000, 800}}))
	testing.expect(t, crop_set(&m, {{10, 20}, {500, 600}}))
	testing.expect(t, !crop_set(&m, {{10, 20}, {500, 600}}))
	testing.expect(t, undo(&m))
	testing.expect_value(t, m.doc.crop.min, Vec{150, 100})
	testing.expect(t, crop_clear(&m))
	testing.expect(t, !m.doc.has_crop)
}

// The pen keeps its samples (time, pressure) and its ink from gt:ink; a move shifts the ink, an undo brings it back.
@(test)
the_pen_lays_ink :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	tool_set(&m, .Pen)
	step(&m, Press{at = {100, 100}, button = .Left, time = 0, pressure = 0.5})
	for i in 1 ..= 10 { step(&m, Move{at = {100 + f32(i) * 20, 100 + f32(i) * 5}, time = f64(i) * 16, pressure = 0.5}) }
	step(&m, Release{at = {300, 150}, button = .Left})
	testing.expect_value(t, len(m.doc.shapes), 1)
	s := &m.doc.shapes[0]
	testing.expect_value(t, s.kind, Kind.Pen)
	testing.expect_value(t, len(s.samples), 11)
	testing.expect_value(t, s.samples[3].pressure, f32(0.5))
	testing.expect(t, len(s.polygon) >= 3 && len(s.triangles) > 0)
	testing.expect_value(t, box_of(s.a, s.b), Box{{100, 100}, {300, 150}})
	first := s.polygon[0]
	tool_set(&m, .Select)
	drag(&m, {200, 125}, {210, 135})
	s = &m.doc.shapes[0]
	testing.expect(t, near(s.polygon[0], first + {10, 10}))
	testing.expect(t, undo(&m))
	testing.expect(t, near(m.doc.shapes[0].polygon[0], first))
	// (a wider pen lays wider ink)
	select(&m, 0)
	style, _ := style_shown(&m)
	before := shape_box(&m.doc, &m.doc.shapes[0])
	style.width = 20
	testing.expect(t, style_set(&m, style))
	lo := m.doc.shapes[0].polygon[0]
	for p in m.doc.shapes[0].polygon { lo = {min(lo.x, p.x), min(lo.y, p.y)} }
	testing.expect(t, lo.y < before.min.y - 5)
	// (a press with no move is a dot of ink, kept)
	tool_set(&m, .Pen)
	step(&m, Press{at = {500, 500}, button = .Left})
	step(&m, Release{at = {500, 500}, button = .Left})
	testing.expect_value(t, len(m.doc.shapes), 2)
}

// The figures: a box's outline closed, its fill under it; an arrow's head as a polygon; dots as discs.
@(test)
figures_of_the_shapes :: proc(t: ^testing.T) {
	m: Model
	model_make(&m)
	defer destroy(&m)
	figs := make([dynamic]Figure, context.temp_allocator)
	s := Shape{kind = .Rectangle, a = {10, 10}, b = {110, 60}, style = STYLE_DEFAULT}
	s.style.fill_color = OPAQUE | 0x00FF00
	figures(&m.doc, &s, &figs, context.temp_allocator)
	testing.expect_value(t, len(figs), 2)
	testing.expect(t, figs[0].kind == .Fill && figs[1].kind == .Stroke && figs[1].closed)
	testing.expect_value(t, figs[0].color, [4]f32{0, 1, 0, 1})
	clear(&figs)
	a := Shape{kind = .Arrow, a = {0, 0}, b = {200, 0}, style = STYLE_DEFAULT}
	figures(&m.doc, &a, &figs, context.temp_allocator)
	testing.expect_value(t, len(figs), 2)
	testing.expect(t, figs[1].kind == .Fill && len(figs[1].points) == 3)
	testing.expect_value(t, figs[1].points[0], [2]f32{200, 0})   // (the head's tip at the end)
	testing.expect(t, figs[0].points[1].x < 200)   // (the shaft ends inside the head)
	clear(&figs)
	l := Shape{kind = .Line, a = {0, 0}, b = {100, 0}, style = STYLE_DEFAULT}
	l.style.dash = .Dotted
	figures(&m.doc, &l, &figs, context.temp_allocator)
	testing.expect(t, len(figs) >= 10)   // (a dot every 8 pixels)
	for f in figs { testing.expect(t, f.kind == .Fill) }
	clear(&figs)
	l.style.dash = .Dashed
	figures(&m.doc, &l, &figs, context.temp_allocator)
	testing.expect_value(t, figs[0].kind, Figure_Kind.Stroke)
	testing.expect_value(t, figs[0].points[1], [2]f32{8, 0})
}

@(test)
mosaic_averages_its_cells :: proc(t: ^testing.T) {
	// (3 x 2 pixels, cells of 2: a full cell on the left, a half one on the right)
	rgba := []u8{
		0, 0, 0, 255,    100, 0, 0, 255,   7, 8, 9, 255,
		200, 0, 0, 255,  100, 40, 0, 255,  9, 8, 7, 255,
	}
	mos := mosaic_make(rgba, {3, 2}, 2)
	defer mosaic_destroy(&mos)
	testing.expect_value(t, [2]int{mos.cols, mos.rows}, [2]int{2, 1})
	testing.expect_value(t, mos.colors[0], [4]u8{100, 10, 0, 255})
	testing.expect_value(t, mos.colors[1], [4]u8{8, 8, 8, 255})
}

// The blurred copy: a quarter of its radius a pixel, and soft (black meets white in greys).
@(test)
blur_copy_is_small_and_soft :: proc(t: ^testing.T) {
	rgba := make([]u8, 32 * 2 * 4)
	defer delete(rgba)
	for y in 0 ..< 2 {
		for x in 0 ..< 32 {
			v := u8(x < 16 ? 0 : 255)
			copy(rgba[(y * 32 + x) * 4:], []u8{v, v, v, 255})
		}
	}
	b := blur_make(rgba, {32, 2}, 8)
	defer blur_destroy(&b)
	testing.expect_value(t, b.cell, 2)
	testing.expect_value(t, b.size, [2]int{16, 1})
	testing.expect(t, b.pixels[0] < b.pixels[15 * 4])
	middle := b.pixels[8 * 4]
	testing.expect(t, middle > 20 && middle < 235)
}

////////////////////////////////
// The flattening

@(private = "file")
picture_make :: proc(w, h: int, rgb: [3]u8) -> []u8 {
	out := make([]u8, w * h * 4)
	for i in 0 ..< w * h { out[i * 4], out[i * 4 + 1], out[i * 4 + 2], out[i * 4 + 3] = rgb[0], rgb[1], rgb[2], 255 }
	return out
}

@(private = "file")
pixel :: proc(rgba: []u8, w, x, y: int) -> [4]u8 {
	i := (y * w + x) * 4
	return {rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]}
}

// A filled box: its inside is its fill colour, its edge its stroke's colour, the rest the picture.
@(test)
flatten_paints_a_filled_box :: proc(t: ^testing.T) {
	m: Model
	init(&m, {200, 100})
	defer destroy(&m)
	m.view = {canvas = {{0, 0}, {200, 100}}, zoom = 1}
	tool_set(&m, .Rectangle)
	style := m.styles[.Rectangle]
	style.fill_color = OPAQUE | 0x1E88E5
	style.color = 0xE53935
	style_set(&m, style)
	drag(&m, {20, 20}, {120, 80})
	pic := picture_make(200, 100, {255, 255, 255})
	defer delete(pic)
	in_ := flatten_input_make(&m, pic, {200, 100})
	defer flatten_input_destroy(&in_)
	out, size := flatten(&in_)
	defer delete(out)
	testing.expect_value(t, size, [2]int{200, 100})
	testing.expect_value(t, pixel(out, 200, 70, 50), [4]u8{0x1E, 0x88, 0xE5, 255})   // (inside)
	testing.expect_value(t, pixel(out, 200, 20, 50), [4]u8{0xE5, 0x39, 0x35, 255})   // (on its left edge)
	testing.expect_value(t, pixel(out, 200, 160, 50), [4]u8{255, 255, 255, 255})     // (outside)
	testing.expect_value(t, pixel(pic, 200, 70, 50), [4]u8{255, 255, 255, 255})      // (the picture is not changed)
}

@(test)
flatten_crops_and_hides :: proc(t: ^testing.T) {
	m: Model
	init(&m, {64, 32})
	defer destroy(&m)
	m.view = {canvas = {{0, 0}, {64, 32}}, zoom = 1}
	pic := make([]u8, 64 * 32 * 4)
	defer delete(pic)
	// (a checkerboard of black and white pixels: its mosaic and its blur are grey)
	for y in 0 ..< 32 {
		for x in 0 ..< 64 {
			v := u8((x + y) % 2 == 0 ? 0 : 255)
			copy(pic[(y * 64 + x) * 4:], []u8{v, v, v, 255})
		}
	}
	tool_set(&m, .Pixelate)
	drag(&m, {0, 0}, {24, 24})
	tool_set(&m, .Blur)
	drag(&m, {32, 0}, {64, 32})
	tool_set(&m, .Crop)
	drag(&m, {8, 8}, {56, 24})
	in_ := flatten_input_make(&m, pic, {64, 32})
	defer flatten_input_destroy(&in_)
	out, size := flatten(&in_)
	defer delete(out)
	testing.expect_value(t, size, [2]int{48, 16})
	p := pixel(out, 48, 4, 4)   // (picture pixel 12, 12: in a cell of the mosaic)
	testing.expect(t, p[0] > 100 && p[0] < 155)
	q := pixel(out, 48, 40, 8)   // (picture pixel 48, 16: blurred)
	testing.expect(t, q[0] > 80 && q[0] < 175)
	r := pixel(out, 48, 20, 15)   // (picture pixel 28, 23: neither, the checkerboard as it was)
	testing.expect(t, r[0] == 0 || r[0] == 255)
}
