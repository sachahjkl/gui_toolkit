// The palette's run mode and go to (src/md/features/everything-palette.md, layers 2 to 4): a setting's control in the
// palette, its value written at once and shown by the page in the same frame, Enter keeps it, Escape puts it back at
// each level; the row that runs is the item, not its place in a list made again; a locked setting shows its value and
// why; a command's form gives its values with the choice; Shift+Enter goes to a setting's line.
//   odin test tests/prefs_page -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package prefs_page_test

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
RUN_DEFS := [?]config.Def{
	{name = "look.theme", description = "The colours of the window.", kind = .String, default = {s = "Graphite"}, value_kind = .Theme},
	{name = "look.style", description = "How surfaces are drawn.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined", "glass"}},
	{name = "look.delay", description = "How long a tip waits.", kind = .Int, default = {i = 300}, bounded = true, min = 0, max = 2000, value_kind = .Duration},
	{name = "look.edge", description = "The colour of an edge.", kind = .String, default = {s = "#336699"}, value_kind = .Color},
	{name = "net.proxy", description = "Where the requests go.", kind = .String, default = {s = ""}},
	{name = "net.cache", description = "Keep a cache of the responses.", kind = .Bool, default = {b = true}},
}

@(private = "file")
RUN_PAGES := [?]prefs_page.Page_Info{{category = "look", title = "Look"}, {category = "net", title = "Network"}}
@(private = "file")
RUN_PAGES_NET_FIRST := [?]prefs_page.Page_Info{{category = "net", title = "Network"}, {category = "look", title = "Look"}}
@(private = "file")
RUN_PAGES_NET := [?]prefs_page.Page_Info{{category = "net", title = "Network"}}

// A command with a text argument and one with a closed list the program fills.
@(private = "file")
RENAME_ARGS := [?]config.Def{{name = "name", title = "Name", description = "The picture's new name.", kind = .String, default = {s = "Harbour"}}}
@(private = "file")
EXPORT_ARGS := [?]config.Def{
	{name = "name", title = "Name", kind = .String, default = {s = "picture"}},
	{name = "format", title = "Format", kind = .String, default = {s = "png"}},
}
// A command with one closed list the program fills (a model button's "Set the model"), and one with two closed lists.
@(private = "file")
CONVERT_ARGS := [?]config.Def{{name = "format", title = "Format", kind = .String, default = {s = "png"}}}
@(private = "file")
PACK_ARGS := [?]config.Def{
	{name = "format", title = "Format", kind = .String, default = {s = "png"}},
	{name = "quality", title = "Quality", kind = .String, default = {s = "high"}, choices = {"low", "high"}},
}
@(private = "file")
RUN_COMMANDS := [?]ui.Command{
	{id = "rename", label = "Rename the picture", group = "File", arguments = RENAME_ARGS[:]},
	{id = "export", label = "Export as", group = "File", arguments = EXPORT_ARGS[:]},
	{id = "convert", label = "Convert to", group = "File", arguments = CONVERT_ARGS[:]},
	{id = "pack", label = "Pack", group = "File", arguments = PACK_ARGS[:]},
}

@(private = "file", rodata) FORMAT_LABELS := [?]string{"PNG", "WebP", "JPEG"}
@(private = "file", rodata) FORMAT_VALUES := [?]string{"png", "webp", "jpeg"}
// (the program's list in another order: what a list changed during a form gives)
@(private = "file", rodata) FORMAT_LABELS_MOVED := [?]string{"JPEG", "PNG", "WebP"}
@(private = "file", rodata) FORMAT_VALUES_MOVED := [?]string{"jpeg", "png", "webp"}

@(private = "file")
Run_App :: struct {
	prefs:    config.Prefs,
	page:     prefs_page.Page,
	pal:      ui.Command_Palette,
	settings: prefs_page.Palette_Settings,
	pages:    []prefs_page.Page_Info,
	shown:    bool,            // the settings page is built
	show:     bool,            // open the palette in the next build
	typed:    string,
	opened:   int,             // the times the source asked to show the settings
	commands: bool,            // the commands source too
	chosen:   string,          // the last command chosen, and its values
	values:   [dynamic]string,
	// the value of look.theme at the end of each frame (before palette_chosen) and as the page drew it: a frame whose
	// two differ showed one value in the palette and another on the page
	page_saw: string,
	split:    int,
	changed:  int,
	// the program's state the forms read: the picture's name (Rename's start; "": none), the formats' list now, the
	// times the list was asked for
	title:    string,
	moved:    bool,
	choices_read: int,
	// a form the program opens in the next build (palette_open_form), and what the call answered
	open_form: string,
	form_opened: Maybe(bool),
}

