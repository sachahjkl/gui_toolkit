// The face of a box in its states (src/md/features/interaction-states.md): hover lifts the face itself, a press sinks it
// at once, a toggled face lifts less, a face that has none at rest appears opaque in the box's shape, and a check box
// reacts on its mark's geometry, its row drawing nothing.
package states_test

import "core:math"
import "core:sync"
import "core:testing"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:ui"

@(private = "file")
face_lock: sync.Mutex

@(test)
face_steps_agree :: proc(t: ^testing.T) {
	H, P :: f32(0.07), f32(0.12)
	step :: proc(hot, pressing, toggled: f32) -> f32 { return ui.face_step({hot = hot, pressing = pressing, toggled = toggled}, H, P) }
	testing.expect_value(t, step(0, 0, 0), 0)
	testing.expect_value(t, step(1, 0, 0), H)
	testing.expect_value(t, step(1, 1, 0), P)        // a press is the press step, not the hover's added to it
	testing.expect_value(t, step(0, 0, 1), P)        // toggled: sunk at rest
	testing.expect(t, math.abs(step(1, 0, 1) - (P + H * 0.5)) < 1e-6, "toggled under the pointer: half a hover step more")
	testing.expect_value(t, step(1, 1, 1), P)
	testing.expect(t, step(0.5, 0, 0) > 0 && step(0.5, 0, 0) < H, "the hover eases")
}

// Which colour a rest, hovered and pressed face gets: always the face itself, opaque, never a veil.
@(test)
faces_are_the_box_itself :: proc(t: ^testing.T) {
	under := draw.Color{0.05, 0.05, 0.05, 1}
	white := draw.Color{1, 1, 1, 1}
	lum :: proc(c: draw.Color) -> f32 { return c.r + c.g + c.b }
	for space in draw.Blend_Space {
		// a raised face (a button): lifted toward the tint under the pointer, deeper and sunk pressed
		button := draw.Color{0.2, 0.2, 0.2, 1}
		rest := ui.face_of(button, under, white, {}, 0.07, 0.13, 0, space)
		hover := ui.face_of(button, under, white, {hot = 1}, 0.07, 0.13, 0, space)
		press := ui.face_of(button, under, white, {hot = 1, pressing = 1}, 0.07, 0.13, 0, space)
		testing.expect(t, rest.color == button && rest.sunk == 0, "at rest: its own colour")
		testing.expect(t, lum(hover.color) > lum(button) && hover.color.a == 1 && hover.sunk == 0, "hover: the face lifts, opaque")
		testing.expect(t, lum(press.color) > lum(hover.color) && press.sunk == 1, "press: a step deeper, sunk")

		// a face that has none at rest (a ghost button): it appears opaque in the box's shape, raised by its hover_sheen
		none := ui.face_of({}, under, white, {}, 0.08, 0.14, 0.6, space)
		testing.expect(t, none.color.a == 0, "a ghost at rest has no face")
		ghost := ui.face_of({}, under, white, {hot = 1}, 0.08, 0.14, 0.6, space)
		testing.expect(t, ghost.color.a == 1 && lum(ghost.color) > lum(under), "settled, the ghost's face is opaque and lifted off the surface")
		testing.expect(t, ghost.raised && ghost.sheen == 0.6, "and raised")
		row := ui.face_of({}, under, white, {hot = 1}, 0.05, 0.09, 0, space)
		testing.expect(t, !row.raised && row.color.a == 1, "a row's face is flat and opaque")
		half := ui.face_of({}, under, white, {hot = 0.5}, 0.08, 0.14, 0.6, space)
		testing.expect(t, half.color.a > 0 && half.color.a < 1, "it appears with the hover's ease")

		// a translucent face (a selected row): made opaque over what is under it, then lifted
		accent := draw.Color{0.2, 0.5, 0.9, 0.22}
		sel := ui.face_of(accent, under, white, {hot = 1}, 0.05, 0.09, 0, space)
		flat := ui.face_over(accent, under, space)
		testing.expect(t, sel.color.a == 1 && lum(sel.color) > lum(flat), "a hovered selected row is a lighter selected row")
		testing.expect(t, sel.color.b > sel.color.r, "and keeps its hue")

		// a light palette: the tint is black, the face goes darker
		paper := draw.Color{0.9, 0.9, 0.9, 1}
		dark := ui.face_of(paper, paper, {0, 0, 0, 1}, {hot = 1}, 0.07, 0.13, 0, space)
		testing.expect(t, lum(dark.color) < lum(paper), "on paper a hovered face darkens")
	}
}

