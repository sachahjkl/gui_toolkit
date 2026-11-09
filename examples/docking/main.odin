// Docking (ui.dock_begin, ui.dock_panel, ui.dock_end): six panels of an editor the user rearranges. Drag a tab out of its
// strip: the squares over the stack under the pointer split it or join it, those at the edges of the window dock at an edge,
// a tab dropped elsewhere floats (moved by its strip, resized by its corner, docked back by a double click on its strip).
// The stack's menu (its button, a right click or the menu key on a tab) reaches every target from the keyboard; Ctrl+Tab goes
// through a stack's panels; the handles resize and fold. The layout is saved next to the program (docking_layout.txt) and
// read again at the next start; "View" puts back a closed panel.
//   odin run tools/tk -- build docking
package docking

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "../../src/draw"
import "../../src/font"
import "../../src/platform"
import "../../src/render"
import "../../src/ui"

Panel :: enum u32 { Files = 1, Outline, Editor, Console, Problems, Search }

PANEL_NAMES := [Panel]string{.Files = "files", .Outline = "outline", .Editor = "editor", .Console = "console", .Problems = "problems", .Search = "search"}
PANEL_TITLES := [Panel]string{.Files = "Files", .Outline = "Outline", .Editor = "Editor", .Console = "Console", .Problems = "Problems", .Search = "Search"}
LAYOUT_FILE :: "docking_layout.txt"
// The default layout: files and search at the left, the editor, the console and the problems under it, the outline at the right.
DEFAULT_LAYOUT :: "dock1 x0.220([*files,search] x0.760(y0.700([*editor] [*console,problems]) [*outline]))"
WINDOW_SIZE :: [2]int{1100, 700}
LINE_EM :: 1.6

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
	pacer:    render.Pacer,
	slept:    bool,
	dock:     ui.Dock,     // what the app saves (ui.dock_format)
	saves:    int,
	path:     string,
}

panel_title :: proc(user: rawptr, id: u32) -> string { return PANEL_TITLES[Panel(id)] }
panel_name :: proc(user: rawptr, id: u32) -> string { return PANEL_NAMES[Panel(id)] }
panel_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	for n, p in PANEL_NAMES { if n == name { return u32(p), true } }
	return 0, false
}

// The saved layout (else the default); a panel it does not name (one added since) goes with the editor.
load_layout :: proc(app: ^App) {
	ui.dock_init(&app.dock)
	text, err := os.read_entire_file(app.path, context.temp_allocator)
	if err != nil || !ui.dock_parse(&app.dock, string(text), panel_of, app) { ui.dock_parse(&app.dock, DEFAULT_LAYOUT, panel_of, app) }
	for p in Panel { ui.dock_add(&app.dock, u32(p), ui.dock_with(&app.dock, u32(Panel.Editor))) }
}

save_layout :: proc(user: rawptr, d: ^ui.Dock) {
	app := (^App)(user)
	app.saves += 1
	_ = os.write_entire_file(app.path, transmute([]u8)ui.dock_format(d, panel_name, app))
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {}, "###main") {
		ui.next({width = ui.fill(), height = ui.px(em * 2.2)})
		if ui.row(.Center, {.Draw_Background}, "###bar") {
			ui.spacer(ui.px(em))
			ui.next({width = ui.text_size(), height = ui.pct(1)})
			if ui.button("View###view").clicked { ui.ctx_menu_open(ui.key_from_string(0, "view_menu"), ui.mouse_pos()) }
			if ui.ctx_menu(ui.key_from_string(0, "view_menu")) {
				for p in Panel {
					if ui.menu_item(fmt.tprintf("%s###v%d", PANEL_TITLES[p], int(p)), checked = ui.dock_has(&app.dock, u32(p))).clicked {
						if !ui.dock_add(&app.dock, u32(p), ui.dock_with(&app.dock, u32(Panel.Editor))) { ui.dock_activate(&app.dock, u32(p)) }
					}
				}
				ui.menu_separator()
				if ui.menu_item("Reset the layout###reset").clicked { ui.dock_parse(&app.dock, DEFAULT_LAYOUT, panel_of, app) }
			}
			ui.spacer(ui.px(em))
			ui.next({width = ui.text_size(), height = ui.pct(1)})
			ui.label(fmt.tprintf("%d saves, %d floating###info", app.saves, len(app.dock.floats)))
		}
		ui.next({width = ui.fill(), height = ui.fill()})
		ui.dock_begin(&app.dock, "###dock", {title = panel_title, on_save = save_layout, user = app, close_buttons = true,
			closable = proc(user: rawptr, id: u32) -> bool { return Panel(id) != .Editor }})
		for p in Panel {
			if ui.dock_panel(&app.dock, u32(p)) { panel_content(app, p) }
		}
		ui.dock_end(&app.dock)
	}
}

