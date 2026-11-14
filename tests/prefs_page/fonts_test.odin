package prefs_page_test

// The family settings on the page: at their defaults they name the family in use (never an empty field), and a font
// picker over a fake source (no system read) sets the preference at once. The toolkit applies a family chosen with no
// restart: its face, loaded on a chore, is the interface's at the chore's answer; Default puts the program's back.

import "base:runtime"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import config "../../src/config"
import "../../src/font"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file") BOUND :: 20 * time.Second

@(private = "file")
Fonts_App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	watch:   prefs_page.Standard_Watch,
	changed: [dynamic]string,
	alpha:   font.Font_Id,   // the fake source's face of "Alpha Sans" (0: it has none)
}

// "Alpha Sans" and "Beta Mono"; only the first has a face.
@(private = "file")
fake_source :: proc(app: ^Fonts_App) -> ui.Font_Source {
	return {
		user = app,
		families = proc(user: rawptr, allocator: mem.Allocator) -> []font.Family {
			out := make([]font.Family, 2, allocator)
			out[0] = {name = strings.clone("Alpha Sans", allocator)}
			out[1] = {name = strings.clone("Beta Mono", allocator), monospace = true}
			return out
		},
		face = proc(user: rawptr, family: string) -> font.Font_Id {
			return family == "Alpha Sans" ? (^Fonts_App)(user).alpha : 0
		},
	}
}

@(private = "file")
fonts_build :: proc(s: ^session.Session) {
	app := (^Fonts_App)(s.user)
	ui.next({width = ui.fill(), height = ui.fill()})
	prefs_page.build(&app.page, &app.prefs, {user = app, changed = proc(user: rawptr, name: string) {
		append(&(^Fonts_App)(user).changed, strings.clone(name, runtime.heap_allocator()))
	}})
}

@(private = "file")
fonts_start :: proc(t: ^testing.T, app: ^Fonts_App) -> ^session.Session {
	app.prefs = config.prefs_make()
	app.changed.allocator = runtime.heap_allocator()
	prefs_page.standard_register(&app.prefs, {.Text}, prefs_page.STANDARD_DEFAULTS, context.temp_allocator)
	prefs_page.focus_search(&app.page)
	s := session.start(t, {size = {1200, 800}, build = fonts_build, user = app})
	// (a face of its own, another than the interface's and the monospace one: the embedded monospace, loaded again)
	app.alpha, _ = font.load_embedded(&s.own.fonts, font.FALLBACK_MONO_DATA)
	prefs_page.standard_watch(&app.watch, &app.prefs, s.state, {font_source = fake_source(app)})
	session.type_text(s, "font")
	session.frames(s, 3)
	return s
}

@(private = "file")
fonts_end :: proc(app: ^Fonts_App) {
	prefs_page.standard_unwatch(&app.watch)
	prefs_page.destroy(&app.page)
	config.prefs_destroy(&app.prefs)
	for n in app.changed { delete(n, runtime.heap_allocator()) }
	delete(app.changed)
}

// The button of a family setting under its line.
@(private = "file")
picker_of :: proc(s: ^session.Session, name: string) -> ^ui.Box {
	line := session.find(s, strings.concatenate({"set_", name}, context.temp_allocator))
	if line == nil { return nil }
	return session.find(s, "font", within = line)
}

// At their defaults, the interface's and the monospace settings name the faces the window draws in.
@(test)
a_font_setting_shows_its_default :: proc(t: ^testing.T) {
	app: Fonts_App
	defer fonts_end(&app)
	s := fonts_start(t, &app)
	for name in ([]string{prefs_page.UI_FONT_PREF, prefs_page.MONO_FONT_PREF, prefs_page.PROSE_FONT_PREF}) {
		b := picker_of(s, name)
		if !testing.expectf(t, b != nil, "%s has a font picker", name) { continue }
		face := name == prefs_page.MONO_FONT_PREF ? s.own.mono_font : s.own.ui_font
		family := font.family_of(&s.own.fonts, face)
		testing.expectf(t, family != "", "%s: the face in use names its family", name)
		shown := session.find_text(s, ui.font_default_label(family))
		testing.expectf(t, shown != nil, "%s shows %q", name, ui.font_default_label(family))
	}
	testing.expect_value(t, app.page.font_families.reads, 0)   // (the list is read at an opening, not with the page)
}