// The marks of a check box: the box's own face reacts, its ring goes toward the accent, a checked box's accent face lifts.
@(test)
mark_colors_react :: proc(t: ^testing.T) {
	ring := draw.Color{1, 1, 1, 0.5}
	accent := draw.Color{0.2, 0.5, 0.9, 1}
	under := draw.Color{0.1, 0.1, 0.1, 1}
	tint := draw.Color{1, 1, 1, 1}
	rest := ui.mark_colors({}, 0, ring, accent, under, tint)
	hover := ui.mark_colors({hot = 1}, 0, ring, accent, under, tint)
	press := ui.mark_colors({hot = 1, pressing = 1}, 0, ring, accent, under, tint)
	testing.expect(t, rest.inside.a == 0, "at rest the surface shows inside the box")
	testing.expect(t, hover.inside.a == 1 && hover.inside.r > under.r, "hover: the inside lifts")
	testing.expect(t, press.inside.r > hover.inside.r, "press: deeper")
	gap :: proc(a, b: draw.Color) -> f32 { return math.abs(a.r - b.r) + math.abs(a.g - b.g) + math.abs(a.b - b.b) }
	testing.expect(t, gap(hover.ring, accent) < gap(rest.ring, accent), "the ring goes toward the accent")
	on_rest := ui.mark_colors({}, 1, ring, accent, under, tint)
	on_hover := ui.mark_colors({hot = 1}, 1, ring, accent, under, tint)
	testing.expect(t, gap(on_rest.fill, accent) < 1e-4, "checked at rest: the accent")
	testing.expect(t, on_hover.fill.r > accent.r && on_hover.fill.a == 1, "checked under the pointer: the accent face lifts")
}

Check_Run :: struct {
	list:  ui.List_State,
	row:   ^ui.Box,   // the check box's row (its target)
	value: bool,
}

