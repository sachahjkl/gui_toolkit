// The settings page of a program's preferences (prefs_page): the search keeps what matches, a switch flips and resets,
// a choice is chosen, a field refuses a value out of range with its reason and takes a good one, a page is shown; the
// program hears of each change.
//   odin test tests/prefs_page -vet -define:ODIN_TEST_THREADS=1
package prefs_page_test

import "core:strings"
import "core:testing"
import config "../../src/config"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
DEFS := [?]config.Def{
	{name = "net.cache", description = "Keep a cache of the responses.", kind = .Bool, default = {b = true}},
	{name = "net.max_body", description = "The largest response kept.", kind = .Int, default = {i = 1000}, bounded = true, min = 1, max = 100000, unit = "KB"},
	{name = "look.style", description = "How surfaces are drawn.", kind = .String, default = {s = "flat"}, choices = {"flat", "machined"}},
}

@(private = "file")
PAGES := [?]prefs_page.Page_Info{{category = "net", title = "Network"}, {category = "gone", title = "Nothing here"}, {category = "look", title = "Look"}}

@(private = "file")
App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	changed: [dynamic]string,
}

@(private = "file")
app_build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, {user = app, pages = PAGES[:], changed = proc(user: rawptr, name: string) {
		app := (^App)(user)
		append(&app.changed, strings.clone(name))
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