// A family chosen in the picker is the preference's value at once; Default puts "" back.
@(test)
a_font_chosen_is_set :: proc(t: ^testing.T) {
	app: Fonts_App
	defer fonts_end(&app)
	s := fonts_start(t, &app)
	b := picker_of(s, prefs_page.UI_FONT_PREF)
	if !testing.expect(t, b != nil, "the interface's font picker") { return }
	session.click_at(s, session.center(b))
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^Fonts_App)(s.user).page.font_families.reading == .Ready }, "the families", BOUND)
	session.frames(s, 2)
	session.type_text(s, "alpha")
	session.frames(s, 2)
	session.key(s, .Return)
	session.frames(s, 2)
	testing.expect_value(t, config.string_of(&app.prefs, prefs_page.UI_FONT_PREF), "Alpha Sans")
	if testing.expect(t, len(app.changed) > 0, "the program hears of it") { testing.expect_value(t, app.changed[len(app.changed) - 1], prefs_page.UI_FONT_PREF) }
	testing.expect(t, session.find_text(s, "Alpha Sans") != nil, "the button shows it")
}

// A family chosen is the interface's face once the chore that loads it answers, with no restart: the window's next
// build draws in it. Default puts the program's face back at once, and the picker names the program's, not the one
// chosen before.
@(test)
a_font_chosen_applies_at_once :: proc(t: ^testing.T) {
	app: Fonts_App
	defer fonts_end(&app)
	s := fonts_start(t, &app)
	if !testing.expect(t, app.alpha != 0 && app.alpha != s.own.ui_font, "a face of its own for the fake family") { return }
	r := config.ref_of(&app.prefs, prefs_page.UI_FONT_PREF)
	testing.expect(t, !config.entry(&app.prefs, r).def.restart, "the interface's family needs no restart")
	testing.expect_value(t, ui.state_text_face(s.state, .Interface), s.own.ui_font)

	testing.expect_value(t, config.set_from_string(&app.prefs, prefs_page.UI_FONT_PREF, "Alpha Sans", .User), config.Set_Error.None)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		return ui.state_text_face(s.state, .Interface) == (^Fonts_App)(s.user).alpha
	}, "the chosen family's face", BOUND)
	session.frames(s, 2)
	if b := picker_of(s, prefs_page.UI_FONT_PREF); testing.expect(t, b != nil, "the interface's font picker") {
		testing.expect_value(t, b.font, app.alpha)   // (the window's base font: what every box draws in)
	}

	testing.expect_value(t, config.set_from_string(&app.prefs, prefs_page.UI_FONT_PREF, "", .User), config.Set_Error.None)
	testing.expect_value(t, ui.state_text_face(s.state, .Interface), s.own.ui_font)
	session.frames(s, 2)
	if b := picker_of(s, prefs_page.UI_FONT_PREF); testing.expect(t, b != nil, "the interface's font picker") {
		testing.expect_value(t, b.font, s.own.ui_font)
	}
	label := ui.font_default_label(font.family_of(&s.own.fonts, s.own.ui_font))
	testing.expectf(t, session.find_text(s, label) != nil, "the default named as the program's: %q", label)
}

// A family the source has no face for leaves the program's face (the monospace one here), and the serial a program
// watches moves only with a face that changed.
@(test)
a_missing_font_keeps_the_programs :: proc(t: ^testing.T) {
	app: Fonts_App
	defer fonts_end(&app)
	s := fonts_start(t, &app)
	serial := ui.text_faces_serial(s.state)
	testing.expect_value(t, config.set_from_string(&app.prefs, prefs_page.MONO_FONT_PREF, "Beta Mono", .User), config.Set_Error.None)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		_, loading := ui.text_family(s.state, .Mono)
		return !loading
	}, "the chore's answer", BOUND)
	testing.expect_value(t, ui.state_text_face(s.state, .Mono), s.own.mono_font)
	testing.expect_value(t, ui.text_faces_serial(s.state), serial)

	testing.expect_value(t, config.set_from_string(&app.prefs, prefs_page.MONO_FONT_PREF, "Alpha Sans", .User), config.Set_Error.None)
	session.wait_until(s, proc(s: ^session.Session) -> bool {
		return ui.state_text_face(s.state, .Mono) == (^Fonts_App)(s.user).alpha
	}, "the chosen family's face", BOUND)
	testing.expect(t, ui.text_faces_serial(s.state) != serial, "the serial moved")
	testing.expect_value(t, ui.state_text_face(s.state, .Interface), s.own.ui_font)   // (the others stay)
}
