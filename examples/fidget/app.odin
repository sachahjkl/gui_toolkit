// fidget: a widget gallery built on gui_toolkit. Four pages (Controls, Inputs, Data, Playground), a command palette,
// menus, toasts, a modal dialog, six themes, persisted settings. Every widget here comes from the `ui` package.
package fidget

import "core:time"
import "../../draw"
import "../../font"
import "../../platform"
import "../../render"
import "../../ui"

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

Named_Palette :: struct { name: string, palette: ui.Palette }

palettes := [?]Named_Palette{
	{"Midnight", ui.PALETTE_MIDNIGHT},
	{"Graphite", {bg = 0x151515ff, panel = 0x1e1e1eff, panel2 = 0x2a2a2aff, text = 0xeaeaeaff, weak = 0x8e8e8eff, border = 0x353535ff, accent = 0x4cc2ffff, accent_text = 0x06222fff, good = 0x5dd39eff, warn = 0xf4c95dff, bad = 0xff6b6bff, dark = true}},
	{"Daylight", ui.PALETTE_DAYLIGHT},
	{"Nord", {bg = 0x2e3440ff, panel = 0x3b4252ff, panel2 = 0x434c5eff, text = 0xeceff4ff, weak = 0x9aa5b8ff, border = 0x4c566aff, accent = 0x88c0d0ff, accent_text = 0x1d2430ff, good = 0xa3be8cff, warn = 0xebcb8bff, bad = 0xbf616aff, dark = true}},
	{"Dracula", {bg = 0x1e1f29ff, panel = 0x282a36ff, panel2 = 0x343746ff, text = 0xf8f8f2ff, weak = 0x9aa0c8ff, border = 0x44475aff, accent = 0xbd93f9ff, accent_text = 0x1a1326ff, good = 0x50fa7bff, warn = 0xf1fa8cff, bad = 0xff5555ff, dark = true}},
	{"Amber", {bg = 0x16120bff, panel = 0x201a10ff, panel2 = 0x2d2415ff, text = 0xffe9c2ff, weak = 0xb59a66ff, border = 0x3d311cff, accent = 0xffb000ff, accent_text = 0x1a1200ff, good = 0x9acd32ff, warn = 0xffd54fff, bad = 0xff7043ff, dark = true}},
}

////////////////////////////////
// Commands: one enum + one table drive the palette, the menus and the shortcuts

Command :: enum {
	Go_Controls, Go_Inputs, Go_Data, Go_Playground,
	Theme_Midnight, Theme_Graphite, Theme_Daylight, Theme_Nord, Theme_Dracula, Theme_Amber, Next_Theme,
	Toggle_Status, Toggle_Animations, Anim_System, Anim_On, Anim_Off, Toggle_Slowmo, Toggle_Boxes,
	Toast_Info, Toast_Good, Toast_Warn, Toast_Bad, Clear_Toasts, Open_Modal, About, Settings,
	Spawn_Balls, Confetti, Clear_Balls, Reset_Values,
	Zoom_In, Zoom_Out, Zoom_Reset,
	Quit,
}

Command_Info :: struct { title, category, shortcut, icon: string }

