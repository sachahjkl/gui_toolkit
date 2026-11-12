package tk_prefs_page

// The preferences every program of the toolkit has, registered once here: the look (theme, light or dark, finish, text
// size) and the program on the desktop (in the application menu, started with the session). Their names are fixed: the
// programs' files already hold them, and the page knows them (Options.themes shows appearance.theme as cards).
//
//	d := prefs_page.STANDARD_DEFAULTS
//	d.theme, d.app_name = "cliche", "cliche"
//	prefs_page.standard_register(&prefs, {.Appearance, .Session}, d)
//	config.register(&prefs, PREF_DEFS[:])   // the program's own
//	a := prefs_page.appearance_read(&prefs); defer prefs_page.appearance_free(&a)
//	ui.theme_show(&theme, themes, prefs_page.appearance_choice(a), &shown, space)

import "core:fmt"
import "core:strings"
import config "../config"
import shortcuts "../shortcuts"
import "../ui"

Standard_Set :: enum u8 {
	Appearance,   // appearance.theme, appearance.mode, appearance.finish, appearance.font_size
	Session,      // general.menu, general.autostart
}
Standard :: bit_set[Standard_Set]

// The defaults of the standard preferences, and the program's name for their descriptions. Start from
// STANDARD_DEFAULTS: a zero `menu` is off.
Standard_Defaults :: struct {
	theme:     string,   // a name of the program's themes (a literal: the registry keeps it)
	mode:      string,   // "system", "dark" or "light" ("": "system")
	finish:    string,   // a name of ui.FINISH_NAMES ("": "machined")
	font_size: f32,      // in logical pixels (0: 14)
	menu:      bool,     // in the application menu
	autostart: bool,     // started with the session
	app_name:  string,   // "Start <app_name> with the session"
}

// The defaults a program changes only where it differs: its theme and its name.
STANDARD_DEFAULTS :: Standard_Defaults{mode = "system", finish = "machined", font_size = 14, menu = true}

THEME_PREF     :: "appearance.theme"
MODE_PREF      :: "appearance.mode"
FINISH_PREF    :: "appearance.finish"
FONT_SIZE_PREF :: "appearance.font_size"
MENU_PREF      :: "general.menu"
AUTOSTART_PREF :: "general.autostart"

FONT_SIZE_MIN :: 10
FONT_SIZE_MAX :: 24

// The finishes in the order the page shows them, the ones a program means first.
@(private = "file", rodata)
FINISH_CHOICES := [?]string{"machined", "edged", "flat", "gradient", "glass"}

@(private = "file", rodata)
MODE_CHOICES := [?]string{"system", "dark", "light"}

// (static: the registry keeps the slices of a Def)
@(private = "file", rodata) MENU_TAGS := [?]string{"launcher", "desktop file", "start menu", "icon"}
@(private = "file", rodata) AUTOSTART_TAGS := [?]string{"login", "startup", "boot", "session"}
@(private = "file", rodata) THEME_TAGS := [?]string{"colours", "colors", "palette", "dark", "light", "look"}
@(private = "file", rodata) MODE_TAGS := [?]string{"dark", "light", "night", "day"}
@(private = "file", rodata) FINISH_TAGS := [?]string{"style", "look", "bevel", "flat"}
@(private = "file", rodata) FONT_SIZE_TAGS := [?]string{"text size", "zoom", "bigger", "smaller"}

