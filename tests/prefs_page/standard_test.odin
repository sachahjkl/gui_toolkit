package prefs_page_test

// The standard preferences (standard.odin): they register beside a program's own, read back as the look, and the page's
// reset rule (a user's value that is not the default); the themes' cards from Options.themes; the back bar.

import "core:testing"
import config "../../src/config"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
standard_prefs :: proc() -> config.Prefs {
	p := config.prefs_make()
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&p, {.Appearance, .Session}, d, context.temp_allocator)
	return p
}

@(test)
the_standard_preferences_register :: proc(t: ^testing.T) {
	p := standard_prefs()
	defer config.prefs_destroy(&p)
	names := [?]string{"appearance.theme", "appearance.mode", "appearance.finish", "appearance.font_size", "general.menu", "general.autostart"}
	for n in names { testing.expectf(t, config.ref_of(&p, n) != config.NO_REF, "%s is registered", n) }
	testing.expect_value(t, config.entry(&p, config.ref_of(&p, "appearance.theme")).def.category, "appearance")
	testing.expect_value(t, config.entry(&p, config.ref_of(&p, "general.menu")).def.category, "general")
	testing.expect(t, config.bool_of(&p, "general.menu"), "in the menu by default")
	testing.expect(t, !config.bool_of(&p, "general.autostart"), "not started with the session by default")
	// (every finish offered is one ui knows by its name)
	for c in config.entry(&p, config.ref_of(&p, "appearance.finish")).def.choices {
		testing.expectf(t, ui.FINISH_NAMES[ui.finish_of(c)] == c, "%q is a finish of ui", c)
	}
	testing.expect_value(t, config.set_from_string(&p, "appearance.font_size", "30", .User), config.Set_Error.Out_Of_Range)
	// a program that registers the same names again (its older table) changes nothing
	again := [?]config.Def{{name = "appearance.mode", kind = .String, default = {s = "dark"}}}
	config.register(&p, again[:])
	testing.expect_value(t, config.string_of(&p, "appearance.mode"), "system")
}

@(test)
only_the_sets_asked_register :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	prefs_page.standard_register(&p, {.Appearance}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	testing.expect(t, config.ref_of(&p, "appearance.mode") != config.NO_REF, "the look is there")
	testing.expect(t, config.ref_of(&p, "general.menu") == config.NO_REF, "the session's are not")
}

@(test)
the_look_reads_back :: proc(t: ^testing.T) {
	p := standard_prefs()
	defer config.prefs_destroy(&p)
	a := prefs_page.appearance_read(&p)
	testing.expect_value(t, a.theme, "Midnight")
	testing.expect_value(t, a.mode, ui.Theme_Mode.System)
	testing.expect_value(t, a.finish, ui.Finish.Machined)
	testing.expect_value(t, a.font_size, f32(14))
	prefs_page.appearance_free(&a)
	config.set_from_string(&p, "appearance.theme", "Nord", .User)
	config.set_from_string(&p, "appearance.mode", "light", .User)
	config.set_from_string(&p, "appearance.finish", "edged", .User)
	config.set_from_string(&p, "appearance.font_size", "17", .User)
	a = prefs_page.appearance_read(&p)
	defer prefs_page.appearance_free(&a)
	testing.expect_value(t, a.theme, "Nord")
	testing.expect_value(t, a.mode, ui.Theme_Mode.Light)
	testing.expect_value(t, a.finish, ui.Finish.Edged)
	testing.expect_value(t, a.font_size, f32(17))
	c := prefs_page.appearance_choice(a)
	testing.expect(t, c.name == "Nord" && c.mode == .Light && c.finish == .Edged, "the choice is the look")
}

@(test)
a_registry_without_them_reads_the_defaults :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	a := prefs_page.appearance_read(&p)
	defer prefs_page.appearance_free(&a)
	testing.expect(t, a.theme == "" && a.mode == .System && a.finish == .Machined && a.font_size == 14, "the standard defaults")
}

