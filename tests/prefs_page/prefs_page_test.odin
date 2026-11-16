// The settings page of a program's preferences (prefs_page): the search keeps what matches, a switch flips and resets,
// a choice is chosen, a field refuses a value out of range with its reason and takes a good one, a page is shown; the
// program hears of each change.
//   odin test tests/prefs_page -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package prefs_page_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"
import update "gt:update"

@(private = "file")
DEFS := [?]config.Def{
	{name = "net.cache", description = "Keep a cache of the responses.", kind = .Bool, default = {b = true}},
	{name = "net.max_body", description = "The largest response kept.", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 100 << 10, value_kind = .Size, unit = .Kibibyte},
	{name = "net.timeout", description = "How long an answer may take.", kind = .Int, default = {i = 300}, bounded = true, min = 0, max = 5000, value_kind = .Duration},
	{name = "net.mirror", description = "Where the copies are fetched.", kind = .String, default = {s = "https://example.org/"}, value_kind = .Address},
	{name = "look.style", description = "How surfaces are drawn.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined"}},
	{name = "look.zoom", description = "How large the interface is drawn.", kind = .Float, default = {f = 1}, bounded = true, min = 0.5, max = 2},
	{name = "look.shade", description = "How dark the screen is around a choice.", kind = .Float, default = {f = 0.45}, bounded = true, min = 0, max = 0.9, value_kind = .Fraction},
	{name = "look.keys", description = "What shows the window.", kind = .String, default = {s = "Ctrl+Shift+U"}, value_kind = .Keys},
	{name = "net.window_size", description = "The size the window was given.", kind = .String, default = {s = ""}, hidden = true},
}

@(private = "file")
PAGES := [?]prefs_page.Page_Info{{category = "net", title = "Network"}, {category = "gone", title = "Nothing here"}, {category = "look", title = "Look"}}

@(private = "file")
App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	changed: [dynamic]string,
	updater: ^update.Updater,
	preview: f64,   // the last value a held slider showed (Page_Options.preview)
	closed:  bool,  // the settings closed: the page is not built
}

@(private = "file")
app_build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	if app.closed { return }
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, {user = app, version = "Sample 1.2.3", pages = PAGES[:], updater = app.updater, update_pref = "net.cache", problem = proc(user: rawptr, name: string) -> string {
		return name == "look.keys" && config.string_of(&(^App)(user).prefs, "look.keys") == "Ctrl+Alt+Delete" ? "Windows holds it" : ""
	}, changed = proc(user: rawptr, name: string) {
		app := (^App)(user)
		append(&app.changed, strings.clone(name))
	}, preview = proc(user: rawptr, name: string, value: f64) {
		if name == "look.zoom" { (^App)(user).preview = value }
	}})
}

@(private = "file")
app_start :: proc(t: ^testing.T, app: ^App, query := "") -> ^session.Session {
	app.prefs = config.prefs_make()
	config.register(&app.prefs, DEFS[:])
	prefs_page.focus_search(&app.page)
	s := session.start(t, {size = {1200, 700}, build = app_build, user = app})
	if query != "" { session.type_text(s, query) }
	return s
}

@(private = "file")
app_end :: proc(app: ^App) {
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
	for n in app.changed { delete(n) }
	delete(app.changed)
}

@(test)
the_search_keeps_what_matches :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "largest")
	testing.expect(t, session.find_text(s, "Max body") != nil, "the preference that matches shows")
	testing.expect(t, session.find_text(s, "Cache") == nil, "the others do not")
	testing.expect(t, session.find_text(s, "NETWORK") != nil, "under its page's title")
}

@(test)
a_switch_flips_and_resets :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "cache")
	session.click(s, "sw")
	testing.expect(t, !config.bool_of(&app.prefs, "net.cache"), "a click flips the switch")
	testing.expect(t, len(app.changed) == 1 && app.changed[0] == "net.cache", "the program hears of it")
	session.click(s, "reset")
	testing.expect(t, config.bool_of(&app.prefs, "net.cache"), "the reset button puts the default back")
	testing.expect_value(t, len(app.changed), 2)
	testing.expect(t, session.find(s, "reset") == nil, "and goes: the value is the default")
}