@(private = "file")
run_options :: proc(user: rawptr) -> prefs_page.Page_Options {
	app := (^Run_App)(user)
	return {pages = app.pages, user = app, themes = ui.THEMES[:4], changed = proc(user: rawptr, name: string) { (^Run_App)(user).changed += 1 }}
}

@(private = "file")
run_build :: proc(s: ^session.Session) {
	app := (^Run_App)(s.user)
	if app.commands {
		ui.palette_commands(&app.pal, RUN_COMMANDS[:], nil, {
			user = app,
			choices = proc(user: rawptr, index: int, argument: string) -> (labels, values: []string) {
				if argument != "format" { return nil, nil }
				app := (^Run_App)(user)
				app.choices_read += 1
				if app.moved { return FORMAT_LABELS_MOVED[:], FORMAT_VALUES_MOVED[:] }
				return FORMAT_LABELS[:], FORMAT_VALUES[:]
			},
			initial = proc(user: rawptr, index: int, argument: string, allocator: runtime.Allocator) -> (value: string, ok: bool) {
				app := (^Run_App)(user)
				if RUN_COMMANDS[index].id != "rename" || argument != "name" || app.title == "" { return "", false }
				return strings.clone(app.title, allocator), true
			},
		})
	}
	ui.palette_keys(&app.pal)
	if app.show { app.show = false; ui.palette_open(&app.pal, app.typed) }
	if app.open_form != "" {
		app.form_opened = ui.palette_open_form(&app.pal, app.open_form)
		app.open_form = ""
	}
	// (what the last frame showed in the palette, its view built after the page: the page must have drawn the same)
	theme := config.ref_of(&app.prefs, "look.theme") != config.NO_REF
	if theme && app.shown && app.page_saw != "" && config.string_of(&app.prefs, "look.theme") != app.page_saw { app.split += 1 }
	if c, ok := ui.palette_chosen(&app.pal); ok {
		if i, is := ui.palette_chosen_command(&app.pal, c); is {
			app.chosen = RUN_COMMANDS[i].id
			for v in app.values { delete(v) }
			clear(&app.values)
			for a in c.arguments { append(&app.values, strings.clone(a)) }
		}
	}
	if !app.shown { return }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, run_options(app))
	if theme {
		delete(app.page_saw)
		app.page_saw = strings.clone(config.string_of(&app.prefs, "look.theme"))
	}
}

@(private = "file")
run_start :: proc(t: ^testing.T, app: ^Run_App, defs: []config.Def = nil) -> ^session.Session {
	app.prefs = config.prefs_make()
	config.register(&app.prefs, defs != nil ? defs : RUN_DEFS[:])
	if app.pages == nil { app.pages = RUN_PAGES[:] }
	prefs_page.palette_settings_add(&app.pal, &app.settings, &app.prefs, &app.page, run_options, proc(user: rawptr) {
		app := (^Run_App)(user)
		app.opened += 1
		app.shown = true
	}, app)
	return session.start(t, {size = {1200, 700}, build = run_build, user = app})
}

@(private = "file")
run_end :: proc(app: ^Run_App) {
	ui.palette_destroy(&app.pal)
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
	delete(app.page_saw)
	for v in app.values { delete(v) }
	delete(app.values)
}

// The palette opened on `typed`, its first row `id` once ranked.
@(private = "file")
run_open_on :: proc(s: ^session.Session, app: ^Run_App, typed, id: string) {
	app.show, app.typed = true, typed
	Want :: struct { app: ^Run_App, id: string }
	w := Want{app, id}
	session.wait_until(s, &w, proc(s: ^session.Session, w: ^Want) -> bool {
		// (opened first: the list a form's close left is still `shown`, and a key pressed before the build that opens
		// the palette would reach it before its field has the focus)
		if w.app.show { return false }
		_, first, ok := ui.palette_row(&w.app.pal, 0)
		return !ui.palette_busy(&w.app.pal) && ok && first == w.id
	}, fmt.tprintf("%s first", id))
}

