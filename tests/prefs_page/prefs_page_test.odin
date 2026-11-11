// The settings page of a program's preferences (prefs_page): the search keeps what matches, a switch flips and resets,
// a choice is chosen, a field refuses a value out of range with its reason and takes a good one, a page is shown; the
// program hears of each change.
//   odin test tests/prefs_page -vet -define:ODIN_TEST_THREADS=1
package prefs_page_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:testing"
import config "../../src/config"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"
import update "../../src/update"

@(private = "file")
DEFS := [?]config.Def{
	{name = "net.cache", description = "Keep a cache of the responses.", kind = .Bool, default = {b = true}},
	{name = "net.max_body", description = "The largest response kept.", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 100000, unit = "KB"},
	{name = "look.style", description = "How surfaces are drawn.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined"}},
	{name = "look.zoom", description = "How large the interface is drawn.", kind = .Float, default = {f = 1}, bounded = true, min = 0.5, max = 2},
	{name = "look.keys", description = "What shows the window.", kind = .String, default = {s = "Ctrl+Shift+U"}},
	{name = "net.window_size", description = "The size the window was given.", kind = .String, default = {s = ""}, hidden = true},
}

@(private = "file")
PAGES := [?]prefs_page.Page_Info{{category = "net", title = "Network"}, {category = "gone", title = "Nothing here"}, {category = "look", title = "Look"}}

@(private = "file", rodata)
HOTKEYS := [?]string{"look.keys"}

@(private = "file")
App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	changed: [dynamic]string,
	updater: ^update.Updater,
	preview: f64,   // the last value a held slider showed (Options.preview)
}

@(private = "file")
app_build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, {user = app, pages = PAGES[:], hotkeys = HOTKEYS[:], updater = app.updater, update_pref = "net.cache", problem = proc(user: rawptr, name: string) -> string {
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
	testing.expect(t, session.find_text(s, "1 to 100000 KB") != nil || session.find_text(s, "out of range: 1 to 100000 KB") != nil, "the reason shows under the line")
	testing.expect_value(t, len(app.changed), 0)
	session.key(s, .A, {.Ctrl})
	session.type_text(s, "12")
	session.key(s, .Return)
	testing.expect_value(t, config.int_of(&app.prefs, "net.max_body"), 12)
	testing.expect(t, len(app.changed) == 1 && app.changed[0] == "net.max_body", "the program hears of the good one")
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

// A slider dragged and let go keeps where it was let go: ui.slider moves its value only while the button is down, the page
// keeps it until the release writes it (it went back to the old value at the release).
@(test)
a_slider_keeps_where_it_was_let_go :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "interface is drawn")
	sl := session.get(s, "sl")
	r := sl.rect
	from := [2]f32{r.min.x + (r.max.x - r.min.x) * (1 - 0.5) / 1.5, (r.min.y + r.max.y) * 0.5}   // (1 on 0.5 .. 2)
	to := [2]f32{r.max.x - 2, from.y}
	session.drag(s, from, to)
	session.frames(s, 2)
	got := config.float_of(&app.prefs, "look.zoom")
	testing.expectf(t, got > 1.8, "the value let go is kept: %v", got)
	testing.expect(t, len(app.changed) > 0 && app.changed[len(app.changed) - 1] == "look.zoom", "the program is told")
}

// A slider held shows its value at once (Options.preview: the program applies it), the preference written at the release.
@(test)
a_held_slider_previews_its_value :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app, "interface is drawn")
	sl := session.get(s, "sl")
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

// The settings as commands of a palette: one per preference shown (not a hidden one), under its page; show puts the one
// chosen alone on its page.
@(test)
a_setting_from_the_palette :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := app_start(t, &app)
	commands, names := prefs_page.palette_commands(&app.prefs, {pages = PAGES[:]})
	testing.expect_value(t, len(commands), 5)   // (the six of DEFS but the hidden one)
	testing.expect_value(t, len(names), 5)
	at := -1
	for n, i in names { if n == "look.style" { at = i } }
	testing.expect(t, at >= 0, "look.style is there")
	testing.expect(t, !slice_has(names, "net.window_size"), "not the hidden one")
	if at >= 0 { testing.expect_value(t, commands[at].group, "Settings · Look") }
	prefs_page.show(&app.page, &app.prefs, {pages = PAGES[:]}, "look.style")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "How surfaces are drawn.") != nil, "the one chosen")
	testing.expect(t, session.find_text(s, "Keep a cache of the responses.") == nil, "alone")
	testing.expect_value(t, app.page.current, "look")
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