@(test)
a_choice_is_chosen :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "surfaces")
	session.click_text(s, "Machined")
	testing.expect_value(t, config.string_of(&app.prefs, "look.style"), "machined")
}

@(test)
a_field_refuses_a_value_out_of_range :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "largest")
	session.click(s, "field")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "200000")
	session.key(s, .Return)
	testing.expect_value(t, config.int_of(&app.prefs, "net.max_body"), 1000)
	testing.expect(t, session.find_text(s, "out of range: 1 KiB to 100 MiB") != nil, "the reason shows under the line, its bounds as sizes")
	testing.expect_value(t, len(app.changed), 0)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "12")
	session.key(s, .Return)
	testing.expect_value(t, config.int_of(&app.prefs, "net.max_body"), 12)
	testing.expect(t, len(app.changed) == 1 && app.changed[0] == "net.max_body", "the program hears of the good one")
}

// The carved line is between two lines of a group: the Network page's four lines have three, none under the last.
@(test)
the_rule_is_between_two_lines :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	body := session.find(s, "prefs_body")
	if !testing.expect(t, body != nil, "the page's body") { return }
	rules, lines: int
	last: ^ui.Box
	for c := body.first; c != nil; c = c.next {
		if .Groove in c.flags { rules += 1 }
		if c.first != nil || .Groove in c.flags { last = c }
	}
	for name in ([]string{"set_net.cache", "set_net.max_body", "set_net.timeout", "set_net.mirror"}) {
		if session.find(s, name) != nil { lines += 1 }
	}
	testing.expect_value(t, lines, 4)
	testing.expect_value(t, rules, 3)
	testing.expect(t, last != nil && .Groove not_in last.flags, "no rule under the last line")
}

// A size typed with a suffix is set in the setting's unit, and the field shows it in its largest exact unit.
@(test)
a_size_is_typed_with_its_suffix :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "largest")
	testing.expect(t, session.find_text(s, "1000 KiB") != nil, "the field shows the size with its unit")
	session.click(s, "field")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "4 MiB")
	session.key(s, .Return)
	testing.expect_value(t, config.int_of(&app.prefs, "net.max_body"), 4096)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "4 MiB") != nil, "and shows it so")
}

// A time is a number with its unit after it, and its field reads the unit's suffixes.
@(test)
a_duration_shows_its_unit :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "answer may take")
	v := session.get(s, "value")
	if testing.expect(t, v.a11y != nil, "the number says its value") { testing.expect_value(t, v.a11y.value, "300 ms") }
	testing.expect(t, session.find_text(s, "ms") != nil, "its unit is written")
	session.click(s, "value")
	session.frames(s, 2)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "1.5 s")
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.int_of(&app.prefs, "net.timeout"), 1500)
}

// An address with no scheme is refused, and the line says what an address is.
@(test)
an_address_without_its_scheme_is_refused :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "copies are fetched")
	session.click(s, "field")
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "example.org")
	session.key(s, .Return)
	testing.expect_value(t, config.string_of(&app.prefs, "net.mirror"), "https://example.org/")
	testing.expect(t, session.find_text(s, "not a valid value for this type: an address with its scheme: https://…") != nil, "the reason says what is taken")
	testing.expect_value(t, len(app.changed), 0)
}

@(test)
a_page_is_shown :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	testing.expect(t, session.find_text(s, "Cache") != nil, "the first page shows")
	testing.expect(t, session.find_text(s, "Nothing here") == nil, "a page with no preference is not shown")
	session.click(s, "nav1")
	testing.expect(t, session.find_text(s, "Style") != nil, "the page clicked shows")
	testing.expect(t, session.find_text(s, "Cache") == nil, "the other no more")
}

// A hidden preference (the program's own) is on no page, and the search does not find it.
@(test)
a_hidden_preference_is_on_no_page :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	testing.expect(t, session.find_text(s, "Cache") != nil, "its page shows")
	testing.expect(t, session.find(s, "set_net.window_size") == nil, "not the hidden one")
	app_end(&app)
	app = {}
	s = app_start(t, &app, "window")
	testing.expect(t, session.find_text(s, "Window size") == nil, "the search does not find it")
}

