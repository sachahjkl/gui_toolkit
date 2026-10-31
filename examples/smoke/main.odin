// Smoke test for platform + render + font + draw (no UI layer): rects, borders, soft shadow, text, clipping.
package smoke

import "core:fmt"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"

App :: struct {
	win:   ^platform.Window,
	r:     render.Renderer,
	fonts: font.State,
	dc:    draw.Context,
	ui:    font.Font_Id,
	frames: int,
	pacer: render.Pacer,
}

frame :: proc(app: ^App, inner := false) {
	at_once := render.pace_frame(&app.pacer, &app.r, app.win, inner = inner)
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	s := app.win.dpi_scale

	draw.rect(&app.dc, {{0, 0}, size}, draw.hex(0x0f1220ff))
	// shadow + card
	card := draw.Rect{{60 * s, 60 * s}, {420 * s, 220 * s}}
	draw.rect(&app.dc, draw.rect_shift(draw.rect_pad(card, 8 * s), {4, 4}), draw.srgb(0, 0, 0, 0.6), 12 * s, 0, 8 * s)
	draw.rect(&app.dc, card, draw.hex(0x171b2fff), 12 * s)
	draw.rect(&app.dc, card, draw.hex(0x2b3150ff), 12 * s, 1)
	// gradient button
	btn := draw.Rect{{80 * s, 160 * s}, {220 * s, 200 * s}}
	a, b := draw.hex(0x7c8cffff), draw.hex(0x5a6af0ff)
	draw.rect_corners(&app.dc, btn, {a, b, a, b}, {8 * s, 8 * s, 8 * s, 8 * s})
	draw.text(&app.dc, app.ui, 15 * s, {96 * s, 186 * s}, draw.hex(0x0b0e1cff), "Hello, Odin")
	draw.text(&app.dc, app.ui, 22 * s, {80 * s, 120 * s}, draw.hex(0xe6e9f5ff), "gui_toolkit: Odin + D3D11")
	// clipped text
	draw.push_clip(&app.dc, {{240 * s, 160 * s}, {330 * s, 200 * s}})
	draw.text(&app.dc, app.ui, 15 * s, {246 * s, 186 * s}, draw.hex(0xe6e9f5ff), "clipped text that is too long")
	draw.pop_clip(&app.dc)
	// squished
	draw.push_scale(&app.dc, draw.rect_center(btn), 0.92)
	draw.rect(&app.dc, {{340 * s, 160 * s}, {460 * s, 200 * s}}, draw.hex(0x4ade80ff), 8 * s)
	draw.pop_xform(&app.dc)

	draw.end_frame(&app.dc)
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	app.frames += 1
}

main :: proc() {
	app := new(App)
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit smoke", {900, 600}, app, transparent = true)
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("renderer init failed"); return }
	render.set_fixed_surface(&app.r, platform.monitor_size(app.win))   // (a resize never stretches a frame: docs/getting-started.md)
	id, ok, _ := font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("font load failed"); return }
	app.ui = id
	draw.init(&app.dc, &app.r, &app.fonts)
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user), inner = true) }   // only once everything is initialized
	fmt.println("size", app.win.size, "dpi", app.win.dpi_scale)
	platform.show_window(app.win)

	for !platform.is_closed(app.win) {
		platform.poll_events(app.win, wait = app.frames > 2)
		frame(app)
	}
}
