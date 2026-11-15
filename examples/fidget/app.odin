// fidget: a widget gallery built on gui_toolkit. Four pages (Controls, Inputs, Data, Playground), a command palette,
// menus, toasts, a modal dialog, six themes, persisted settings. Every widget here comes from the `ui` package.
package fidget

import "core:time"
import "gt:devtools"
import "gt:draw"
import "gt:font"
import "gt:platform"
import "gt:render"
import "gt:ui"

// Icon-font characters (icons.ttf)
ICON_GEAR :: "G"
ICON_PENCIL :: "P"
ICON_LIST :: "J"
ICON_CUBE :: "*"
ICON_PLAY :: "g"
ICON_PAUSE :: "r"
ICON_STOP :: "s"
ICON_TRASH :: "3"
ICON_PIN :: "p"
ICON_CLIPBOARD :: "a"
ICON_FIND :: "N"
ICON_PALETTE :: "E"
ICON_REFRESH :: "q"
ICON_SAVE :: "m"
ICON_WINDOW :: "n"
ICON_TARGET :: "l"
ICON_GRID :: "A"
ICON_PERSON :: "4"
ICON_QUESTION :: "?"
ICON_FOLDER :: "c"
ICON_FOLDER_OPEN :: "b"
ICON_FILE :: "f"
ICON_UNDO :: "j"
ICON_DOT :: "."

Page :: enum { Controls, Inputs, Data, Playground }
page_names := [len(Page)]string{"Controls", "Inputs", "Data", "Playground"}
page_icons := [len(Page)]string{ICON_GEAR, ICON_PENCIL, ICON_LIST, ICON_CUBE}

Anim_Mode :: enum { System, On, Off }

////////////////////////////////
// Palettes (each one expands into the full theme)

DEFAULT_PALETTE :: "Graphite"

// Every version of every theme of the toolkit, by its name ("Nord", "Nord Light"): what the theme menu and the settings list.
palettes: []ui.Named_Palette

palettes_make :: proc() {
	if len(palettes) == 0 { palettes = ui.theme_palettes(ui.THEMES[:], allocator = context.allocator) }
}

// The palette of this name's index (the first when there is none).
palette_index :: proc(name: string) -> int {
	for p, i in palettes { if p.name == name { return i } }
	return 0
}

////////////////////////////////
// Commands: one enum + one table drive the palette, the menus and the shortcuts

Command :: enum {
	Go_Controls, Go_Inputs, Go_Data, Go_Playground,
	Next_Theme, Toggle_Machined,
	Toggle_Status, Toggle_Animations, Anim_System, Anim_On, Anim_Off, Toggle_Slowmo, Toggle_Boxes,
	Toast_Info, Toast_Good, Toast_Warn, Toast_Bad, Clear_Toasts, Open_Modal, About, Settings,
	Spawn_Balls, Confetti, Clear_Balls, Reset_Values,
	Zoom_In, Zoom_Out, Zoom_Reset,
	Quit,
}

