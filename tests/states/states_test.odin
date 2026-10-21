// Interaction states without a window: hover, press, focus and selection show in the frame that sees them (no fade),
// the theme's state fills are visible steps of the right size in both blend spaces, a palette change still cross-fades,
// and a theme that asks for transitions gets them.
//   odin test tests/states -vet -define:ODIN_TEST_THREADS=1
package states_test

import "core:math"
import "core:sync"
import "core:testing"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

WINDOW :: ui.Vec2{800, 600}

Fx :: struct {
	fonts: font.State,
	theme: ui.Theme,
	s:     ui.State,
	base_font: font.Font_Id,
}

@(private = "file")
ui_state_lock: sync.Mutex

@(private = "file")
open :: proc(f: ^Fx, p := ui.PALETTE_GRAPHITE) -> bool {
	font.init(&f.fonts)
	id, ok := font.load_embedded(&f.fonts, font.FALLBACK_UI_DATA)
	if !ok { return false }
	icons, iok := font.load_embedded(&f.fonts, ui.ICON_FONT_DATA)
	if !iok { return false }
	ui.apply_palette(&f.theme, p)
	ui.init(&f.s, &f.fonts, &f.theme)
	f.s.icon_font = icons
	f.base_font = id
	return true
}

@(private = "file")
close :: proc(f: ^Fx) {
	ui.destroy(&f.s)
	ui.theme_destroy(&f.theme)
	font.destroy(&f.fonts)
}

Run :: struct {
	btn, row, other: ^ui.Box,
	list:            ui.List_State,
}

// A button at (20, 20) 120 x 30, a list of three rows below it.
@(private = "file")
body :: proc(r: ^Run) {
	ui.next({fixed_x = 20, fixed_y = 20, width = ui.px(120), height = ui.px(30)})
	r.btn = ui.button("Press me###btn").box
	ui.next({fixed_x = 20, fixed_y = 80, width = ui.px(300), height = ui.px(150)})
	if ui.list("###list", &r.list) {
		for i in 0 ..< 3 {
			ui.next({height = ui.px(30)})
			sig := ui.list_row(&r.list, i, "row")
			if i == 1 { r.row = sig.box }
		}
	}
	ui.next({fixed_x = 400, fixed_y = 20, width = ui.px(120), height = ui.px(30)})
	r.other = ui.button("Other###other").box
}

@(private = "file")
frame :: proc(f: ^Fx, r: ^Run, events: []platform.Event, animations := true) {
	ui.begin_build(&f.s, {
		window_size = WINDOW, events = events, dt = 1.0 / 60, animations = animations, dpi_scale = 1,
		base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = f.base_font, font_size = 15, text_pad = 6},
	})
	body(r)
	ui.end_build()
	free_all(context.temp_allocator)
}

@(private = "file")
move :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Move, pos = {x, y}} }
@(private = "file")
press :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Press, pos = {x, y}, button = .Left} }
@(private = "file")
release :: proc(x, y: f32) -> platform.Event { return {kind = .Mouse_Release, pos = {x, y}, button = .Left} }

@(test)
hover_and_press_are_instant :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Run
	defer ui.list_state_destroy(&r.list)
	frame(&f, &r, {move(700, 500)})
	frame(&f, &r, nil)
	testing.expect_value(t, r.btn.hot_t, 0)

	// the pointer enters the button: hot in that very frame, nothing left to animate (no frame asked for)
	frame(&f, &r, {move(60, 35)})
	testing.expect_value(t, r.btn.hot_t, 1)
	testing.expect(t, !ui.needs_frame(&f.s), "a hover change asks for no further frame")
	// it leaves for the other button: the first is cold and the second hot, in one frame
	frame(&f, &r, {move(450, 35)})
	testing.expect_value(t, r.btn.hot_t, 0)
	testing.expect_value(t, r.other.hot_t, 1)
	testing.expect(t, !ui.needs_frame(&f.s), "no fade out")

	// press and release: active at once, no squish by default
	frame(&f, &r, {move(60, 35), press(60, 35)})
	testing.expect_value(t, r.btn.active_t, 1)
	testing.expect_value(t, r.btn.squish, 0)
	testing.expect(t, !ui.needs_frame(&f.s), "a press asks for no further frame")
	frame(&f, &r, {release(60, 35)})
	testing.expect_value(t, r.btn.active_t, 0)

	// the theme's press_squish: at once too
	f.theme.press_squish = 0.04
	frame(&f, &r, {press(60, 35)})
	testing.expect_value(t, r.btn.squish, 0.04)
	frame(&f, &r, {release(60, 35)})
	testing.expect_value(t, r.btn.squish, 0)
	f.theme.press_squish = 0

	// a list row: lit under the pointer (a selectable row has the hover fill), its selection colour at once
	frame(&f, &r, {move(100, 125)})
	testing.expect(t, .Draw_Hot_Effects in r.row.flags, "a selectable row has hover effects")
	testing.expect_value(t, r.row.hot_t, 1)
	frame(&f, &r, {press(100, 125)})
	frame(&f, &r, {release(100, 125)})
	frame(&f, &r, nil)
	testing.expect_value(t, r.list.sel, 1)
	testing.expect(t, r.row.bg == r.row.target_bg && r.row.target_bg.a > 0.05, "the selected row has its colour in the frame it is selected")
}

