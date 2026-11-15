package prefs_page_test

// What's new (changelog.odin): the program's changelog on a page of its own; after an update, once, a message that stays
// until a click, which opens the page; the first start and the same version say nothing.

import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private = "file")
SAMPLE_CHANGELOG :: "# Changelog\n\n## [1.2.0] - 2026-11-15\n\n### Added\n\n- **A thing that is new.** It does this.\n\n## [1.1.0] - 2026-11-01\n\n### Fixed\n\n- **An old thing.** It works.\n"

@(private = "file")
Changelog_App :: struct {
	prefs:     config.Prefs,
	page:      prefs_page.Page,
	changelog: prefs_page.Changelog,
	announcer: ui.Announcer,
	opened:    int,
}

@(private = "file")
CHANGELOG_DEFS := [?]config.Def{{name = "general.sample", description = "A setting of the General page.", kind = .Bool}}
@(private = "file")
CHANGELOG_PAGES := [?]prefs_page.Page_Info{{category = "general", title = "General"}}

@(test)
the_changelog_reads_in_the_program_and_an_update_says_so_once :: proc(t: ^testing.T) {
	app: Changelog_App
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	config.register(&app.prefs, CHANGELOG_DEFS[:])
	app.changelog = {english = SAMPLE_CHANGELOG}
	defer prefs_page.changelog_destroy(&app.changelog)
	app.page.current = strings.clone(prefs_page.CHANGELOG_PAGE)
	defer prefs_page.destroy(&app.page)
	s := session.start(t, {size = {1100, 700}, user = &app, build = proc(s: ^session.Session) {
		app := (^Changelog_App)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.page, &app.prefs, {user = app, pages = CHANGELOG_PAGES[:], changelog = &app.changelog})
	}})
	app.announcer = {mode = .Window, state = s.state}
	session.frames(s, 3)
	testing.expect(t, session.find_text(s, "A thing that is new.") != nil, "the changelog on its page")
	testing.expect(t, session.find_text(s, "What's new") != nil, "its title in the sidebar")

	open :: proc(user: rawptr) { (^Changelog_App)(user).opened += 1 }
	testing.expect(t, !prefs_page.changelog_after_update(&app.changelog, &app.prefs, "1.1.0", &app.announcer, open, &app), "the first start: nothing to say")
	testing.expect(t, !prefs_page.changelog_after_update(&app.changelog, &app.prefs, "1.1.0", &app.announcer, open, &app), "the same version: nothing")
	testing.expect(t, prefs_page.changelog_after_update(&app.changelog, &app.prefs, "1.2.0", &app.announcer, open, &app), "an update: said")
	testing.expect_value(t, config.string_of(&app.prefs, prefs_page.SEEN_VERSION_PREF), "1.2.0")
	// it stays past a toast's life, until a click, which opens the page
	session.advance(s, 20_000)
	session.frames(s, 2)
	news := session.find_text(s, "Updated to 1.2.0")
	if !testing.expect(t, news != nil, "the message stays") { return }
	session.click_at(s, session.center(news))
	session.frames(s, 2)
	testing.expect_value(t, app.opened, 1)
}

// The language in use has no translation: the English changelog.
@(test)
the_english_changelog_is_the_fallback :: proc(t: ^testing.T) {
	c := prefs_page.Changelog{english = SAMPLE_CHANGELOG, translations = {{language = "xx", text = "# Ailleurs\n"}}}
	testing.expect_value(t, prefs_page.changelog_text(&c), SAMPLE_CHANGELOG)
}