@(private = "file")
run_level_is :: proc(s: ^session.Session, app: ^Run_App, level: ui.Palette_Run_Level) {
	Want :: struct { app: ^Run_App, level: ui.Palette_Run_Level }
	w := Want{app, level}
	session.wait_until(s, &w, proc(s: ^session.Session, w: ^Want) -> bool { return ui.palette_run_level(&w.app.pal) == w.level }, fmt.tprintf("the run mode %v", level))
}

// Day-one test 1: the settings page open beside the palette, a theme changed in the run mode shows on the page in the
// same frame as in the palette; Escape puts the page back too, and a default comes back as the default.
@(test)
a_theme_changed_in_the_palette_shows_on_the_page_in_the_same_frame :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.shown = true
	s := run_start(t, &app)
	run_open_on(s, &app, ":theme", "look.theme")
	testing.expect(t, session.find_text(s, "Graphite") != nil, "its value at its row's right")
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	testing.expect(t, ui.palette_is_open(&app.pal), "the palette stays")
	testing.expect_value(t, app.opened, 0)
	session.key(s, .Down)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return config.string_of(&app.prefs, "look.theme") != "Graphite" }, "the next theme, at once")
	moved := strings.clone(config.string_of(&app.prefs, "look.theme"), context.temp_allocator)
	testing.expect_value(t, moved, ui.THEMES[3].name)   // (Graphite is the third of the four)
	session.frames(s, 3)
	testing.expect_value(t, app.page_saw, moved)
	session.key(s, .Escape)
	run_level_is(s, &app, .Closed)
	session.frames(s, 3)
	testing.expect_value(t, config.string_of(&app.prefs, "look.theme"), "Graphite")
	testing.expect(t, config.is_default(&app.prefs, config.ref_of(&app.prefs, "look.theme")), "the default again, not a value of the user's")
	testing.expect_value(t, app.page_saw, "Graphite")
	testing.expect_value(t, app.split, 0)
	testing.expect(t, ui.palette_is_open(&app.pal), "Escape stepped back to the list, the palette stays")
}

// Day-one test 2: Enter on an unfolded row while its source's table is made again (another order of its pages) acts on
// the same setting, never on the row that took its place; its item gone, the run mode closes.
@(test)
the_row_that_runs_is_its_item :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	s := run_start(t, &app)
	app.show, app.typed = true, ":"
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return !ui.palette_busy(&app.pal) && ui.palette_row_count(&app.pal) == 6 }, "the six settings")
	_, first, _ := ui.palette_row(&app.pal, 0)
	testing.expect_value(t, first, "look.theme")
	session.key(s, .Down)   // (look.style)
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	_, id, _, _ := ui.palette_run_item(&app.pal)
	testing.expect_value(t, id, "look.style")
	// the table made again: the Network page first, another setting where look.style's row was
	app.pages = RUN_PAGES_NET_FIRST[:]
	app.settings.source.version += 1
	rankings := app.pal.rankings
	Want :: struct { app: ^Run_App, rankings: int }
	w := Want{&app, rankings}
	session.wait_until(s, &w, proc(s: ^session.Session, w: ^Want) -> bool {
		return !ui.palette_busy(&w.app.pal) && w.app.pal.rankings > w.rankings
	}, "the list made again")
	moved := false
	for i in 0 ..< ui.palette_row_count(&app.pal) {
		if _, row, _ := ui.palette_row(&app.pal, i); row == "net.proxy" { moved = i < 2 }
	}
	testing.expect(t, moved, "another setting in the first rows")
	testing.expect_value(t, ui.palette_run_level(&app.pal), ui.Palette_Run_Level.Control)
	session.key(s, .Down)
	session.key(s, .Return)
	run_level_is(s, &app, .Closed)
	testing.expect_value(t, config.string_of(&app.prefs, "look.style"), "machined")
	testing.expect_value(t, config.string_of(&app.prefs, "net.proxy"), "")
	// its item gone: closed, nothing put back
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	_, id, _, _ = ui.palette_run_item(&app.pal)
	session.key(s, .Down)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return config.string_of(&app.prefs, "look.style") == "glass" }, "glass written")
	app.pages = RUN_PAGES_NET[:]
	app.settings.source.version += 1
	run_level_is(s, &app, .Closed)
	testing.expect_value(t, config.string_of(&app.prefs, "look.style"), "glass")
	testing.expect(t, ui.palette_is_open(&app.pal), "the palette stays")
}