@(test)
transitions_when_the_theme_asks :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Run
	defer ui.list_state_destroy(&r.list)
	f.theme.transition_ms = 120
	frame(&f, &r, {move(700, 500)})
	frame(&f, &r, {move(60, 35)})
	testing.expect(t, r.btn.hot_t > 0.05 && r.btn.hot_t < 0.9, "a 120 ms transition: part of the way after one 60 Hz frame")
	testing.expect(t, ui.needs_frame(&f.s), "and more frames to come")
	for _ in 0 ..< 20 { frame(&f, &r, nil) }
	testing.expect_value(t, r.btn.hot_t, 1)
	// animations off (the system's setting): at once even so
	frame(&f, &r, {move(700, 500)}, animations = false)
	testing.expect_value(t, r.btn.hot_t, 0)
}

@(test)
palette_change_cross_fades :: proc(t: ^testing.T) {
	sync.mutex_lock(&ui_state_lock)
	defer sync.mutex_unlock(&ui_state_lock)
	f: Fx
	if !testing.expect(t, open(&f), "fonts") { return }
	defer close(&f)
	r: Run
	defer ui.list_state_destroy(&r.list)
	frame(&f, &r, nil)
	frame(&f, &r, nil)
	testing.expect(t, r.btn.bg == r.btn.target_bg, "settled")
	serial := f.theme.serial
	ui.apply_palette(&f.theme, ui.PALETTE_GRAPHITE)
	testing.expect_value(t, f.theme.serial, serial)   // the same colours: no change, no fade
	ui.apply_palette(&f.theme, ui.PALETTE_DAYLIGHT)
	testing.expect(t, f.theme.serial != serial, "another palette bumps the serial")
	frame(&f, &r, nil)
	testing.expect(t, r.btn.bg != r.btn.target_bg, "the first frame after a palette change is part of the way")
	testing.expect(t, ui.needs_frame(&f.s), "the cross-fade asks for frames")
	for _ in 0 ..< 40 { frame(&f, &r, nil) }
	testing.expect(t, r.btn.bg == r.btn.target_bg, "then it settles")
}

// The fills are steps of the theme's size in sRGB values, whatever the blend space and the palette.
@(test)
state_fills_are_visible_steps :: proc(t: ^testing.T) {
	enc :: proc(c: f32) -> f32 { return render.linear_to_srgb(c) * 255 }
	for p in ([2]ui.Palette{ui.PALETTE_GRAPHITE, ui.PALETTE_DAYLIGHT}) {
		th: ui.Theme
		defer ui.theme_destroy(&th)
		ui.apply_palette(&th, p)
		hover := ui.theme_lookup(&th, {"button"}, "hover_fill")
		press := ui.theme_lookup(&th, {"button"}, "press_fill")
		row := ui.theme_lookup(&th, {"list_row"}, "hover_fill")
		testing.expect(t, hover.a >= 0.06 && hover.a <= 0.08, "button hover: 6 to 8 %")
		testing.expect(t, press.a >= 0.11 && press.a <= 0.14, "button press: about 12 %")
		testing.expect(t, row.a > 0 && row.a < hover.a, "rows: a lighter step")
		testing.expect(t, ui.theme_lookup(&th, {"menu_item"}, "hover_fill").a == 0, "a hovered menu item is its selection")
		testing.expect(t, ui.theme_lookup(&th, {"remove_button", "icon_button"}, "hot text") == draw.hex(p.bad), "a remove button turns to the palette's red under the pointer")
		under := draw.hex(p.panel2)
		for space in render.Blend_Space {
			a := draw.alpha_like_srgb(space, hover, hover.a, under)
			// the result blended in that space, in sRGB values
			got: f32
			if space == .Srgb {
				got = enc(under.g) + a * (enc(hover.g) - enc(under.g))
			} else {
				got = enc(under.g + a * (hover.g - under.g))
			}
			want := enc(under.g) + hover.a * (enc(hover.g) - enc(under.g))
			testing.expectf(t, math.abs(got - want) < 1.5, "%v %v: %.1f vs %.1f", p.dark, space, got, want)
			testing.expect(t, math.abs(want - enc(under.g)) >= 10, "at least 10 sRGB levels: visible")
		}
	}
}
