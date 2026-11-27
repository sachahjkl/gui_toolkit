// gui_toolkit example: the showcase. Each scene is composed to be looked at, and to be a screenshot: the intents and their
// hues, the numbers and ranges, the command palette, a menu that searches, the dialogs, the settings page, a node graph
// with its inspector, the toasts, the steppers, every theme, the values and the controls they get. Its data is fixed: no clock, no chance, the same picture each run.
//   odin run tools/tk -- build showcase
//   build/showcase --scene=graph                      a scene by its name (SCENE_NAMES)
//   build/showcase --theme="Tokyo Night" --light      a theme of ui.THEMES (or of THEMES_OF_THE_USER), its light version
//   build/showcase --finish=edged                     flat, gradient, glass, machined (the default), edged
//   build/showcase --page=scrolling --advanced        the settings scene: the page shown, its Advanced part unfolded
//   build/showcase --scene=views --views=floating     the views scene: docked (panels), floating (and a floating
//                                                     window), dialog (and a dialog), tabs (every terminal)
//   build/showcase --scene=files                      the file browser over the page, on a demo source (files.odin)
//   build/showcase --scene=values --value=size        a value and the control it gets (values.odin: --unit=, --open)
//   build/showcase --headless                         no window of the system: what tk screenshots runs
//   build/showcase --size=1280x800                    the window's size
//   build/showcase --rounding=0                       the rounding setting (0 square .. 2), over the default 1
// tk screenshots makes docs/screenshots/showcase_*.webp and site/img/showcase_*.webp from it (tools/tk/shots.odin).
package showcase

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import config "gt:config"
import "gt:devtools"
import flowgraph "gt:flowgraph"
import "gt:font"
import host "gt:host"
import "gt:platform"
import prefs_page "gt:prefs_page"
import "gt:render"
import "gt:ui"
import "gt:ascii"

Scene :: enum { Intents, Controls, Palette, Menus, Dialog, Confirm, Prompt, Settings, Graph, Toasts, Themes, Toolbar, Views, Files, Steppers, Values, Wheels, Editor }

// The scenes' names on the command line (--scene=), and their titles in the sidebar.
SCENE_NAMES := [Scene]string{
	.Intents = "intents", .Controls = "controls", .Palette = "palette", .Menus = "menus", .Dialog = "dialog",
	.Confirm = "confirm", .Prompt = "prompt", .Settings = "settings", .Graph = "graph", .Toasts = "toasts", .Themes = "themes",
	.Toolbar = "toolbar", .Views = "views", .Files = "files", .Steppers = "steppers", .Values = "values",
	.Wheels = "wheels", .Editor = "editor",
}

WINDOW_SIZE :: [2]int{1280, 800}

App :: struct {
	shared:   host.Shared,
	main:     host.Host,
	devtools: ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven with the Chrome DevTools Protocol (tk screenshots)
	scene:    Scene,
	builds:   int,                // the builds made: what a scene does once (opens its menu, says its toasts)
	nav:      ui.Side_Panel,      // the showcase sidebar: resizable and foldable to its icon rail

	// the look
	themes:   [dynamic]ui.Theme_Def,   // ui.THEMES, then the user's own (THEMES_OF_THE_USER)
	users:    [dynamic]ui.Theme_Def,   // the user's own, as themes_read made them (owned)
	choice:   ui.Theme_Choice,
	shown:    ui.Theme_Shown,
	other_theme: string,          // remembered single-mode theme when switching Light/Dark (e.g. Graphite <-> Midnight)

	// the controls
	quality:  int,
	width:    f32,
	copies:   int,
	from, to: f32,
	volume:   f32,
	format:   int,
	switches: [3]bool,
	checks:   [2]bool,
	radio:    int,
	bold, italic: bool,
	view:     int,

	// the wheels: a delay (seconds), an alarm's hour and minute, a date (day, month, year), a size
	delay:    int,
	delay_open: bool,
	alarm_h, alarm_m: int,
	day, month, year: int,
	size:     int,

	// the tool bars: the tool chosen, the colour, the width, bold, the dashes; the "…" menu opened at the start
	bar_tool, bar_colour, bar_dash: int,
	bar_width: f32,
	bar_bold:  bool,
	bar_menu_opened: bool,

	// the views scene (views.odin): what it opens (--views=), whether its views are open, its terminals, its picture's
	// tint, the inspector's toggle
	views_variant:  Views_Variant,
	views_opened:   bool,
	terminals:      [TERMINALS_MAX]Terminal,
	terminal_count: int,
	views_hue, views_sat, views_val: f32,
	views_keep_meta: bool,

	// the file browser's scene (files.odin): its demo source, read by the dialog while it is open
	files:          ui.File_Source,

	// the values scene (values.odin): its registry, its page's state, the value chosen
	values:         Values,

	// the editor's scene (editor.odin): its dock
	editor:         Editor,

	// the overlays: views of the window's own Views, shown as dialogs (in memory only: the showcase keeps no file)
	palette:      ui.Command_Palette,   // (its usage memory in memory only: the showcase keeps no file)
	palette_settings: prefs_page.Palette_Settings,
	file_name:    ui.Line_Edit,
	pin:          ui.Line_Edit,
	reveal:       bool,
	announcer:    ui.Announcer,

	// the settings
	prefs:        config.Prefs,
	page:         prefs_page.Page,
	themes_file:  prefs_page.Themes_File,
	watch:        prefs_page.Standard_Watch,

	// the graph
	graph:     flowgraph.Graph,
	flow:      ui.Flow_Nodes,
	graph_view: ui.Graph_View,
	selected:  [dynamic]u64,
	inspector: ui.Node_Inspector,
}

