// gui_toolkit example: the showcase. Each scene is composed to be looked at, and to be a screenshot: the intents and their
// hues, the numbers and ranges, the command palette, a menu that searches, the dialogs, the settings page, a node graph
// with its inspector, the toasts, every theme. Its data is fixed: no clock, no chance, the same picture each run.
//   odin run tools/tk -- build showcase
//   build/showcase --scene=graph                      a scene by its name (SCENE_NAMES)
//   build/showcase --theme="Tokyo Night" --light      a theme of ui.THEMES (or of THEMES_OF_THE_USER), its light version
//   build/showcase --finish=edged                     flat, gradient, glass, machined (the default), edged
//   build/showcase --page=scrolling --advanced        the settings scene: the page shown, its Advanced part unfolded
//   build/showcase --headless                         no window of the system: what tk screenshots runs
//   build/showcase --size=1280x800                    the window's size
// tk screenshots makes docs/screenshots/showcase_*.webp and site/img/showcase_*.webp from it (tools/tk/shots.odin).
package showcase

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import config "../../src/config"
import "../../src/devtools"
import flowgraph "../../src/flowgraph"
import "../../src/font"
import "../../src/host"
import "../../src/platform"
import prefs_page "../../src/prefs_page"
import "../../src/render"
import "../../src/ui"
import "../../src/ascii"

Scene :: enum { Intents, Controls, Palette, Menus, Dialog, Confirm, Prompt, Settings, Graph, Toasts, Themes }

// The scenes' names on the command line (--scene=), and their titles in the sidebar.
SCENE_NAMES := [Scene]string{
	.Intents = "intents", .Controls = "controls", .Palette = "palette", .Menus = "menus", .Dialog = "dialog",
	.Confirm = "confirm", .Prompt = "prompt", .Settings = "settings", .Graph = "graph", .Toasts = "toasts", .Themes = "themes",
}

WINDOW_SIZE :: [2]int{1280, 800}

App :: struct {
	shared:   host.Shared,
	main:     host.Host,
	devtools: ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven with the Chrome DevTools Protocol (tk screenshots)
	scene:    Scene,
	builds:   int,                // the builds made: what a scene does once (opens its menu, says its toasts)

	// the look
	themes:   [dynamic]ui.Theme_Def,   // ui.THEMES, then the user's own (THEMES_OF_THE_USER)
	users:    [dynamic]ui.Theme_Def,   // the user's own, as themes_read made them (owned)
	choice:   ui.Theme_Choice,
	shown:    ui.Theme_Shown,

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

	// the overlays
	palette:      ui.Command_Palette,
	dialog_open:  bool,
	dialog_size:  ui.Vec2,
	file_name:    ui.Text_Field,
	confirm_open: bool,
	prompt_open:  bool,
	pin:          ui.Text_Field,
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
}

// The application, up to its first frame (the caller makes the frames: `frame`). nil: it cannot start, and has said why.
open :: proc(o: Open_Options) -> ^App {
	app := new(App)
	headless := o.headless
	size := WINDOW_SIZE
	app.choice = {name = "Graphite", mode = .Dark, finish = .Machined, glow = 1}
	page, advanced := "", false
	for a in o.args {
		switch {
		case a == "--headless": headless = true
		case a == "--light": app.choice.mode = .Light
		case a == "--advanced": advanced = true
		case strings.has_prefix(a, "--scene="):
			for name, s in SCENE_NAMES { if ascii.equal_fold(name, a[len("--scene="):]) { app.scene = s } }
		case strings.has_prefix(a, "--theme="): app.choice.name = a[len("--theme="):]
		case strings.has_prefix(a, "--finish="): app.choice.finish = ui.finish_of(a[len("--finish="):])
		case strings.has_prefix(a, "--page="): page = a[len("--page="):]
		case strings.has_prefix(a, "--size="):
			v := a[len("--size="):]
			if x := strings.index_byte(v, 'x'); x > 0 {
				w, wok := strconv.parse_int(v[:x])
				h, hok := strconv.parse_int(v[x + 1:])
				if wok && hok && w > 0 && h > 0 { size = {w, h} }
			}
		}
	}
	if !host.host_open(&app.main, &app.shared, {title = "gui_toolkit showcase", size = size, headless = headless}, build, app) {
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

	themes_make(app)
	values_reset(app)
	settings_open(app, page, advanced)
	graph_make(app)
	app.announcer = {mode = .Window, window = h.win}
	app.devtools = devtools.start_from_env(h.win, "gui_toolkit showcase")
	return app
}

// The end of what `open` made.
close :: proc(app: ^App) {
	devtools.stop(app.devtools)
	graph_destroy(app)
	settings_close(app)
	ui.palette_destroy(&app.palette)
	ui.field_destroy(&app.file_name)
	ui.field_wipe(&app.pin)
	ui.field_destroy(&app.pin)
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
	app.format = 2
	app.switches = {true, false, true}
	app.checks = {true, false}
	app.radio = 1
	app.bold = true
	app.dialog_open = app.scene == .Dialog
	app.confirm_open = app.scene == .Confirm
	app.prompt_open = app.scene == .Prompt
	ui.field_set(&app.file_name, "harbour-at-dusk")
	ui.field_set(&app.pin, "472913")
	if app.scene == .Palette { ui.palette_open(&app.palette) }   // (nothing typed: every command under its group, with its keys)
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
