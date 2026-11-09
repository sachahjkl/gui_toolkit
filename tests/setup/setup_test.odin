// The setup (src/setup): what the facts make of an install, when a start offers the dialog, and the dialog itself: the
// buttons each state shows, what a choice tells the program. Nothing is installed: the facts are given.
//   odin test tests/setup -vet -define:ODIN_TEST_THREADS=1
package setup_test

import "core:strings"
import "core:testing"
import desktop "../../src/desktop"
import setup "../../src/setup"
import "../../src/testkit/session"
import "../../src/ui"

@(test)
the_facts_make_a_state :: proc(t: ^testing.T) {
	testing.expect_value(t, setup.state_of({}), setup.State.Not_Installed)
	testing.expect_value(t, setup.state_of({start_lnk = true}), setup.State.Repair)   // (no program, a launcher left)
	testing.expect_value(t, setup.state_of({exe_there = true}), setup.State.Repair)   // (no manifest)
	testing.expect_value(t, setup.state_of({exe_there = true, manifest = true}), setup.State.Other_Copy)
	testing.expect_value(t, setup.state_of({exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true}), setup.State.This_Copy)
	testing.expect_value(t, setup.state_of({exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true, missing = 1}), setup.State.Repair)
}

@(test)
a_start_offers_it_when_there_is_something_to_do :: proc(t: ^testing.T) {
	none := setup.Facts{state = .Not_Installed}
	testing.expect(t, setup.wanted(none, "1.0.0", ""))
	testing.expect(t, !setup.wanted(none, "1.0.0", setup.CHOICE_STANDALONE), "standalone: not asked again")
	testing.expect(t, !setup.wanted(none, "1.0.0", setup.choice_dismissed("1.0.0")), "closed for this version")
	testing.expect(t, setup.wanted(none, "1.1.0", setup.choice_dismissed("1.0.0")), "a new version asks again")
	older := setup.Facts{state = .Other_Copy, version = "0.9.2"}
	testing.expect(t, setup.wanted(older, "1.0.0", setup.CHOICE_STANDALONE), "an upgrade is offered even to a standalone copy")
	testing.expect(t, !setup.wanted({state = .Other_Copy, version = "1.0.0"}, "1.0.0", ""), "the same version elsewhere")
	testing.expect(t, !setup.wanted({state = .This_Copy}, "1.0.0", ""))
	testing.expect(t, !setup.wanted({state = .Not_Installed, from_nix = true}, "1.0.0", ""), "never a copy of the Nix store")
	testing.expect(t, setup.version_older("0.9.10", "0.10.0"))
	testing.expect(t, !setup.version_older("1.0", "1.0.0"))
	testing.expect(t, !setup.version_older("x", "1.0.0"))
}

@(private = "file")
App :: struct {
	d:     setup.Dialog,
	cfg:   setup.Config,
	event: setup.Event,
}

@(private = "file")
start :: proc(t: ^testing.T, app: ^App, f: setup.Facts) -> ^session.Session {
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0"}
	app.d.open = true
	app.d.facts = f
	return session.start(t, {size = {900, 640}, user = app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ev := setup.dialog(&app.d, app.cfg, ui.font_size()); ev != .None { app.event = ev }
	}})
}

@(test)
not_installed_offers_install_and_standalone :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .Not_Installed})
	testing.expect(t, session.find_text(s, "Not installed") != nil, "the state says it")
	testing.expect(t, session.find(s, "setup_install") != nil, "Install")
	testing.expect(t, session.find(s, "setup_uninstall") == nil, "nothing to uninstall")
	session.click(s, "setup_standalone")
	testing.expect_value(t, app.event, setup.Event.Kept_Standalone)
	testing.expect(t, !app.d.open, "and it closes")
}

@(test)
an_older_copy_is_offered_an_upgrade :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .Other_Copy, version = strings.clone("0.9.0"), exe_there = true, manifest = true,
		exe = strings.clone(`C:\Users\someone\AppData\Local\Programs\sample\sample.exe`), running = strings.clone(`C:\Users\someone\Downloads\sample-1.0.0-windows-x64\sample.exe`)})
	testing.expect(t, session.find_text(s, "Upgrade to 1.0.0") != nil)
	testing.expect(t, session.find(s, "setup_uninstall") != nil, "the installed copy can be removed")
	session.click(s, "setup_later")
	testing.expect_value(t, app.event, setup.Event.Dismissed)
}

@(test)
the_installed_copy_updates_its_shortcuts :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	testing.expect(t, session.find_text(s, "this is the installed copy") != nil)
	testing.expect(t, session.find_text(s, "Update the shortcuts") != nil)
	session.click(s, "setup_close")
	testing.expect(t, !app.d.open)
	testing.expect_value(t, app.event, setup.Event.None)   // (nothing to remember: it is installed)
}

@(test)
escape_dismisses_it_for_this_version :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .Not_Installed})
	session.key(s, .Escape)
	testing.expect(t, !app.d.open)
	testing.expect_value(t, app.event, setup.Event.Dismissed)
}