// The palette, the keys and the person's own keys (ui.Keymap) read this table. The zoom's keys are the interface's own
// (the build zooms on them): listed for the palette and the sheet. Ids: the person's keys and aliases are stored by them.
COMMANDS := [Command]ui.Command{
	.Go_Controls = {id = "go.controls", label = "Go to Controls", group = "Navigate", keys = {{.N1, {.Ctrl}}}, icon = ICON_GEAR},
	.Go_Inputs = {id = "go.inputs", label = "Go to Inputs", group = "Navigate", keys = {{.N2, {.Ctrl}}}, icon = ICON_PENCIL},
	.Go_Data = {id = "go.data", label = "Go to Data", group = "Navigate", keys = {{.N3, {.Ctrl}}}, icon = ICON_LIST},
	.Go_Playground = {id = "go.playground", label = "Go to Playground", group = "Navigate", keys = {{.N4, {.Ctrl}}}, icon = ICON_CUBE},
	.Next_Theme = {id = "theme.next", label = "Theme: Cycle next", group = "Theme", keys = {{.T, {.Ctrl}}}, icon = ICON_REFRESH},
	.Toggle_Machined = {id = "theme.machined", label = "Theme: Machined finish", group = "Theme", keys = {{.M, {.Ctrl}}}, icon = ICON_PALETTE},
	.Toggle_Status = {id = "view.status", label = "View: Toggle status bar", group = "View", keys = {{.B, {.Ctrl}}}, icon = ICON_WINDOW},
	.Toggle_Animations = {id = "view.animations", label = "View: Toggle animations", group = "View", keys = {{.J, {.Ctrl}}}, icon = ui.ICON_RADIO_ON},
	.Anim_System = {id = "view.animations_system", label = "View: Animations follow system setting", group = "View", icon = ICON_PAUSE},
	.Anim_On = {id = "view.animations_on", label = "View: Animations always on", group = "View", icon = ICON_PAUSE},
	.Anim_Off = {id = "view.animations_off", label = "View: Animations always off", group = "View", icon = ICON_PAUSE},
	.Toggle_Slowmo = {id = "view.slow_motion", label = "View: Slow-motion animations", group = "View", icon = ICON_PAUSE},
	.Toggle_Boxes = {id = "view.boxes", label = "View: Count UI boxes in the status bar", group = "View", icon = ICON_GRID},
	.Toast_Info = {id = "toast.info", label = "Toast: Info", group = "Feedback", icon = ui.ICON_INFO},
	.Toast_Good = {id = "toast.good", label = "Toast: Success", group = "Feedback", icon = ui.ICON_CHECK},
	.Toast_Warn = {id = "toast.warn", label = "Toast: Warning", group = "Feedback", icon = ui.ICON_WARN},
	.Toast_Bad = {id = "toast.bad", label = "Toast: Error", group = "Feedback", icon = ui.ICON_WARN_BIG},
	.Clear_Toasts = {id = "toast.clear", label = "Toast: Dismiss all", group = "Feedback", icon = ui.ICON_X},
	.Open_Modal = {id = "dialog.confirm", label = "Dialog: Open confirm dialog", group = "Feedback", icon = ICON_QUESTION},
	.About = {id = "about", label = "Help: About gui_toolkit fidget", group = "General", keys = {{.F1, {}}}, icon = ui.ICON_INFO},
	.Settings = {id = "settings", label = "Settings...", group = "General", keys = {{.Comma, {.Ctrl}}}, icon = ICON_GEAR},
	.Spawn_Balls = {id = "playground.balls", label = "Playground: Spawn 25 balls", group = "Playground", icon = ICON_DOT},
	.Confetti = {id = "playground.confetti", label = "Playground: Confetti", group = "Playground", icon = ICON_TARGET},
	.Clear_Balls = {id = "playground.clear", label = "Playground: Clear balls", group = "Playground", icon = ICON_TRASH},
	.Reset_Values = {id = "values.reset", label = "Reset all widget values", group = "General", icon = ICON_UNDO},
	.Zoom_In = {id = "zoom.in", label = "View: Zoom in", group = "View", keys = ui.ZOOM_IN_KEYS[:], icon = ui.ICON_ADD},
	.Zoom_Out = {id = "zoom.out", label = "View: Zoom out", group = "View", keys = ui.ZOOM_OUT_KEYS[:], icon = ui.ICON_MINUS},
	.Zoom_Reset = {id = "zoom.reset", label = "View: Reset zoom", group = "View", keys = ui.ZOOM_RESET_KEYS[:], icon = ui.ICON_MINUS},
	.Quit = {id = "quit", label = "Quit", group = "General", keys = {{.F4, {.Alt}}}, icon = ICON_STOP},
}

////////////////////////////////
// Data page

Data_Row :: struct {
	id:     u32,
	name:   [32]u8,
	name_n: u8,
	dept:   u8,
	status: u8,
	score:  u16,
	year:   u16,
}

DATA_ROW_COUNT :: 20000
DATA_COLS :: 5

Tree_Node :: struct { name: string, parent: int, dir: bool }

////////////////////////////////
// Playground

Ball :: struct { alive: bool, p, v: [2]f32, r: f32, c: draw.Color }
Particle :: struct { alive: bool, p, v: [2]f32, life, max_life, size: f32, c: draw.Color }
BALL_MAX :: 300
PARTICLE_MAX :: 600

Note :: struct { pos, size: [2]f32, title: string, kind: int }

////////////////////////////////
// App