command_info := [Command]Command_Info{
	.Go_Controls = {"Go to Controls", "Navigate", "Ctrl+1", ICON_GEAR},
	.Go_Inputs = {"Go to Inputs", "Navigate", "Ctrl+2", ICON_PENCIL},
	.Go_Data = {"Go to Data", "Navigate", "Ctrl+3", ICON_LIST},
	.Go_Playground = {"Go to Playground", "Navigate", "Ctrl+4", ICON_CUBE},
	.Theme_Midnight = {"Theme: Midnight", "Theme", "", ICON_PALETTE},
	.Theme_Graphite = {"Theme: Graphite", "Theme", "", ICON_PALETTE},
	.Theme_Daylight = {"Theme: Daylight", "Theme", "", ICON_PALETTE},
	.Theme_Nord = {"Theme: Nord", "Theme", "", ICON_PALETTE},
	.Theme_Dracula = {"Theme: Dracula", "Theme", "", ICON_PALETTE},
	.Theme_Amber = {"Theme: Amber", "Theme", "", ICON_PALETTE},
	.Next_Theme = {"Theme: Cycle next", "Theme", "Ctrl+T", ICON_REFRESH},
	.Toggle_Status = {"View: Toggle status bar", "View", "Ctrl+B", ICON_WINDOW},
	.Toggle_Animations = {"View: Toggle animations", "View", "Ctrl+J", ui.ICON_RADIO_ON},
	.Anim_System = {"View: Animations follow system setting", "View", "", ICON_PAUSE},
	.Anim_On = {"View: Animations always on", "View", "", ICON_PAUSE},
	.Anim_Off = {"View: Animations always off", "View", "", ICON_PAUSE},
	.Toggle_Slowmo = {"View: Slow-motion animations", "View", "", ICON_PAUSE},
	.Toggle_Boxes = {"View: Count UI boxes in the status bar", "View", "", ICON_GRID},
	.Toast_Info = {"Toast: Info", "Feedback", "", ui.ICON_INFO},
	.Toast_Good = {"Toast: Success", "Feedback", "", ui.ICON_CHECK},
	.Toast_Warn = {"Toast: Warning", "Feedback", "", ui.ICON_WARN},
	.Toast_Bad = {"Toast: Error", "Feedback", "", ui.ICON_WARN_BIG},
	.Clear_Toasts = {"Toast: Dismiss all", "Feedback", "", ui.ICON_X},
	.Open_Modal = {"Dialog: Open confirm dialog", "Feedback", "", ICON_QUESTION},
	.About = {"Help: About gui_toolkit fidget", "General", "F1", ui.ICON_INFO},
	.Settings = {"Settings...", "General", "Ctrl+,", ICON_GEAR},
	.Spawn_Balls = {"Playground: Spawn 25 balls", "Playground", "", ICON_DOT},
	.Confetti = {"Playground: Confetti", "Playground", "", ICON_TARGET},
	.Clear_Balls = {"Playground: Clear balls", "Playground", "", ICON_TRASH},
	.Reset_Values = {"Reset all widget values", "General", "", ICON_UNDO},
	.Zoom_In = {"View: Zoom in", "View", "Ctrl +", ui.ICON_ADD},
	.Zoom_Out = {"View: Zoom out", "View", "Ctrl -", ui.ICON_MINUS},
	.Zoom_Reset = {"View: Reset zoom", "View", "Ctrl 0", ui.ICON_MINUS},
	.Quit = {"Quit", "General", "Alt+F4", ICON_STOP},
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
	win:      ^platform.Window,
	r:        render.Renderer,
	fonts:    font.State,
	dc:       draw.Context,
	ui_state: ui.State,
	theme:    ui.Theme,
	ui_font, mono, icons: font.Font_Id,
	last_tick: time.Tick,
	frames_requested: int,
	frame_index: u64,
	title_cache: string,
	debug_dump: bool,
	debug_toasts: bool,
	want_quit: bool,
	ui_ms: f32,
	real_dt: f32,
	ms_hist: [64]f32,
	ms_idx: int,

	// settings (persisted)
	palette_idx: int,
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

	// overlays
	palette_open: bool,
	palette_field: ui.Text_Field,
	palette_sel, palette_scroll: int,
	palette_focus: bool,
	palette_mouse: [2]f32,
	palette_frames: int,
	modal_open:   bool,
	about_open:   bool,
	settings_open: bool,

	// controls page
	sw:      [3]bool,
	chk:     [3]bool,
	radio_sel: int,
	slider:  [3]f32,
	range_lo, range_hi: f32,
	stepper: int,
	seg:     int,
	chips:   u32,
	dd:      [2]int,
	rating:  int,
	progress: f32,
	progress_run: bool,
	ctx_check: bool,

	// inputs page
	name, email, number, search, tag_input, bio, filter: ui.Text_Field,
	tags:    [dynamic]string,
	agree:   bool,

	// data page
	rows:    []Data_Row,
	order:   []u32,
	order_count: int,
	sort_col: int,
	sort_asc: bool,
	order_key: u64,
	selected_row: int,
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
}

Saved_Settings :: struct { palette, anim, status, toast_pos: i32, zoom: f32 }

Palette_Entry :: struct { cmd: Command, ranges: []ui.Fuzzy_Range }

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