// A preference's line is as tall as its words and its control: a field, with its unit or not, makes it no taller.
@(test)
a_line_is_as_tall_as_its_words :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	em := ui.font_size()
	for name in ([]string{"set_net.cache", "set_net.max_body"}) {
		b := session.find(s, name)
		testing.expectf(t, b != nil, "%s is shown", name)
		if b == nil { continue }
		h := b.rect.max.y - b.rect.min.y
		testing.expectf(t, h < em * 6, "%s: %.0f px tall (an em is %.0f)", name, h, em)
	}
}

// A preference that holds a key combination is recorded: a click, the keys pressed, saved as their text; what the program
// says of it shows under its line.
@(test)
a_shortcut_is_recorded_by_its_keys :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "shows the window")
	testing.expect(t, session.find_text(s, "Ctrl+Shift+U") != nil, "its keys show")
	session.click(s, "keys")
	testing.expect(t, prefs_page.editing(&app.page), "while it records, Escape is its own")
	session.key(s, .Delete, {.Ctrl, .Alt})
	testing.expect_value(t, config.string_of(&app.prefs, "look.keys"), "Ctrl+Alt+Delete")
	testing.expect(t, len(app.changed) == 1 && app.changed[0] == "look.keys", "the program hears of it")
	testing.expect(t, session.find_text(s, "Windows holds it") != nil, "the program's word under the line")
}

// The line of the update preference says the Updater's state, and its Check now asks: a server that cannot be reached says
// so there.
@(test)
the_updater_shows_under_its_preference :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	base, _ := os.temp_directory(context.temp_allocator)
	app.updater = update.updater_start({product = {name = "app", sign_context = "app-update-v1\n"}, folder = "http://127.0.0.1:1/", current = "1.0.0", exe = fmt.tprintf("%s/no-such-app", base)})
	defer update.updater_stop(app.updater)
	s := app_start(t, &app, "cache")
	testing.expect(t, session.find_text(s, "Not checked yet.") != nil, "its state")
	session.click(s, "update_check")
	deadline := time.time_add(time.now(), 10 * time.Second)
	for update.status(app.updater).serial < 2 && time.diff(time.now(), deadline) > 0 { time.sleep(5 * time.Millisecond) }
	session.frame(s)
	testing.expect(t, update.status(app.updater).failed, "the check failed")
	found := false
	if b := session.find_text(s, update.status_words(update.status(app.updater))); b != nil { found = true }
	testing.expect(t, found, "said under the line")
}

// Check now keeps its words on one line on a page of a normal width: its row has a width of its own, not the program's
// base width (text_size() of a row with no text: a few pixels, which wrapped the words to their widest one).
@(test)
the_update_button_keeps_its_words_on_one_line :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	base, _ := os.temp_directory(context.temp_allocator)
	app.updater = update.updater_start({product = {name = "app"}, folder = "http://127.0.0.1:1/", current = "1.0.0", exe = fmt.tprintf("%s/no-such-app", base)})
	defer update.updater_stop(app.updater)
	s := app_start(t, &app, "cache")
	b := session.find(s, "update_check")
	testing.expect(t, b != nil, "Check now")
	if b == nil { return }
	words := session.find(s, "t", within = b)
	testing.expect(t, words != nil, "its words")
	if words == nil { return }
	wide := words.rect.max.x - words.rect.min.x
	tall := words.rect.max.y - words.rect.min.y
	testing.expectf(t, wide + 0.5 >= words.text_dim.x, "as wide as its words on one line: %v < %v", wide, words.text_dim.x)
	testing.expectf(t, tall < 1.5 * words.text_dim.y, "one line tall: %v for a line of %v", tall, words.text_dim.y)
}

// A copy a package manager updates says so, and offers nothing.
@(test)
a_managed_copy_offers_nothing :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	app.updater = update.updater_start({product = {name = "app"}, folder = "http://127.0.0.1:1/", current = "1.0.0", exe = "/nix/store/x-app/bin/app"})
	defer update.updater_stop(app.updater)
	s := app_start(t, &app, "cache")
	testing.expect(t, session.find_text(s, "A package manager updates this copy.") != nil)
	testing.expect(t, session.find(s, "update_check") == nil, "no Check now")
}

