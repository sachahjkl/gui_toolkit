// Panes the user resizes (ui.splitter) and sections the user folds (ui.accordion): a sidebar of sections, a content
// area and a bottom panel. Double-click a handle to put its default back; Tab to a handle and use the arrow keys.
//   build.bat panes
package panes

import "core:fmt"
import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

App :: struct {
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	theme:    ui.Theme,
	ui_state: ui.State,
	ui_font:  font.Font_Id,
	icons:    font.Font_Id,
	last_tick: time.Tick,
	frames_requested: int,
	sidebar:  f32,       // logical pixels
	bottom:   f32,
	open:     [4]bool,
	saved:    int,       // splitter drags finished (where an app would write its settings)
}

SECTIONS := [4]string{"Conversations", "Contacts", "Files", "Settings"}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	sc := ui.scale()
	room := [2]f32{f32(app.win.size.x), f32(app.win.size.y)} / sc
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row() {
		// sidebar
		ui.next({width = ui.px(app.sidebar * sc), height = ui.fill()})
		if ui.column(.Start, {.Draw_Background}, "###sidebar") {
			for name, i in SECTIONS {
				if ui.accordion(fmt.tprintf("###sec%d", i), name, &app.open[i]) {
					for j in 0 ..< 3 + i {
						ui.next({width = ui.fill(), height = ui.px(em * 1.8)})
						ui.label(fmt.tprintf("    %s item %d###it%d", name, j + 1, j))
					}
				}
			}
		}
		r := ui.splitter("###side_split", .X, &app.sidebar, 140, 480, {default_size = 240, total = room.x, min_other = 240})
		if r.finished { app.saved += 1 }
		// content and bottom panel
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.column() {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.column(.Center, {}, "###content") {
				ui.spacer(ui.px(em))
				ui.next({width = ui.text_size(), height = ui.px(em * 2)})
				ui.label(fmt.tprintf("sidebar %.0f px, bottom panel %.0f px, %d sizes saved###info", app.sidebar, app.bottom, app.saved))
			}
			b := ui.splitter("###bottom_split", .Y, &app.bottom, 60, 600, {default_size = 160, after = true, total = room.y, min_other = 120})
			if b.finished { app.saved += 1 }
			ui.next({width = ui.fill(), height = ui.px(app.bottom * sc)})
			if ui.column(.Start, {.Draw_Background}, "###bottom") {
				ui.next({width = ui.text_size(), height = ui.px(em * 2)})
				ui.label("  Bottom panel")
			}
		}
	}
}

frame :: proc(app: ^App) {
	render.wait_for_frame(&app.r)
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 2) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now
	ui.apply_palette(&app.theme, ui.PALETTE_MIDNIGHT)
	platform.set_dark_title(app.win, true)
	base := ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = app.ui_font, font_size = 14, text_pad = 6, cursor = .Arrow}
	ui.begin_build(&app.ui_state, {window_size = size, events = events, dt = dt, animations = platform.os_animations_enabled(), dpi_scale = app.win.dpi_scale, base = base, window = app.win})
	build_ui(app)
	ui.end_build()
	platform.set_cursor(app.win, ui.cursor(&app.ui_state))
	if ui.needs_frame(&app.ui_state) { app.frames_requested = max(app.frames_requested, 1) }
	draw.begin_frame(&app.dc, size)
	render.frame_begin(&app.r, {0, 0, 0, 1})
	ui.draw_tree(&app.ui_state, &app.dc)
	draw.end_frame(&app.dc)
	render.frame_end(&app.r)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit panes", {900, 600})
	if !render.init_window(&app.r, app.win, app.win.size) { fmt.eprintln("renderer init failed"); return }
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	app.icons, _ = font.load_embedded(&app.fonts, ui.ICON_FONT_DATA)
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons
	app.sidebar, app.bottom = 240, 160
	app.open = {true, false, true, false}
	app.last_tick = time.tick_now()
	app.frames_requested = 2
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user)) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_in_ms(&app.ui_state)) }
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
	ui.destroy(&app.ui_state)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	ui.theme_destroy(&app.theme)
	platform.destroy_window(app.win)
	free(app)
}
