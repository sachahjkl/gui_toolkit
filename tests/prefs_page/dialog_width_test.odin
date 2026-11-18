package prefs_page_test

// The settings shown in a dialog narrower than their content's natural width (opencode native 0.73.0: What's new in a
// 1000 px dialog ran ~280 px past its edge): the page's body is its share of the dialog beside the sidebar, never its
// content's width; every box of the page stands within the body, the bullets wrap at its width. Every page of the common
// set, What's new among them, in a dialog 1000 and 700 px wide.

import "core:fmt"
import "core:strings"
import "core:testing"
import config "gt:config"
import prefs_page "gt:prefs_page"
import "gt:testkit/session"
import "gt:ui"

@(private)
Dialog_App :: struct {
	prefs:     config.Prefs,
	page:      prefs_page.Page,
	changelog: prefs_page.Changelog,
	width:     f32,   // the dialog's width, in pixels
}

// A changelog as a real program's: many versions, the four common kinds, bullets of long sentences.
@(private)
dialog_changelog :: proc() -> string {
	b := strings.builder_make()   // (owned: the frames free the temporary memory)
	strings.write_string(&b, "# Changelog\n\n")
	for v := 40; v > 0; v -= 1 {
		fmt.sbprintf(&b, "## [0.%d.0] - 2026-11-%02d 14:07\n\n", v, v % 28 + 1)
		for kind in ([]string{"Added", "Changed", "Removed", "Fixed"}) {
			fmt.sbprintf(&b, "### %s\n\n", kind)
			fmt.sbprintf(&b, "- **The sidebar folds from its servers' row in version %d.** The toolkit's fold button stands at the row's start, and at the rail's top at the same pixel; pulling the rail opens the list again.\n", v)
			fmt.sbprintf(&b, "- **A second change of kind %s.** It says what changed for the user in a sentence long enough to wrap twice at a narrow width.\n\n", kind)
		}
	}
	return strings.to_string(b)
}

@(private)
dialog_build :: proc(s: ^session.Session) {
	app := (^Dialog_App)(s.user)
	// (a dialog: a box of a fixed width in the window's middle, which clips what is in it)
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###around") {
		ui.spacer(ui.fill())
		ui.next({width = ui.px(app.width), height = ui.fill(), axis = .Y})
		dialog := ui.build_box({.Clip, .Draw_Border}, "###dialog")
		ui.push_parent(dialog)
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.page, &app.prefs, {user = app, changelog = &app.changelog})
		ui.pop_parent()
		ui.spacer(ui.fill())
	}
}

// The boxes under `b` whose right edge passes `right` (half a pixel of rounding left aside): their ids, for the message.
@(private)
past_edge :: proc(b: ^ui.Box, right: f32, out: ^[dynamic]string) {
	for c := b.first; c != nil; c = c.next {
		if c.rect.max.x > c.rect.min.x && c.rect.max.x > right + 0.5 {
			append(out, fmt.tprintf("%s (%.0f)", c.name, c.rect.max.x - right))
		}
		past_edge(c, right, out)
	}
}

@(test)
every_page_fits_a_dialog_1000_px_wide :: proc(t: ^testing.T) { dialog_fits(t, 1000) }

@(test)
every_page_fits_a_dialog_700_px_wide :: proc(t: ^testing.T) { dialog_fits(t, 700) }

@(private = "file")
dialog_fits :: proc(t: ^testing.T, width: f32) {
	app: Dialog_App
	app.width = width
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	d := prefs_page.STANDARD_DEFAULTS
	d.theme, d.app_name = "Midnight", "Sample"
	prefs_page.standard_register(&app.prefs, prefs_page.STANDARD_ALL, d, context.temp_allocator)
	app.changelog = {english = dialog_changelog()}
	defer delete(app.changelog.english)
	defer prefs_page.changelog_destroy(&app.changelog)
	app.page.current = strings.clone(prefs_page.CHANGELOG_PAGE)
	defer prefs_page.destroy(&app.page)
	s := session.start(t, {size = {1200, 800}, user = &app, build = dialog_build})
	// (the sidebar as wide as the person made it in the report: about 380 px of the dialog; the page registers its
	// preference at its first build)
	session.frames(s, 1)
	_ = config.set_from_string(&app.prefs, prefs_page.SIDEBAR_PREF, fmt.tprintf("%v", 380 / session.BASE_FONT_SIZE), .User)
	session.frames(s, 4)
	session.save_png(s, fmt.tprintf("settings-whatsnew-%.0f.png", width))
	check :: proc(t: ^testing.T, s: ^session.Session, width: f32, page: string) {
		dialog := session.find(s, "dialog")
		body := session.find(s, "prefs_scroll")
		if !testing.expect(t, dialog != nil && body != nil, "the dialog and the page's body") { return }
		testing.expectf(t, body.rect.max.x <= dialog.rect.max.x + 0.5, "%.0f px, %s: the body ends at the dialog's edge (%.0f past)", width, page, body.rect.max.x - dialog.rect.max.x)
		past := make([dynamic]string, context.temp_allocator)
		past_edge(body, body.rect.max.x, &past)
		testing.expectf(t, len(past) == 0, "%.0f px, %s: every box within the body: %v", width, page, past[:])
	}
	check(t, s, width, "What's new")
	// (a bullet's paragraph: its words wrap at the body's width, onto more lines than one)
	bullet := session.find_text(s, "The sidebar folds from its servers' row in version 40.")
	if testing.expect(t, bullet != nil, "a bullet shown") {
		testing.expect(t, bullet.rect.max.y - bullet.rect.min.y > 2 * session.BASE_FONT_SIZE, "a bullet wraps onto more lines")
	}
	for pg in config.groups_of(&app.prefs) {
		delete(app.page.current)
		app.page.current = strings.clone(pg)
		session.frames(s, 3)
		check(t, s, width, pg)
	}
}
