// Views in every presentation (ui.views_frame, ui.view_register, ui.view_drag_handle, host.view_windows): five panels of
// an editor around its content, and a Properties view that opens as a dialog. A panel alone at an edge adds nothing to
// what it draws; two at one edge are tabs. Drag a panel by its title or its tab: it floats as an internal window, and the
// four squares at the middle of the window's edges dock it where it is let go; let go outside the window (Windows, X11),
// it opens in a window of its own. The hover of a panel's top shows its Float and Close icons; a right click on a header
// opens its menu (Detach into a window, Float, Dock left, right, bottom, Re-attach, Close); "View" lists the same acts.
// A view's window closed by the system goes back to where it was at home. F6 goes through the areas. The places, the
// zones' sizes and the windows' sizes are remembered next to the program (docking_views.txt).
//   odin run tools/tk -- build docking
package docking

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../../src/font"
import host "../../src/host"
import "../../src/platform"
import "../../src/ui"

Panel :: enum u32 { Files, Search, Outline, Console, Problems }

PANEL_IDS := [Panel]string{.Files = "files", .Search = "search", .Outline = "outline", .Console = "console", .Problems = "problems"}
PANEL_TITLES := [Panel]string{.Files = "Files", .Search = "Search", .Outline = "Outline", .Console = "Console", .Problems = "Problems"}
PANEL_EDGES := [Panel]ui.View_Edge{.Files = .Left, .Search = .Left, .Outline = .Right, .Console = .Bottom, .Problems = .Bottom}
MEMORY_FILE :: "docking_views.txt"
WINDOW_SIZE :: [2]int{1100, 700}
LINE_EM :: 1.6
PROPERTIES :: "properties"

App :: struct {
	shared: host.Shared,
	main:   host.Host,
	views:  ui.Views,   // the views and what is remembered of them
	path:   string,
	name:   ui.Line_Edit,   // the Properties view's field: the program's data, the same in every presentation
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

// The Properties view: a field and its buttons, wherever it is shown.
properties_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	if ui.dialog_body("props_body") {
		ui.label(fmt.tprintf("Shown as: %v###props_where", v.presentation))
		ui.next({width = ui.fill()})
		ui.line_edit("###props_name", &app.name, {placeholder = "A name"})
		ui.spacer(ui.px(em * 0.5))
	}
	if ui.dialog_buttons("props_buttons") {
		if ui.button("props_done", "Done", o = {intent = .Primary}).clicked { ui.view_end(v, 0) }
	}
}

panel_of :: proc(id: string) -> Panel {
	for n, p in PANEL_IDS { if n == id { return p } }
	return .Files
}

build :: proc(h: ^host.Host, size: host.Vec2) {
	app := (^App)(h.user)
	em := ui.font_size()
	_, _ = ui.view_ended(&app.views, PROPERTIES)
	if ui.views_frame(&app.views) {
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(.Start, {}, "###main") {
			ui.next({width = ui.fill(), height = ui.px(em * 2.2)})
			if ui.row(.Center, {.Draw_Background}, "###bar") {
				ui.spacer(ui.px(em))
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				if ui.button("view", "View").clicked { ui.menu_open("view_menu", ui.mouse_pos()) }
				if ui.menu("view_menu") { view_menu(app) }
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				if ui.button("props", "Properties").clicked { ui.view_open(&app.views, PROPERTIES, app) }
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

main :: proc() {
	app := new(App)
	defer free(app)
	exe, _ := os.get_executable_path(context.allocator)
	app.path = strings.concatenate({filepath.dir(exe), "/", MEMORY_FILE})
	delete(exe)
	defer delete(app.path)
	if !host.host_open(&app.main, &app.shared, {title = "gui_toolkit docking", size = WINDOW_SIZE}, build, app) { os.exit(1) }
	app.main.background = ui.theme_lookup(&app.shared.theme, {}, "background")
	platform.set_dark_title(app.main.win, true)
	if icons, ok := font.load_embedded(&app.shared.fonts, ui.ICON_FONT_DATA); ok { app.main.state.icon_font = icons }

	ui.views_init(&app.views, {path = app.path})
	ui.set_views(&app.main.state, &app.views)
	ui.views_set_windows(&app.views, host.view_windows(&app.shared))
	for p in Panel {
		ui.view_register(&app.views, PANEL_IDS[p], panel_view, ui.View_Options{title = PANEL_TITLES[p], home = .Panel, home_place = {edge = PANEL_EDGES[p]}, extent_em = PANEL_EDGES[p] == .Bottom ? 12 : 16})
	}
	ui.view_register(&app.views, PROPERTIES, properties_view, ui.View_Options{title = "Properties", width_em = 26, resizable = true})
	// (the first start opens every panel; later ones, those open when the program quit)
	for p in Panel { _ = ui.view_restore(&app.views, PANEL_IDS[p], app, first_start_open = true, owner = &app.main.state) }
	_ = ui.view_restore(&app.views, PROPERTIES, app, owner = &app.main.state)

	platform.show_window(app.main.win)
	for !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		host.host_frame(&app.main)
	}
	// (the views first: their windows close while the main window is still there)
	ui.views_destroy(&app.views)
	ui.line_edit_destroy(&app.name)
	host.host_close(&app.main)
}