// Registers the standard preferences of `sets`, in the page's order (before the program's own: the page lists a
// category's preferences in the order they came). The descriptions that name `defaults.app_name` are made in
// `allocator` and must live as long as `prefs` (the registry keeps them, and frees no description): a program's
// registry lives as long as the program; a test gives an arena or the temporary allocator.
standard_register :: proc(prefs: ^config.Prefs, sets: Standard, defaults: Standard_Defaults, allocator := context.allocator) {
	d := defaults
	if d.mode == "" { d.mode = "system" }
	if d.finish == "" { d.finish = "machined" }
	if d.font_size <= 0 { d.font_size = 14 }
	name := d.app_name != "" ? d.app_name : "the program"
	a := allocator
	defs := make([dynamic]config.Def, context.temp_allocator)
	if .Session in sets {
		append(&defs, config.Def{
			name = MENU_PREF, title = "In the application menu", category = "general", kind = .Bool, default = {b = d.menu},
			description = fmt.aprintf("Put %s in the %s, with its icon. The desktop then knows %s by its name: its shortcuts and its windows' places come from that.", name, menu_words(), name, allocator = a),
			tags = MENU_TAGS[:],
		})
		append(&defs, config.Def{
			name = AUTOSTART_PREF, title = "Start with the session", category = "general", kind = .Bool, default = {b = d.autostart},
			description = fmt.aprintf("Start %s with the session, so that its shortcuts work from the start.", name, allocator = a),
			tags = AUTOSTART_TAGS[:],
		})
	}
	if .Appearance in sets {
		append(&defs, config.Def{
			name = THEME_PREF, title = "Theme", category = "appearance", kind = .String, default = {s = d.theme},
			description = fmt.aprintf("The colours of %s's windows.", name, allocator = a),
			tags = THEME_TAGS[:],
		})
		append(&defs, config.Def{
			name = MODE_PREF, title = "Light or dark", category = "appearance", kind = .String, default = {s = d.mode},
			description = "The theme's version: the system's (light or dark, followed as it changes), dark, or light.",
			choices = MODE_CHOICES[:], tags = MODE_TAGS[:],
		})
		append(&defs, config.Def{
			name = FINISH_PREF, title = "Finish", category = "appearance", kind = .String, default = {s = d.finish},
			description = "How surfaces are drawn. Machined: bevelled buttons, sunken fields, carved lines. Edged: the same reliefs, crisp, with square corners. Flat: plain surfaces and thin lines. Gradient: faces lit from the top. Glass: glossy faces.",
			choices = FINISH_CHOICES[:], tags = FINISH_TAGS[:],
		})
		append(&defs, config.Def{
			name = FONT_SIZE_PREF, title = "Text size", category = "appearance", kind = .Float, default = {f = f64(d.font_size)},
			description = "The size of the text, in logical pixels.", min = FONT_SIZE_MIN, max = FONT_SIZE_MAX, bounded = true, unit = "px",
			tags = FONT_SIZE_TAGS[:],
		})
	}
	// (the theme's default must outlive the registry, as every Def's: the program's literal)
	config.register(prefs, defs[:])
}

// The launcher's place in the user's words (gt:desktop's menu_name says the same; the page does not import it).
@(private = "file")
menu_words :: proc() -> string {
	when ODIN_OS == .Windows { return "Start menu" } else { return "application menu" }
}

// The look, as a program applies it.
Appearance :: struct {
	theme:     string,   // owned (appearance_free)
	mode:      ui.Theme_Mode,
	finish:    ui.Finish,
	font_size: f32,
}

// The look the registry holds now. A preference that is not registered reads as its standard default.
appearance_read :: proc(prefs: ^config.Prefs, allocator := context.allocator) -> (a: Appearance) {
	a.mode = .System
	a.finish = .Machined
	a.font_size = 14
	if r := config.ref_of(prefs, THEME_PREF); r != config.NO_REF { a.theme = strings.clone(config.get_string(prefs, r), allocator) }
	if r := config.ref_of(prefs, MODE_PREF); r != config.NO_REF { a.mode = ui.theme_mode_of(config.get_string(prefs, r)) }
	if r := config.ref_of(prefs, FINISH_PREF); r != config.NO_REF { a.finish = ui.finish_of(config.get_string(prefs, r)) }
	if r := config.ref_of(prefs, FONT_SIZE_PREF); r != config.NO_REF { a.font_size = f32(config.get_float(prefs, r)) }
	return
}

appearance_free :: proc(a: ^Appearance, allocator := context.allocator) {
	delete(a.theme, allocator)
	a^ = {}
}

// What ui.theme_show takes for the look (the machined finish's halos on).
appearance_choice :: proc(a: Appearance) -> ui.Theme_Choice {
	return {name = a.theme, mode = a.mode, finish = a.finish, glow = 1}
}

// Whether the user's value of `name` is not its default: the page shows its reset button then, and Restore defaults
// while one of the page's is. A value the command line or a policy decides is not the user's. `keys`: the value is a
// key combination, compared as keys ("ctrl+print" is "Ctrl+Print").
differs_from_default :: proc(prefs: ^config.Prefs, name: string, keys := false) -> bool {
	r := config.ref_of(prefs, name)
	if r == config.NO_REF { return false }
	e := config.entry(prefs, r)
	if e.source != .User { return false }
	value, default := config.value_string(prefs, r), config.default_string(prefs, r)
	if keys { return !shortcuts.same_keys(value, default) }
	return value != default
}