panel_content :: proc(app: ^App, p: Panel) {
	em := ui.font_size()
	sz := ui.dock_panel_size(&app.dock, u32(p))
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {.Draw_Background}, "###content") {
		ui.spacer(ui.px(em * 0.5))
		for i in 0 ..< 6 {
			ui.next({width = ui.fill(), height = ui.px(em * LINE_EM)})
			ui.label(fmt.tprintf("   %s line %d (%.0f x %.0f px)###l%d", PANEL_TITLES[p], i + 1, sz.x, sz.y, i))
		}
	}
}

frame :: proc(app: ^App, inner := false) {
	at_once := render.pace_frame(&app.pacer, &app.r, app.win, idled = app.slept, dragging = ui.active_key() != 0, inner = inner)
	app.slept = false
	events := platform.poll_events(app.win, false)
	render.mark_input(&app.r)
	if len(events) > 0 { app.frames_requested = max(app.frames_requested, 2) }
	render.resize(&app.r, app.win.size)
	size := draw.Vec2{f32(app.win.size.x), f32(app.win.size.y)}
	now := time.tick_now()
	dt := clamp(f32(time.duration_seconds(time.tick_diff(app.last_tick, now))), 0.0005, 0.1)
	app.last_tick = now
	ui.apply_palette(&app.theme, ui.palette_of("Midnight"))
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
	render.frame_end(&app.r, !at_once)
	render.paced_present(&app.pacer)
	free_all(context.temp_allocator)
}

main :: proc() {
	app := new(App)
	exe, _ := os.get_executable_path(context.allocator)
	app.path = strings.concatenate({filepath.dir(exe), "/", LAYOUT_FILE})
	delete(exe)
	font.init(&app.fonts)
	app.win = platform.open_window("gui_toolkit docking", WINDOW_SIZE, transparent = true)
	if !render.init_window(&app.r, app.win, app.win.size, transparent = true) { fmt.eprintln("renderer init failed"); return }
	render.set_fixed_surface(&app.r, platform.monitor_size(app.win))   // (a resize never stretches a frame: docs/getting-started.md)
	ok: bool
	app.ui_font, ok, _ = font.load_system_or_embedded(&app.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
	if !ok { fmt.eprintln("cannot load a UI font"); return }
	app.icons, _ = font.load_embedded(&app.fonts, ui.ICON_FONT_DATA)
	draw.init(&app.dc, &app.r, &app.fonts)
	ui.init(&app.ui_state, &app.fonts, &app.theme)
	app.ui_state.icon_font = app.icons
	load_layout(app)
	app.last_tick = time.tick_now()
	app.frames_requested = 2
	app.win.user = app
	app.win.on_frame = proc(user: rawptr) { frame((^App)(user), inner = true) }
	platform.show_window(app.win)
	for !platform.is_closed(app.win) {
		if app.frames_requested == 0 && !ui.needs_frame(&app.ui_state) { platform.wait_event(app.win, ui.wake_in_ms(&app.ui_state)); app.slept = true }
		frame(app)
		if app.frames_requested > 0 { app.frames_requested -= 1 }
	}
	ui.dock_destroy(&app.dock)
	delete(app.path)
	ui.destroy(&app.ui_state)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	ui.theme_destroy(&app.theme)
	platform.destroy_window(app.win)
	free(app)
}