// What `open` starts from.
Open_Options :: struct {
	args:     []string,   // the command line, without the program's name
	headless: bool,       // no window of the system (also --headless)
	gpu:      bool,       // headless, on the graphics card when there is one (a film; host.Open_Options.headless_gpu)
}

// The application, up to its first frame (the caller makes the frames: `frame`). nil: it cannot start, and has said why.
open :: proc(o: Open_Options) -> ^App {
	app := new(App)
	headless := o.headless
	size := WINDOW_SIZE
	app.choice = {name = "Graphite", mode = .Dark, finish = .Machined, glow = 1}
	page, advanced := "", false
	value, unit, open := "", "", false
	rounding := -1.0   // (< 0: the setting's own)
	for a in o.args {
		switch {
		case a == "--headless": headless = true
		case a == "--light": app.choice.mode = .Light
		case a == "--advanced": advanced = true
		case a == "--open": open = true
		case strings.has_prefix(a, "--value="): value = a[len("--value="):]
		case strings.has_prefix(a, "--unit="): unit = a[len("--unit="):]
		case strings.has_prefix(a, "--scene="):
			for name, s in SCENE_NAMES { if ascii.equal_fold(name, a[len("--scene="):]) { app.scene = s } }
		case strings.has_prefix(a, "--theme="): app.choice.name = a[len("--theme="):]
		case strings.has_prefix(a, "--finish="): app.choice.finish = ui.finish_of(a[len("--finish="):])
		case strings.has_prefix(a, "--page="): page = a[len("--page="):]
		case strings.has_prefix(a, "--rounding="):
			if v, ok := strconv.parse_f64(a[len("--rounding="):]); ok { rounding = v }
		case strings.has_prefix(a, "--views="):
			for name, v in VIEWS_VARIANT_NAMES { if ascii.equal_fold(name, a[len("--views="):]) { app.views_variant = v } }
		case strings.has_prefix(a, "--size="):
			v := a[len("--size="):]
			if x := strings.index_byte(v, 'x'); x > 0 {
				w, wok := strconv.parse_int(v[:x])
				h, hok := strconv.parse_int(v[x + 1:])
				if wok && hok && w > 0 && h > 0 { size = {w, h} }
			}
		}
	}
	if !host.host_open(&app.main, &app.shared, {title = "gui_toolkit showcase", size = size, headless = headless, headless_gpu = o.gpu}, build, app) {
		free(app)
		return nil
	}
	h := &app.main
	h.state.icon_font = ui.lucide_icons()   // (the palette's, the menus' and the buttons' glyphs are Lucide's)
	// (the host loads the interface's face only: the code and the facts are in a monospace one, the system's or the one compiled in)
	if mono, ok, _ := font.load_system_or_embedded(&app.shared.fonts, headless ? "" : platform.system_font_path("consola.ttf"), font.FALLBACK_MONO_DATA); ok {
		h.state.mono_font = mono
	}
	ui.set_animations(&h.state, .On)          // (a dialog fades in, a toast glides: the same on every system)
	ui.set_toast_position(&h.state, .Bottom_Right)
	h.after_input = 4
	h.settle = 4
	h.params = params
	h.before_input = proc(h: ^host.Host) { app := (^App)(h.user); devtools.service(app.devtools, &h.state, &app.shared.r) }

	app.files = demo_files()
	export_register(app)
	views_register(app)
	themes_make(app)
	values_reset(app)
	settings_open(app, page, advanced)
	values_open(&app.values, value, unit, open)
	// (after the settings: the command line's rounding, a picture at another rounding than the setting's default)
	if rounding >= 0 { _ = config.set_float(&app.prefs, "appearance.rounding", rounding) }
	graph_make(app)
	app.announcer = {mode = .Window, window = h.win}
	app.devtools = devtools.start_from_env(h.win, "gui_toolkit showcase")
	return app
}

