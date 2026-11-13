package prefs_page_test

// The toolkit's Licence page (prefs_page.Licence): unregistered, it says so in the one wording, with Buy a licence; a key
// that does not check out is refused with its reason, read and written on a task, never the interface's thread.

import "core:strings"
import "core:testing"
import config "../../src/config"
import licence "../../src/licence"
import prefs_page "../../src/prefs_page"
import "../../src/testkit/session"
import "../../src/ui"

@(private = "file")
SAMPLE_PRODUCT :: licence.Product{
	name = "sample", title = "sample", version_tag = "SAMPLE1", sign_context = "sample-licence-v1\n",
	file_extension = ".samplelicence", editions = {0 = {id = "supporter", title = "Supporter"}},
}

@(private = "file")
Licence_App :: struct {
	prefs:   config.Prefs,
	page:    prefs_page.Page,
	licence: prefs_page.Licence,
}

// (this file's own: the other tests' preferences and pages are private to their files)
@(private = "file")
LICENCE_DEFS := [?]config.Def{{name = "general.sample", description = "A setting of the General page.", kind = .Bool}}

@(private = "file")
LICENCE_PAGES := [?]prefs_page.Page_Info{{category = "general", title = "General"}}

@(test)
the_licence_page_says_its_state :: proc(t: ^testing.T) {
	app: Licence_App
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	config.register(&app.prefs, LICENCE_DEFS[:])
	app.page.current = strings.clone(prefs_page.LICENCE_PAGE)
	defer prefs_page.destroy(&app.page)
	s := session.start(t, {size = {1200, 700}, user = &app, build = proc(s: ^session.Session) {
		app := (^Licence_App)(s.user)
		ui.next({width = ui.fill(), height = ui.fill()})
		prefs_page.build(&app.page, &app.prefs, {user = app, pages = LICENCE_PAGES[:], licence = &app.licence})
	}})
	prefs_page.licence_init(&app.licence, s.state, {store = {product = SAMPLE_PRODUCT, memory = true}, name = "sample", pricing_url = "https://example.invalid/pricing/"})
	defer prefs_page.licence_end(&app.licence)
	session.wait_text(s, "Unregistered")
	// (the name in lower case starts its sentence in capitals)
	testing.expect(t, session.find_text(s, "Sample is free; a licence supports its development.") != nil, "what a licence is for")
	testing.expect(t, session.find(s, "licence_buy") != nil, "Buy a licence")
	testing.expect(t, session.find(s, "licence_remove") == nil, "nothing to remove")
	testing.expect(t, !prefs_page.licence_registered(&app.licence), "not registered")
	session.click(s, "licence_key")
	session.type_text(s, "SAMPLE1.not.signed")
	session.click(s, "licence_register")
	session.wait_until(s, &app.licence, proc(s: ^session.Session, l: ^prefs_page.Licence) -> bool { return l.problem != "" && !l.busy }, "the key refused")
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, app.licence.problem) != nil, "why it was refused shows")
	testing.expect(t, !prefs_page.licence_registered(&app.licence), "still not registered")
}