// A value another path wrote meanwhile wins: Escape leaves it.
@(test)
escape_leaves_a_value_written_by_another_path :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	s := run_start(t, &app)
	run_open_on(s, &app, ":style", "look.style")
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	session.key(s, .Down)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return config.string_of(&app.prefs, "look.style") == "machined" }, "machined")
	_ = config.set_from_string(&app.prefs, "look.style", "glass", .User)   // (a sync, the page)
	session.key(s, .Escape)
	run_level_is(s, &app, .Closed)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, "look.style"), "glass")
}

// A value typed: the field holds the value's text with its unit; Enter writes it, a refused one stays with its reason;
// a duration steps with Up.
@(test)
a_typed_value_is_kept_or_refused :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	s := run_start(t, &app)
	run_open_on(s, &app, ":delay", "look.delay")
	testing.expect(t, session.find_text(s, "300 ms") != nil, "its value at its row's right")
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "300 ms")
	session.key(s, .Up)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return config.int_of(&app.prefs, "look.delay") == 301 }, "a step")
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "301 ms")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "9 h")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return ui.palette_run_error(&app.pal) != "" }, "refused")
	testing.expect_value(t, ui.palette_run_level(&app.pal), ui.Palette_Run_Level.Control)
	testing.expect_value(t, config.int_of(&app.prefs, "look.delay"), 301)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "1.5 s")
	session.key(s, .Return)
	run_level_is(s, &app, .Closed)
	testing.expect_value(t, config.int_of(&app.prefs, "look.delay"), 1500)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), ":delay")
}

@(private = "file")
PATH_DEFS := [?]config.Def{
	{name = "net.folder", description = "Where the downloads go.", kind = .String, default = {s = ""}, value_kind = .Path},
}

// A path completes (everything-palette.md, "A path completes"): the folder typed is read on a chore, its entries that
// start with the last part are listed, folders first; Tab puts the one selected in the field with its separator; Enter
// keeps the text.
@(test)
a_path_completes_with_tab :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "palette_path")
	for d in ([]string{"alpha", "albums", "beta"}) { _ = os.make_directory(fmt.tprintf("%s/%s", dir, d)) }
	_ = os.write_entire_file(fmt.tprintf("%s/apple.txt", dir), transmute([]u8)string("x"))
	app: Run_App
	defer run_end(&app)
	app.pages = RUN_PAGES_NET[:]
	s := run_start(t, &app, PATH_DEFS[:])
	run_open_on(s, &app, ":folder", "net.folder")
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	session.type_text(s, fmt.tprintf("%s/al", dir))
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "albums") != nil && session.find_text(s, "alpha") != nil }, "the folder's entries that start with al")
	testing.expect(t, session.find_text(s, "beta") == nil, "none that does not")
	sep := ODIN_OS == .Windows ? "\\" : "/"
	session.key(s, .Tab)
	session.frames(s, 2)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), fmt.tprintf("%s/albums%s", dir, sep))   // (folders first, by name)
	session.key(s, .Return)
	run_level_is(s, &app, .Closed)
	testing.expect_value(t, config.string_of(&app.prefs, "net.folder"), fmt.tprintf("%s/albums%s", dir, sep))
}

// A locked setting (the command line) shows its value and why, and opens no control.
@(test)
a_locked_setting_shows_its_value_and_why :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	s := run_start(t, &app)
	_ = config.set_from_string(&app.prefs, "net.proxy", "http://proxy:3128", .Command_Line)
	run_open_on(s, &app, ":proxy", "net.proxy")
	testing.expect(t, session.find_text(s, "http://proxy:3128") != nil, "its value")
	testing.expect(t, session.find_text(s, "Set on the command line for this run.") != nil, "why")
	session.key(s, .Return)
	session.frames(s, 3)
	testing.expect_value(t, ui.palette_run_level(&app.pal), ui.Palette_Run_Level.Closed)
	testing.expect_value(t, config.string_of(&app.prefs, "net.proxy"), "http://proxy:3128")
}

