// Docking with views (ui.views_frame, ui.view_register, ui.view_drag_handle): five panels of an editor around its
// content. A panel alone at an edge adds nothing to what it draws; two at one edge are tabs. Drag a panel by its title or
// its tab: it floats as an internal window, and the four squares at the middle of the window's edges dock it where it is
// let go. The hover of a panel's top shows its Float and Close icons; a right click there opens its menu (Detach, Dock
// left, right, bottom, Re-attach, Close); "View" lists the same acts. F6 goes through the areas. The places and the
// zones' sizes are remembered next to the program (docking_views.txt) and read again at the next start.
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

Panel :: enum u32 { Files, Search, Outline, Console, Problems }

PANEL_IDS := [Panel]string{.Files = "files", .Search = "search", .Outline = "outline", .Console = "console", .Problems = "problems"}
PANEL_TITLES := [Panel]string{.Files = "Files", .Search = "Search", .Outline = "Outline", .Console = "Console", .Problems = "Problems"}
PANEL_EDGES := [Panel]ui.View_Edge{.Files = .Left, .Search = .Left, .Outline = .Right, .Console = .Bottom, .Problems = .Bottom}
MEMORY_FILE :: "docking_views.txt"
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
	views:    ui.Views,   // the panels and what is remembered of them
	path:     string,
}

// A panel: its title (which moves it), then its lines.
panel_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	p := panel_of(v.id)
	room := ui.view_room(v)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(.Start, {.Draw_Background}, "###panel") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		title := ui.label(fmt.tprintf("  %s###title", PANEL_TITLES[p]))
		ui.view_drag_handle(v, title.box)
		for i in 0 ..< 6 {
			ui.next({width = ui.fill(), height = ui.px(em * LINE_EM)})
			ui.label(fmt.tprintf("   %s line %d (%.0f x %.0f px)###l%d", PANEL_TITLES[p], i + 1, room.x, room.y, i))
		}
	}
}

panel_of :: proc(id: string) -> Panel {
	for n, p in PANEL_IDS { if n == id { return p } }
	return .Files
}

build_ui :: proc(app: ^App) {
	em := ui.font_size()
	if ui.views_frame(&app.views) {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {}, "###main") {
			ui.next({width = ui.fill(), height = ui.px(em * 2.2)})
			if ui.row(.Center, {.Draw_Background}, "###bar") {
				ui.spacer(ui.px(em))
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				if ui.button("view", "View").clicked { ui.menu_open("view_menu", ui.mouse_pos()) }
				if ui.menu("view_menu") { view_menu(app) }
			}
			// the content: the editor, never moved
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(.Start, {}, "###editor") {
				ui.spacer(ui.px(em * 0.5))
				for i in 0 ..< 12 {
					ui.next({width = ui.fill(), height = ui.px(em * LINE_EM)})
					ui.label(fmt.tprintf("   Editor line %d###e%d", i + 1, i))
				}
			}
		}
	}
}

// Each panel, open or closed; then what the palette would list (ui.views_commands).
view_menu :: proc(app: ^App) {
	for p in Panel {
		open := ui.view_is_open(&app.views, PANEL_IDS[p])
		if ui.menu_item(fmt.tprintf("%s###v%d", PANEL_TITLES[p], int(p)), checked = open).clicked {
			if open { ui.view_close(&app.views, PANEL_IDS[p]) } else { ui.view_open(&app.views, PANEL_IDS[p], app) }
		}
	}
	ui.menu_separator()
	commands, acts := ui.views_commands(&app.views)
	for c, i in commands {
		if ui.menu_item(fmt.tprintf("%s###c%d", c.label, i), icon = c.icon).clicked { ui.views_command_run(&app.views, acts[i]) }
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
	app.path = strings.concatenate({filepath.dir(exe), "/", MEMORY_FILE})
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

	// (the first start opens every panel; later ones, those open when the program quit)
	_, err := os.read_entire_file(app.path, context.temp_allocator)
	first := err != nil
	ui.views_init(&app.views, {path = app.path})
	ui.set_views(&app.ui_state, &app.views)
	for p in Panel {
		ui.view_register(&app.views, PANEL_IDS[p], panel_view, ui.View_Options{title = PANEL_TITLES[p], home = .Panel, home_place = {edge = PANEL_EDGES[p]}, extent_em = PANEL_EDGES[p] == .Bottom ? 12 : 16})
	}
	for p in Panel {
		if first || ui.view_was_open(&app.views, PANEL_IDS[p]) { ui.view_open(&app.views, PANEL_IDS[p], app, owner = &app.ui_state) }
	}

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
	ui.views_destroy(&app.views)
	delete(app.path)
	ui.destroy(&app.ui_state)
	draw.destroy(&app.dc)
	render.destroy(&app.r)
	font.destroy(&app.fonts)
	ui.theme_destroy(&app.theme)
	platform.destroy_window(app.win)
	free(app)
}