// A number's slider dragged and let go keeps where it was let go: the page keeps the value while the button is down, the
// release writes it.
@(test)
a_slider_keeps_where_it_was_let_go :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "interface is drawn")
	sl := session.get(s, "slider")
	r := sl.rect
	from := [2]f32{r.min.x + (r.max.x - r.min.x) * (1 - 0.5) / 1.5, (r.min.y + r.max.y) * 0.5}   // (1 on 0.5 .. 2)
	to := [2]f32{r.max.x - 2, from.y}
	session.drag(s, from, to)
	session.frames(s, 2)
	got := config.float_of(&app.prefs, "look.zoom")
	testing.expectf(t, got > 1.8, "the value let go is kept: %v", got)
	testing.expect(t, len(app.changed) > 0 && app.changed[len(app.changed) - 1] == "look.zoom", "the program is told")
}

// A number's unit is written as it is, "%" too.
@(test)
a_number_writes_its_unit :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "dark the screen")
	v := session.get(s, "value")
	testing.expect(t, v.a11y != nil, "the number says its value")
	if v.a11y != nil { testing.expect_value(t, v.a11y.value, "45 %") }
}

// A number's slider held shows its value at once (Page_Options.preview: the program applies it), the preference written at the release.
@(test)
a_held_slider_previews_its_value :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "interface is drawn")
	sl := session.get(s, "slider")
	r := sl.rect
	from := [2]f32{r.min.x + (r.max.x - r.min.x) * (1 - 0.5) / 1.5, (r.min.y + r.max.y) * 0.5}   // (1 on 0.5 .. 2)
	to := [2]f32{r.max.x - 2, from.y}
	session.press(s, from)
	session.move(s, to)
	session.frames(s, 2)
	testing.expectf(t, app.preview > 1.8, "previewed while held: %v", app.preview)
	testing.expect_value(t, config.float_of(&app.prefs, "look.zoom"), 1)   // (not written yet)
	session.release(s, to)
	session.frames(s, 2)
	testing.expect(t, config.float_of(&app.prefs, "look.zoom") > 1.8, "written at the release")
}

@(private = "file")
Palette_App :: struct {
	using app: App,
	pal:       ui.Command_Palette,
	settings:  prefs_page.Palette_Settings,
	opened:    int,      // the times the settings source asked the program to show its settings
	show:      bool,     // open the palette in the next build
	typed:     string,   // what it opens with
	pages:     []prefs_page.Page_Info,   // the page options' pages: the source asks for them when it reads
}

// The page options as they are now (the settings source asks for them each time it reads or acts).
@(private = "file")
palette_app_options :: proc(user: rawptr) -> prefs_page.Page_Options {
	app := (^Palette_App)(user)
	return {pages = app.pages, user = app, changed = proc(user: rawptr, name: string) {
		app := (^Palette_App)(user)
		append(&app.changed, strings.clone(name))
	}}
}

// (the window command first, as a program reads its keys before it builds its page; the toolkit's sources act in
// palette_chosen)
@(private = "file")
palette_app_build :: proc(s: ^session.Session) {
	app := (^Palette_App)(s.user)
	ui.palette_keys(&app.pal)
	if app.show { app.show = false; ui.palette_open(&app.pal, app.typed) }
	_, _ = ui.palette_chosen(&app.pal)
	app_build(s)
}

@(private = "file")
palette_app_start :: proc(t: ^testing.T, app: ^Palette_App) -> ^session.Session {
	app.prefs = config.prefs_make()
	config.register(&app.prefs, DEFS[:])
	if app.pages == nil { app.pages = PAGES[:] }
	prefs_page.palette_settings_add(&app.pal, &app.settings, &app.prefs, &app.page, palette_app_options, proc(user: rawptr) { (^Palette_App)(user).opened += 1 }, app)
	prefs_page.focus_search(&app.page)
	return session.start(t, {size = {1200, 700}, build = palette_app_build, user = app})
}