App :: struct {
	devtools: ^devtools.Server,   // TOOLKIT_DEVTOOLS=<port>: driven with the Chrome DevTools Protocol
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	announcer: ui.Announcer,   // what the demo says: toasts of the window (a demo of them)
	theme:    ui.Theme,
	ui_font, mono, icons: font.Font_Id,
	last_tick: time.Tick,
	frames_requested: int,
	bench_n: int,             // --bench: frames to measure
	bench_out: string,
	bench_ms: [dynamic]f32,
	frame_index: u64,
	title_cache: string,
	debug_dump: bool,
	debug_toasts: bool,
	want_quit: bool,
	ui_ms: f32,
	real_dt: f32,
	frames: ui.Frame_History,   // per frame: build ms, draw ms (the status bar's graph)

	// settings (persisted)
	palette_idx: int,
	machined:    bool,   // the machined finish (a theme made for its own finish keeps it)
	finish:      Maybe(ui.Finish),   // --finish=name: every theme in this finish (not saved)
	anim_mode:   Anim_Mode,
	show_status: bool,
	saved:       Saved_Settings,

	// view
	page:        Page,
	slowmo:      bool,
	show_boxes:  bool,
	os_anim_on:  bool,
	os_anim_checked_ms: f64,
	accent_override: bool,
	hue, sat, val: f32,

	// overlays: views of the window's Views, shown as dialogs (shell.odin: the toolkit's palette, CONFIRM_VIEW, ABOUT_VIEW,
	// SETTINGS_VIEW)
	palette:          ui.Command_Palette,
	keymap:           ui.Keymap,   // the person's keys and aliases, set from the palette (kept for the run)
	corner_smoothing: f32,   // 0 circular, 1 squircle
	window_square: bool,
	translucent, backdrop_ok: bool,   // current palette shows the OS backdrop (and the OS accepted it)     // last value sent to the OS (window corners follow rounding = 0)

	// controls page
	sw:      [3]bool,
	sliders_on: bool,
	chk:     [3]bool,
	radio_sel: int,
	slider:  [3]f32,
	range_lo, range_hi: f32,
	stepper: int,
	size:    f32,
	seg:     int,
	chips:   u32,
	dd:      [2]int,
	rating:  int,
	progress: f32,
	progress_run: bool,
	ctx_check: bool,
	bar_tool:  int,    // the tool bars' demo: the tool chosen, the colour, the width, the grid
	bar_color: int,
	bar_width: f32,
	bar_grid:  bool,

	// inputs page
	name, email, number, search, tag_input, bio, filter: ui.Line_Edit,
	editor:  ui.Text_Edit,
	editor_tab_indents: bool,
	composer: ui.Text_Edit,   // a chat composer: wraps, grows from 1 to 5 lines
	settings_in: string,   // Open_Options.settings_dir
	integrated:  bool,   // --integrated: the menu bar is the window's title bar (ui.title_bar, ui.window_buttons)
	tags:    [dynamic]string,
	agree:   bool,
	files_said:   string,        // what the last file dialog answered (owned; "": none yet)
	files_bar:    ui.Path_Bar,   // the path bar over FILES_TREE (files.odin)
	files_folder: int,           // the folder it shows: an index of FILES_TREE

	// data page
	rows:    []Data_Row,
	order:   []u32,
	order_count: int,
	sort_col: int,
	sort_asc: bool,
	order_key: u64,
	selected_row: int,       // index in the display lines (group headers + rows), -1 = none
	selected_disp: Maybe(Disp),
	group_closed: [8]bool,   // per department
	disp_count, disp_groups: int,
	disp:      [dynamic]Disp,   // display lines cache (see build_display)
	disp_sums: [len(dept_names)]Group_Sum,
	disp_key:  u64,
	table_focus: bool,
	col_w:   [DATA_COLS]f32,
	tree_open: [32]bool,
	tree_sel: int,

	// playground
	balls:   [BALL_MAX]Ball,
	parts:   [PARTICLE_MAX]Particle,
	phys_run, repel, balls_seeded: bool,
	gravity, bounce: f32,
	arena_size: [2]f32,
	spin_angle, spin_omega, spin_prev: f32,
	notes:   [3]Note,
	note_order: [3]int,
	note_counter: int,
	spawn_next_ms: f64,
	pacer: render.Pacer,
	slept: bool,
}

Saved_Settings :: struct { palette, anim, status, toast_pos: i32, zoom, rounding, smoothing, density: f32, blending: i32 }

// xorshift: deterministic enough for a demo, no allocation
rng_state: u64 = 0x9e3779b97f4a7c15

rand_u64 :: proc() -> u64 {
	x := rng_state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	rng_state = x
	return x * 0x2545f4914f6cdd1d
}

rand01 :: proc() -> f32 { return f32((rand_u64() >> 40) & 0xffffff) / f32(0x1000000) }
rand_range :: proc(lo, hi: f32) -> f32 { return lo + (hi - lo) * rand01() }