// The end of what `open` made.
close :: proc(app: ^App) {
	devtools.stop(app.devtools)
	graph_destroy(app)
	if app.editor.ready { ui.dock_destroy(&app.editor.dock) }
	values_close(&app.values)
	settings_close(app)
	ui.palette_destroy(&app.palette)
	ui.line_edit_destroy(&app.file_name)
	ui.line_edit_wipe(&app.pin)
	ui.line_edit_destroy(&app.pin)
	host.host_close(&app.main)
	delete(app.themes)
	ui.themes_destroy(&app.users)
	free(app)
}

frame :: proc(app: ^App) { host.host_frame(&app.main) }

// Before each build: the theme chosen (once: theme_show applies it again only when something it reads changed).
@(private = "file")
params :: proc(h: ^host.Host, p: ^ui.Build_Params) {
	app := (^App)(h.user)
	if ui.theme_show(&app.shared.theme, app.themes[:], app.choice, &app.shown, render.blend_space(&app.shared.r)) {
		platform.set_dark_title(h.win, !app.shown.light)
		h.background = ui.theme_lookup(&app.shared.theme, {}, "background")
	}
}

// Themes a user wrote in the themes file beside the settings (themes.md, "A user's themes"): read as Themes_File reads
// it, so they show among the toolkit's.
THEMES_OF_THE_USER :: `# themes.txt
[Ember]
from = Graphite
accent = #e8743b
red = #f05d4a
light.accent = #c4521c

[Lagoon]
from = Midnight
accent = #2ec4b6
cyan = #5eead4
bg0 = #0b1418
bg1 = #0f1b20
bg2 = #13222a
bg3 = #1a2e36
`

@(private = "file")
themes_make :: proc(app: ^App) {
	app.users = ui.themes_read(THEMES_OF_THE_USER, ui.THEMES[:], ui.THEMES[0])
	append(&app.themes, ..ui.THEMES[:])
	append(&app.themes, ..app.users[:])
}

// The values the controls show: the same each run.
@(private = "file")
values_reset :: proc(app: ^App) {
	app.quality, app.width, app.copies = 82, 12.5, 3
	app.from, app.to = 9, 17
	app.volume = 0.64
	app.delay, app.alarm_h, app.alarm_m = 90 * 60, 7, 30
	app.day, app.month, app.year, app.size = 13, 10, 2026, 1
	app.bar_tool, app.bar_colour, app.bar_width, app.bar_bold, app.bar_dash = 1, 4, 4, true, 0
	app.views_hue, app.views_sat, app.views_val, app.views_keep_meta = 205, 0.45, 0.55, true
	app.format = 2
	app.switches = {true, false, true}
	app.checks = {true, false}
	app.radio = 1
	app.bold = true
	ui.line_edit_set(&app.file_name, "harbour-at-dusk")
	ui.line_edit_set(&app.pin, "472913")
	// (the scene's overlay opens in the first build: a view's owner is the window being built)
}

main :: proc() {
	app := open({args = os.args[1:]})
	if app == nil { fmt.eprintln("showcase: it cannot start"); os.exit(1) }
	defer close(app)
	if !platform.is_offscreen(app.main.win) { platform.show_window(app.main.win) }
	for !platform.is_closed(app.main.win) {
		host.hosts_wait({&app.main})
		frame(app)
	}
}