// The palette's list came: no ranking in flight, no source reading.
@(private = "file")
palette_wait :: proc(s: ^session.Session, app: ^Palette_App) {
	session.wait_until(s, app, proc(s: ^session.Session, app: ^Palette_App) -> bool { return !ui.palette_busy(&app.pal) && ui.palette_row_count(&app.pal) > 0 }, "the palette's list")
}

// The settings source: one item per preference shown (not a hidden one), under its page; the one chosen is put alone on
// its page, and the program is asked to show its settings.
@(test)
a_setting_from_the_palette :: proc(t: ^testing.T) {
	app: Palette_App
	defer app_end(&app.app)
	defer ui.palette_destroy(&app.pal)
	s := palette_app_start(t, &app)
	testing.expect(t, slice_has(ui.palette_prefixes(&app.pal), ": Settings"), "the prefix of the settings")
	app.show, app.typed = true, ":"
	palette_wait(s, &app)
	testing.expect_value(t, ui.palette_row_count(&app.pal), 8)   // (the nine of DEFS but the hidden one)
	ids := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< ui.palette_row_count(&app.pal) { _, id, _ := ui.palette_row(&app.pal, i); append(&ids, id) }
	testing.expect(t, slice_has(ids[:], "look.style"), "look.style is there")
	testing.expect(t, !slice_has(ids[:], "net.window_size"), "not the hidden one")
	testing.expect(t, session.find_text(s, "Settings · Look") != nil, "under its page")
	session.type_text(s, "style")
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Palette_App) -> bool {
		_, id, ok := ui.palette_row(&app.pal, 0)
		return !ui.palette_busy(&app.pal) && ok && id == "look.style"
	}, "look.style first")
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Palette_App) -> bool { return app.opened == 1 }, "the settings shown")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "How surfaces are drawn.") != nil, "the one chosen")
	testing.expect(t, session.find_text(s, "Keep a cache of the responses.") == nil, "alone")
	testing.expect_value(t, app.page.current, "look")
}

// A switch from the palette: Enter flips it, the palette stays open, its mark follows, the list is not ranked again.
@(test)
a_switch_flips_from_the_palette :: proc(t: ^testing.T) {
	app: Palette_App
	defer app_end(&app.app)
	defer ui.palette_destroy(&app.pal)
	s := palette_app_start(t, &app)
	app.show, app.typed = true, ":cache"
	palette_wait(s, &app)
	_, id, _ := ui.palette_row(&app.pal, 0)
	testing.expect_value(t, id, "net.cache")
	testing.expect(t, app.settings.source.mark(&app.settings.source, "net.cache"), "on: its mark")
	rankings := app.pal.rankings
	session.key(s, .Return)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Palette_App) -> bool { return !config.bool_of(&app.prefs, "net.cache") }, "the switch off")
	session.frames(s, 2)
	testing.expect(t, ui.palette_is_open(&app.pal), "the palette stays open")
	testing.expect(t, !app.settings.source.mark(&app.settings.source, "net.cache"), "off: no mark")
	testing.expect_value(t, app.pal.rankings, rankings)
	testing.expect(t, slice_has(app.changed[:], "net.cache"), "the program hears of it")
	testing.expect_value(t, app.opened, 0)
}

// The settings source is added once: it asks for the page options when it reads, so options made again (a new slice)
// need no new add; a second add does nothing.
@(test)
the_settings_source_reads_its_options_when_it_needs_them :: proc(t: ^testing.T) {
	app: Palette_App
	defer app_end(&app.app)
	defer ui.palette_destroy(&app.pal)
	app.pages = PAGES[:1]   // (the Network page alone)
	s := palette_app_start(t, &app)
	app.show, app.typed = true, ":"
	palette_wait(s, &app)
	testing.expect_value(t, ui.palette_row_count(&app.pal), 4)   // (net.cache, net.max_body, net.timeout, net.mirror; not the hidden one)
	session.key(s, .Escape)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Palette_App) -> bool { return !ui.palette_is_open(&app.pal) }, "the palette closed")
	// the program's options made again (another slice): no new add, a new version of the pages
	app.pages = PAGES[:]
	prefs_page.palette_settings_add(&app.pal, &app.settings, &app.prefs, &app.page, palette_app_options, nil, &app)   // (a second add: nothing)
	testing.expect(t, app.settings.open != nil, "the first add's still")
	app.settings.source.version += 1
	app.show = true
	// (the list of the last opening stays until the new read is ranked: wait for the new one, not for any list)
	session.wait_until(s, &app, proc(s: ^session.Session, app: ^Palette_App) -> bool {
		return !ui.palette_busy(&app.pal) && ui.palette_row_count(&app.pal) == 8
	}, "the eight settings of every page, read again for the new version")
}