@(test)
the_reset_rule :: proc(t: ^testing.T) {
	p := standard_prefs()
	defer config.prefs_destroy(&p)
	keys := [?]config.Def{{name = "shortcut.region", kind = .String, default = {s = "Ctrl+Print"}}}
	config.register(&p, keys[:])
	testing.expect(t, !prefs_page.differs_from_default(&p, "appearance.mode"), "the default: no reset")
	config.set_from_string(&p, "appearance.mode", "system", .User)
	testing.expect(t, !prefs_page.differs_from_default(&p, "appearance.mode"), "the user's value equal to the default: no reset")
	config.set_from_string(&p, "appearance.mode", "dark", .User)
	testing.expect(t, prefs_page.differs_from_default(&p, "appearance.mode"), "another value: a reset")
	config.set_from_string(&p, "appearance.font_size", "14.0", .User)
	testing.expect(t, !prefs_page.differs_from_default(&p, "appearance.font_size"), "a number is compared as a number")
	config.set_from_string(&p, "appearance.finish", "flat", .Command_Line)
	testing.expect(t, !prefs_page.differs_from_default(&p, "appearance.finish"), "the command line's value is not the user's")
	config.set_from_string(&p, "shortcut.region", "ctrl+print", .User)
	testing.expect(t, !prefs_page.differs_from_default(&p, "shortcut.region", keys = true), "the same keys in other words")
	testing.expect(t, prefs_page.differs_from_default(&p, "shortcut.region"), "as text, they differ")
	testing.expect(t, !prefs_page.differs_from_default(&p, "no.such"), "an unknown name")
}

@(private = "file")
Look :: struct {
	prefs: config.Prefs,
	page:  prefs_page.Page,
	back:  int,
}

@(private = "file", rodata)
LOOK_PAGES := [?]prefs_page.Page_Info{{category = "appearance", title = "Appearance"}, {category = "general", title = "General"}}

// The themes as cards with no code of the program's; a reset button only while a value differs from its default.
@(test)
the_themes_show_as_cards :: proc(t: ^testing.T) {
	l: Look
	l.prefs = standard_prefs()
	defer { prefs_page.destroy(&l.page); config.prefs_destroy(&l.prefs) }
	s := session.start(t, {size = {1200, 900}, user = &l, build = proc(s: ^session.Session) {
		l := (^Look)(s.user)
		o := prefs_page.Options{pages = LOOK_PAGES[:], themes = ui.THEMES[:6]}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###look") {
			if prefs_page.back_bar(&l.page, o, "Settings", "Back (Escape)", ui.font_size()) { l.back += 1 }
			ui.next({width = ui.fill(), height = ui.fill()})
			prefs_page.build(&l.page, &l.prefs, o)
		}
	}})
	testing.expect(t, session.find(s, "reset") == nil, "every value is its default: no reset button")
	session.click_text(s, ui.THEMES[1].name)
	testing.expect_value(t, config.string_of(&l.prefs, "appearance.theme"), ui.THEMES[1].name)
	testing.expect(t, session.find(s, "reset") != nil, "the theme differs: its reset button shows")
	session.click(s, "reset")
	testing.expect_value(t, config.string_of(&l.prefs, "appearance.theme"), "Midnight")
	config.set_from_string(&l.prefs, "appearance.theme", "Midnight", .User)
	session.frame(s)
	testing.expect(t, session.find(s, "reset") == nil, "the user's value equal to the default: no reset button")
	session.click(s, "prefs_back")
	testing.expect_value(t, l.back, 1)
}

// Where the messages go: the system's by default, as the preference says once set.
@(test)
the_messages_mode_reads_back :: proc(t: ^testing.T) {
	p := standard_prefs()
	defer config.prefs_destroy(&p)
	testing.expect_value(t, prefs_page.messages_mode(&p), ui.Announce_Mode.System)
	config.set_from_string(&p, "general.messages", "window", .User)
	testing.expect_value(t, prefs_page.messages_mode(&p), ui.Announce_Mode.Window)
	testing.expect(t, config.set_from_string(&p, "general.messages", "loud", .User) != .None, "a value of its choices only")
}