// A command's form: Enter opens it at its first argument, each argument with its control (a text, a closed list the
// program fills); Escape steps back one argument, then to the list, then closes; Enter on the last gives the choice
// with the values.
@(test)
a_command_s_form_gives_its_values :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	s := run_start(t, &app)
	run_open_on(s, &app, ">export", "export")
	session.key(s, .Return)
	run_level_is(s, &app, .Form)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "picture")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "Harbour at dusk")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { _, _, arg, _ := ui.palette_run_item(&app.pal); return arg == 1 }, "the second argument")
	testing.expect(t, session.find_text(s, "WebP") != nil, "the program's choices")
	// Escape: the first argument again, what was typed kept
	session.key(s, .Escape)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { _, _, arg, _ := ui.palette_run_item(&app.pal); return arg == 0 }, "back to the first")
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "Harbour at dusk")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { _, _, arg, _ := ui.palette_run_item(&app.pal); return arg == 1 }, "the second argument again")
	session.key(s, .Down)
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "export" }, "the command chosen")
	testing.expect_value(t, len(app.values), 2)
	if len(app.values) == 2 {
		testing.expect_value(t, app.values[0], "Harbour at dusk")
		testing.expect_value(t, app.values[1], "webp")
	}
	session.frames(s, 2)
	testing.expect(t, !ui.palette_is_open(&app.pal), "the palette closed")

	// Escape at each level: the argument, the list, the palette
	app.chosen = ""
	run_open_on(s, &app, ">rename", "rename")
	session.key(s, .Return)
	run_level_is(s, &app, .Form)
	session.key(s, .Escape)
	run_level_is(s, &app, .Closed)
	testing.expect(t, ui.palette_is_open(&app.pal), "the list again")
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), ">rename")
	session.key(s, .Escape)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return !ui.palette_is_open(&app.pal) }, "closed")
	testing.expect_value(t, app.chosen, "")
}

@(private = "file")
run_arg_is :: proc(s: ^session.Session, app: ^Run_App, arg: int) {
	Want :: struct { app: ^Run_App, arg: int }
	w := Want{app, arg}
	session.wait_until(s, &w, proc(s: ^session.Session, w: ^Want) -> bool {
		_, _, arg, ok := ui.palette_run_item(&w.app.pal)
		return ok && arg == w.arg
	}, fmt.tprintf("argument %d", arg))
}

// A form the program opens (a button): the palette opens on its first argument, what is typed and Enter give the
// choice; Escape at the first argument closes the palette, there being no list it came from. An unknown command, or
// one without arguments, opens nothing.
@(test)
a_form_opened_by_the_program_runs_and_escape_closes :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	s := run_start(t, &app)
	session.frames(s, 2)
	app.open_form = "rename"
	run_level_is(s, &app, .Form)
	opened, asked := app.form_opened.?
	testing.expect(t, asked && opened, "palette_open_form answered true")
	testing.expect(t, ui.palette_is_open(&app.pal), "the palette open")
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "Harbour")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "Quay")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "rename" }, "the command chosen")
	testing.expect_value(t, len(app.values), 1)
	if len(app.values) == 1 { testing.expect_value(t, app.values[0], "Quay") }
	session.frames(s, 2)
	testing.expect(t, !ui.palette_is_open(&app.pal), "the palette closed")

	// Escape at the first argument: the palette closes, nothing chosen
	app.chosen = ""
	app.open_form = "export"
	run_level_is(s, &app, .Form)
	session.key(s, .Return)
	run_arg_is(s, &app, 1)
	session.key(s, .Escape)
	run_arg_is(s, &app, 0)
	testing.expect(t, ui.palette_is_open(&app.pal), "a later argument steps back")
	session.key(s, .Escape)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return !ui.palette_is_open(&app.pal) }, "closed")
	testing.expect_value(t, ui.palette_run_level(&app.pal), ui.Palette_Run_Level.Closed)
	testing.expect_value(t, app.chosen, "")

	// refused: the palette stays closed
	app.form_opened = nil
	app.open_form = "no_such_command"
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.form_opened != nil }, "asked")
	opened, _ = app.form_opened.?
	testing.expect(t, !opened, "palette_open_form answered false")
	session.frames(s, 2)
	testing.expect(t, !ui.palette_is_open(&app.pal), "nothing opened")
}