// A check box with no label in a narrow cell of a list's row: the case where the row's fill was a square larger than
// the box and off its centre.
@(private = "file")
check_frame :: proc(fx: ^Fx_Faces, r: ^Check_Run, events: []platform.Event, transition_ms: f32 = 0) {
	fx.theme.transition_ms = transition_ms
	ui.begin_build(&fx.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = true, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = fx.base_font, font_size = 15, text_pad = 6},
	})
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(300), height = ui.px(150)})
	if ui.list("###list", &r.list) {
		ui.next({height = ui.px(30)})
		if ui.parent(ui.list_row(&r.list, 0, "row").box) {
			ui.next({width = ui.px(40), height = ui.pct(1)})
			ui.checkbox("###ck", "", &r.value)
			r.row = ui.prev_box("###ck")
		}
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

Fx_Faces :: struct {
	fonts:     font.State,
	theme:     ui.Theme,
	s:         ui.State,
	base_font: font.Font_Id,
}

@(test)
check_box_reacts_on_its_own_geometry :: proc(t: ^testing.T) {
	sync.mutex_lock(&face_lock)
	defer sync.mutex_unlock(&face_lock)
	fx: Fx_Faces
	font.init(&fx.fonts)
	defer font.destroy(&fx.fonts)
	id, ok := font.load_embedded(&fx.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "font") { return }
	fx.base_font = id
	ui.apply_palette(&fx.theme, ui.palette_of("Graphite"))
	defer ui.theme_destroy(&fx.theme)
	ui.init(&fx.s, &fx.fonts, &fx.theme)
	defer ui.destroy(&fx.s)
	r: Check_Run
	defer ui.list_state_destroy(&r.list)
	check_frame(&fx, &r, {move_to(700, 500)})
	check_frame(&fx, &r, nil)
	mark := ui.box_from_key(ui.key_from_string(r.row.key, "mark"))
	if !testing.expect(t, mark != nil, "the mark's box") { return }
	c := (mark.rect.min + mark.rect.max) * 0.5
	check_frame(&fx, &r, {move_to(c.x, c.y)})
	check_frame(&fx, &r, nil)
	testing.expect_value(t, r.row.hot_t, 1)

	// the row is the target and draws nothing: no fill over the row, no plate around the box
	ui.use(&fx.s)
	testing.expect(t, .Draw_Hot_Effects not_in r.row.flags && .Draw_Background not_in r.row.flags, "the row has no face of its own")
	testing.expect_value(t, ui.box_face(&fx.s, r.row).color.a, 0)
	// what reacts is the mark, and its geometry is the box's: a square, centred in the row's height
	d := (^ui.Mark_Draw)(mark.custom_user)
	testing.expect(t, d.row == r.row, "the mark reads its row's states")
	testing.expect_value(t, ui.face_state(r.row).hot, 1)
	size := mark.rect.max - mark.rect.min
	testing.expect(t, math.abs(size.x - size.y) < 0.5, "the mark is a square")
	testing.expect(t, math.abs((mark.rect.min.y + mark.rect.max.y) * 0.5 - (r.row.rect.min.y + r.row.rect.max.y) * 0.5) < 1, "centred in its row")

	// a press shows at once, even with the theme's transitions; its release eases out
	check_frame(&fx, &r, {ui_press(c.x, c.y)}, transition_ms = 120)
	testing.expect_value(t, ui.face_state(r.row).pressing, 1)
	check_frame(&fx, &r, {ui_release(c.x, c.y)}, transition_ms = 120)
	testing.expect(t, r.row.active_t > 0 && r.row.active_t < 1, "the release eases out")
	testing.expect(t, r.value, "and the click checked it")
}

Frame_Run :: struct {
	field:        ui.Line_Edit,
	frame, inner: ^ui.Box,
}

@(private = "file")
frame_build :: proc(fx: ^Fx_Faces, r: ^Frame_Run, events: []platform.Event) {
	ui.begin_build(&fx.s, {
		window_size = {800, 600}, events = events, dt = 1.0 / 60, animations = true, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = fx.base_font, font_size = 15, text_pad = 6},
	})
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(300), height = ui.px(32)})
	if ui.input_frame("###frame") {
		r.frame = ui.parent_box()
		ui.spacer(ui.px(24))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.tags("bare") {
			ui.line_edit("###field", &r.field)
			r.inner = ui.prev_box("###field")
		}
	}
	ui.end_build()
	free_all(context.temp_allocator)
}

// A field inside an input_frame: the frame is the face that reacts, on its own rect; the bare field inside draws none
// (it would be a second, smaller face inside the frame).
@(test)
input_frame_reacts_as_one_field :: proc(t: ^testing.T) {
	sync.mutex_lock(&face_lock)
	defer sync.mutex_unlock(&face_lock)
	fx: Fx_Faces
	font.init(&fx.fonts)
	defer font.destroy(&fx.fonts)
	id, ok := font.load_embedded(&fx.fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok, "font") { return }
	fx.base_font = id
	ui.apply_palette(&fx.theme, ui.palette_of("Graphite"))
	defer ui.theme_destroy(&fx.theme)
	ui.init(&fx.s, &fx.fonts, &fx.theme)
	defer ui.destroy(&fx.s)
	r: Frame_Run
	defer ui.line_edit_destroy(&r.field)
	frame_build(&fx, &r, {move_to(700, 500)})
	frame_build(&fx, &r, nil)
	rest := r.frame.bg
	c := (r.inner.rect.min + r.inner.rect.max) * 0.5
	frame_build(&fx, &r, {move_to(c.x, c.y)})
	frame_build(&fx, &r, nil)
	ui.use(&fx.s)
	testing.expect_value(t, r.frame.hot_t, 1)
	testing.expect_value(t, ui.box_face(&fx.s, r.inner).color.a, 0)
	f := ui.box_face(&fx.s, r.frame)
	testing.expect(t, f.color != rest && f.color.a == 1, "the frame's own face lifts")
}

@(private = "file")
move_to :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Move, pos = {x, y}} }
@(private = "file")
ui_press :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Press, pos = {x, y}, button = .Left} }
@(private = "file")
ui_release :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Release, pos = {x, y}, button = .Left} }