// The settings shown, their search field with the keyboard: the window command's key opens the palette, which finds
// the settings.
@(test)
the_palette_opens_from_the_settings :: proc(t: ^testing.T) {
	app: Palette_App
	defer app_end(&app.app)
	defer ui.palette_destroy(&app.pal)
	s := palette_app_start(t, &app)
	session.type_text(s, "cache")
	testing.expect_value(t, ui.line_edit_string(&app.page.query), "cache")
	session.key(s, .K, {.Ctrl})
	session.frames(s, 2)
	testing.expect(t, ui.palette_is_open(&app.pal), "Ctrl+K opens the palette while the settings' field has the keyboard")
	testing.expect_value(t, ui.line_edit_string(&app.page.query), "cache")
	session.type_text(s, "max")
	palette_wait(s, &app)
	testing.expect(t, session.find_text(s, "Max body") != nil, "the palette finds the settings")
}

// The search the palette put there is for that visit: closed and opened again, the settings show the page the person
// had, the search empty. A search the person typed stays, as the last page does.
@(test)
a_setting_from_the_palette_goes_when_the_settings_close :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	session.frames(s, 2)
	app.closed = true
	session.frames(s, 2)
	prefs_page.show(&app.page, &app.prefs, {pages = PAGES[:]}, "look.style")
	app.closed = false
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "How surfaces are drawn.") != nil, "opened on the one chosen")
	testing.expect(t, session.find_text(s, "Keep a cache of the responses.") == nil, "alone")
	app.closed = true
	session.frames(s, 2)
	prefs_page.focus_search(&app.page)
	app.closed = false
	session.frames(s, 2)
	testing.expect_value(t, ui.line_edit_string(&app.page.query), "")
	testing.expect_value(t, app.page.current, "")   // (the page the person had: the first)
	testing.expect(t, session.find_text(s, "Keep a cache of the responses.") != nil, "the first page, whole")

	// (the person's own search: kept across a close)
	session.type_text(s, "surfaces")
	session.frames(s, 2)
	app.closed = true
	session.frames(s, 2)
	app.closed = false
	session.frames(s, 2)
	testing.expect_value(t, ui.line_edit_string(&app.page.query), "surfaces")

	// (a jump the person then changed is theirs too)
	prefs_page.show(&app.page, &app.prefs, {pages = PAGES[:]}, "net.cache")
	session.frames(s, 2)
	session.type_text(s, "x")
	session.frames(s, 2)
	app.closed = true
	session.frames(s, 2)
	app.closed = false
	session.frames(s, 2)
	q := ui.line_edit_string(&app.page.query)
	testing.expect(t, q != "" && q != "\"net.cache\"", "the changed search stays")
}

@(private = "file")
slice_has :: proc(xs: []string, x: string) -> bool {
	for y in xs { if y == x { return true } }
	return false
}

// A search lights its words in the titles and the descriptions: the description is drawn as runs then.
@(test)
a_search_lights_its_words :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "cache")
	session.frames(s, 2)
	testing.expect(t, session.find(s, "d") != nil, "its runs")
}

// The program's version, at the bottom of the pages.
@(test)
the_version_shows :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	testing.expect(t, session.find_text(s, "Sample 1.2.3") != nil)
}

// The badge of the status bar shows nothing when the updater has nothing to do.
@(test)
no_badge_with_nothing_to_do :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	app.updater = update.updater_start({product = {name = "app"}, folder = "http://127.0.0.1:1/", current = "1.0.0", exe = "/nix/store/x-app/bin/app"})
	defer update.updater_stop(app.updater)
	s := app_start(t, &app)
	_ = s
	testing.expect(t, prefs_page.update_badge(app.updater, nil, nil) == nil)
}