// A form starts on the program's value now (Palette_Commands_Options.initial), read when it opens: the program's
// state changed between two opens gives the new value; with none, the argument's default.
@(test)
a_form_starts_on_the_program_s_value :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	app.title = "Harbour at dusk"
	s := run_start(t, &app)
	session.frames(s, 2)
	app.open_form = "rename"
	run_level_is(s, &app, .Form)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "Harbour at dusk")
	session.key(s, .Escape)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return !ui.palette_is_open(&app.pal) }, "closed")
	// the program's state changed: the next form, opened from the list, starts on it
	app.title = "Quay"
	run_open_on(s, &app, ">rename", "rename")
	session.key(s, .Return)
	run_level_is(s, &app, .Form)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "Quay")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "rename" }, "the command chosen")
	if len(app.values) == 1 { testing.expect_value(t, app.values[0], "Quay") }
	// none: the default
	app.title, app.chosen = "", ""
	app.open_form = "rename"
	run_level_is(s, &app, .Form)
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), "Harbour")
}

// A step's closed list is read once when the step opens, not at each build; a list the program changes during the
// step keeps the rows shown (the row selected writes the value it showed); the step opened again reads the new list.
@(test)
a_step_reads_its_choices_once :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	s := run_start(t, &app)
	run_open_on(s, &app, ">export", "export")
	session.key(s, .Return)
	run_level_is(s, &app, .Form)
	session.key(s, .Return)
	run_arg_is(s, &app, 1)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "WebP") != nil }, "the program's choices")
	session.frames(s, 10)
	testing.expect_value(t, app.choices_read, 1)
	// the program's list changes under the open step: its rows stay, PNG selected, WebP under it
	app.moved = true
	session.frames(s, 5)
	testing.expect_value(t, app.choices_read, 1)
	session.key(s, .Down)
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "export" }, "the command chosen")
	if len(app.values) == 2 { testing.expect_value(t, app.values[1], "webp") }
	// the step opened again: the new list, read once more
	app.chosen = ""
	run_open_on(s, &app, ">export", "export")
	session.key(s, .Return)
	run_level_is(s, &app, .Form)
	session.key(s, .Return)
	run_arg_is(s, &app, 1)
	session.frames(s, 10)
	testing.expect_value(t, app.choices_read, 2)
	session.key(s, .Down)   // (png, the default, is the second row now: jpeg, png, webp)
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "export" }, "the command chosen again")
	if len(app.values) == 2 { testing.expect_value(t, app.values[1], "webp") }
}

// A click on a row of a form's closed list is Enter on it (everything-palette.md, "A click on a row is Enter on it"):
// on the only argument the command runs with that row and the palette closes; on the first of two, the form steps to
// the second. A double click acts once: its second click, on the next argument's row now under the pointer, chooses
// nothing.
@(test)
a_click_on_a_form_s_row_keeps_it_and_steps_on :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	s := run_start(t, &app)
	session.frames(s, 2)
	app.open_form = "convert"
	run_level_is(s, &app, .Form)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "WebP") != nil }, "the program's choices")
	session.click_text(s, "WebP")
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "convert" }, "the command run by the click")
	testing.expect_value(t, len(app.values), 1)
	if len(app.values) == 1 { testing.expect_value(t, app.values[0], "webp") }
	session.frames(s, 2)
	testing.expect(t, !ui.palette_is_open(&app.pal), "the palette closed")

	// two arguments: a click on the first's row steps to the second
	app.chosen = ""
	app.open_form = "pack"
	run_level_is(s, &app, .Form)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "WebP") != nil }, "the first argument's choices")
	session.click_text(s, "WebP")
	run_arg_is(s, &app, 1)
	testing.expect(t, ui.palette_is_open(&app.pal), "the form goes on")
	testing.expect_value(t, app.chosen, "")
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "Low") != nil }, "the second argument's choices")
	session.click_text(s, "Low")
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return app.chosen == "pack" }, "the command run by the second click")
	testing.expect_value(t, len(app.values), 2)
	if len(app.values) == 2 {
		testing.expect_value(t, app.values[0], "webp")
		testing.expect_value(t, app.values[1], "low")
	}

	// a double click on the first's row: the second argument, and nothing chosen by its second click (WebP's row is
	// the second, as High's is under it now)
	app.chosen = ""
	session.frames(s, 2)
	app.open_form = "pack"
	run_level_is(s, &app, .Form)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "WebP") != nil }, "the choices again")
	session.click_text(s, "WebP", count = 2)
	run_arg_is(s, &app, 1)
	session.frames(s, 3)
	testing.expect_value(t, app.chosen, "")
	testing.expect(t, ui.palette_is_open(&app.pal), "the second click ran nothing")
	testing.expect_value(t, ui.palette_run_level(&app.pal), ui.Palette_Run_Level.Form)
}

// A click on a row of a setting's list is Enter on it: the value written and kept, the list again, the palette open.
@(test)
a_click_on_a_setting_s_row_keeps_it :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	s := run_start(t, &app)
	run_open_on(s, &app, ":style", "look.style")
	session.key(s, .Return)
	run_level_is(s, &app, .Control)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return session.find_text(s, "Glass") != nil }, "its choices")
	session.click_text(s, "Glass")
	run_level_is(s, &app, .Closed)
	testing.expect_value(t, config.string_of(&app.prefs, "look.style"), "glass")
	testing.expect(t, ui.palette_is_open(&app.pal), "the palette stays, on its list")
	testing.expect_value(t, ui.line_edit_string(&app.pal.field), ":style")
}

// Go to: Shift+Enter on a setting shows the settings on its page, its line scrolled into view, focused and lit; the
// hint row offers it only where it can be done.
@(test)
shift_enter_goes_to_a_setting :: proc(t: ^testing.T) {
	app: Run_App
	defer run_end(&app)
	app.commands = true
	// (a long page: the setting is far below the fold)
	defs := make([dynamic]config.Def, context.temp_allocator)
	for i in 0 ..< 40 { append(&defs, config.Def{name = fmt.tprintf("net.item%02d", i), description = "A line.", kind = .Bool}) }
	append(&defs, config.Def{name = "net.proxy", description = "Where the requests go.", kind = .String, default = {s = ""}})
	app.pages = RUN_PAGES_NET[:]
	s := run_start(t, &app, defs[:])
	run_open_on(s, &app, ":proxy", "net.proxy")
	testing.expect(t, session.find_text(s, "Go to") != nil, "the hint row offers go to")
	session.key(s, .Return, {.Shift})
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Run_App) -> bool { return s.state.act_light.key != 0 }, "lit")
	testing.expect_value(t, app.opened, 1)
	testing.expect(t, !ui.palette_is_open(&app.pal), "the palette closed")
	testing.expect_value(t, app.page.current, "net")
	testing.expect(t, ui.act_shown("setting:net.proxy"), "its line shown")
	line := s.state.boxes[s.state.act_light.key]
	testing.expect(t, line != nil && line.name == "set_net.proxy", "its line lit")
	focus := s.state.boxes[s.state.focus_key] or_else nil
	in_line := false
	for a := focus; a != nil; a = a.parent { if a == line { in_line = true } }
	testing.expect(t, in_line, "the focus in its line")
	session.frames(s, 20)
	testing.expect(t, line.rect.max.y <= 700 && line.rect.min.y >= 0, "scrolled into view")
	// (the light stands off the line: a ring on the line's own edge touched its words)
	if s.state.act_light.key != 0 {
		img := session.capture(s)
		out := math.round(f32(line.font_size * ui.ACT_LIGHT_OUTSET))
		y := int((line.rect.min.y + line.rect.max.y) / 2)
		ring := session.pixel(img, int(line.rect.min.x - out) + 1, y)
		page := session.pixel(img, int(line.rect.min.x - out) - 12, y)
		edge := session.pixel(img, int(line.rect.min.x) + 1, y)       // (the wash, not a ring: the same as further in)
		further := session.pixel(img, int(line.rect.min.x) + 6, y)
		testing.expectf(t, !session.near(ring, page, 12), "the ring outside the line: %v against the page's %v", ring, page)
		testing.expectf(t, session.near(edge, further, 6), "no ring on the line's own edge: %v against %v", edge, further)
	}
	// a command no frame shows: no go to
	run_open_on(s, &app, ">rename", "rename")
	testing.expect(t, session.find_text(s, "Go to") == nil, "no go to offered")
}
