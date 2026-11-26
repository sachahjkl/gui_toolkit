// The setup (src/setup): what the facts make of an install, when a start offers the dialog, and the dialog itself: the
// buttons each state shows, what a choice tells the program. Nothing is installed: the facts are given.
//   odin test tests/setup -collection:gt=src -vet -define:ODIN_TEST_THREADS=1
package setup_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import desktop "gt:desktop"
import i18n "gt:i18n"
import setup "gt:setup"
import "gt:testkit/session"
import "gt:ui"

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

// The setup's view, opened in the first build (`opening`), its events through update at each build.
@(private = "file")
App :: struct {
	d:       setup.Dialog,
	cfg:     setup.Setup_Options,
	event:   setup.Event,
	opening: bool,
	state:   ^ui.State,   // the session's (its Views has the setup's view)
}

@(private = "file")
app_build :: proc(s: ^session.Session) {
	app := (^App)(s.user)
	app.state = s.state
	if app.opening {
		app.opening = false
		setup.open(&app.d, app.cfg)
	}
	if ev := setup.update(&app.d, app.cfg); ev != .None { app.event = ev }
}

@(private = "file")
app_end :: proc(app: ^App) {
	setup.destroy(&app.d)
}

// (the facts are the test's: the controller is open with them, the view takes it over)
@(private = "file")
start :: proc(t: ^testing.T, app: ^App, f: setup.Facts) -> ^session.Session {
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0"}
	app.d.open, app.d.known = true, true
	app.d.facts = f
	app.opening = true
	s := session.start(t, {size = {900, 640}, user = app, build = app_build})
	session.wait_box(s, "setup_scroll")
	return s
}

// The event the view's buttons or its close gave, read by update in a later build.
@(private = "file")
wait_event :: proc(s: ^session.Session) {
	session.wait_until(s, proc(s: ^session.Session) -> bool { return (^App)(s.user).event != .None }, "the event")
}

// A logo given after open (made from a task's answer): the view shows it from then on. (No renderer: the mark is a box
// whose drawing is not read here.)
@(test)
a_logo_given_after_open_shows :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0"}
	app.d.open, app.d.known = true, true
	app.d.facts = {state = .Not_Installed}
	app.opening = true
	s := session.start(t, {size = {900, 640}, user = &app, build = app_build, no_renderer = true})
	session.wait_box(s, "setup_scroll")
	testing.expect(t, session.find(s, "setup_logo") == nil, "no mark yet")
	setup.set_logo(&app.d, setup.Logo{size = {64, 64}})
	session.wait_box(s, "setup_logo")
	setup.set_logo(&app.d, nil)
	session.wait_gone(s, "setup_logo")
}

// The vendor signs the view: "By", its mark when the program gives one, its name; a vendor without a site is its name
// alone, a program without a vendor has no line.
@(test)
the_vendor_signs_the_view :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0", vendor_url = "https://someone.example"}
	app.d.open, app.d.known = true, true
	app.d.facts = {state = .Not_Installed}
	app.opening = true
	s := session.start(t, {size = {900, 640}, user = &app, build = app_build})
	session.wait_box(s, "setup_by_name")
	testing.expect(t, session.find(s, "setup_by_word") != nil, "the line says By")
	testing.expect(t, session.find(s, "setup_by_mark") == nil, "no mark yet")
	mark, made := setup.logo_make(s.renderer, #load("../../site/img/logo.png"))
	testing.expect(t, made, "the PNG makes a mark")
	_, bad := setup.logo_make(s.renderer, transmute([]u8)string("not an image"))
	testing.expect(t, !bad, "other bytes make none")
	held: Maybe(setup.Logo) = mark
	defer setup.logo_destroy(s.renderer, &held)
	setup.set_vendor_mark(&app.d, setup.Logo{mark.texture, {64, 64}})
	session.wait_box(s, "setup_by_mark")
	session.frames(s, 2)
	session.save_png(s, "by.png")
	app.cfg.identity.vendor = ""
	app.d.options = app.cfg
	session.wait_gone(s, "setup_by")
}

@(test)
not_installed_offers_install_and_standalone :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .Not_Installed})
	testing.expect(t, session.find_text(s, "Not installed") != nil, "the state says it")
	testing.expect(t, session.find(s, "setup_install") != nil, "Install")
	testing.expect(t, session.find(s, "setup_uninstall") == nil, "nothing to uninstall")
	session.click(s, "setup_standalone")
	wait_event(s)
	testing.expect_value(t, app.event, setup.Event.Kept_Standalone)
	testing.expect(t, !app.d.open, "and it closes")
	testing.expect(t, !ui.view_is_open(ui.state_views(app.state), setup.VIEW), "its view too")
}

@(test)
an_older_copy_is_offered_an_upgrade :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .Other_Copy, version = strings.clone("0.9.0"), exe_there = true, manifest = true,
		exe = strings.clone(`C:\Users\someone\AppData\Local\Programs\sample\sample.exe`), running = strings.clone(`C:\Users\someone\Downloads\sample-1.0.0-windows-x64\sample.exe`)})
	testing.expect(t, session.find_text(s, "Upgrade to 1.0.0") != nil)
	testing.expect(t, session.find(s, "setup_uninstall") != nil, "the installed copy can be removed")
	session.click(s, "setup_later")
	wait_event(s)
	testing.expect_value(t, app.event, setup.Event.Dismissed)
}

@(test)
the_installed_copy_updates_its_shortcuts :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	testing.expect(t, session.find_text(s, "Installed") != nil)   // (the state's pill: the sentence says no more than it)
	testing.expect(t, session.find_text(s, "Update the shortcuts") != nil)
	session.click(s, "setup_close")
	session.wait_gone(s, "setup_scroll")
	testing.expect(t, !app.d.open)
	testing.expect_value(t, app.event, setup.Event.None)   // (nothing to remember: it is installed)
}

@(test)
escape_dismisses_it_for_this_version :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .Not_Installed})
	session.key(s, .Escape)
	wait_event(s)
	testing.expect(t, !app.d.open)
	testing.expect_value(t, app.event, setup.Event.Dismissed)
}

// A path is copied by its button (or by a click on it); the button shows a check until the pointer leaves.
@(test)
a_path_is_copied :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	path := `C:\Users\someone\AppData\Local\Programs\sample\sample.exe`
	s := start(t, &app, {state = .This_Copy, exe = strings.clone(path), running = strings.clone(path), exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	session.click(s, "copy")
	testing.expect_value(t, session.clipboard(s), path)
	testing.expect(t, app.d.copied != "", "the button shows it")
}

// A newer copy is installed: this one goes back to its version, and says so.
@(test)
a_newer_copy_is_named_as_such :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .Other_Copy, version = strings.clone("1.2.0"), exe_there = true, manifest = true})
	testing.expect(t, session.find_text(s, "A newer copy is installed (1.2.0)") != nil)
	testing.expect(t, session.find_text(s, "Go back to 1.0.0") != nil)
}

// Uninstall asks once: the first click changes the button, Escape takes it back.
@(test)
uninstall_asks_first :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	session.click(s, "setup_uninstall")
	testing.expect(t, session.find_text(s, "Click again to uninstall") != nil)
	testing.expect(t, app.d.job == nil, "nothing is removed yet")
}

// The program's options are boxes; what is ticked is what the dialog keeps for prepare.
@(test)
the_program_s_choices_are_boxes :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := start(t, &app, {state = .Not_Installed})
	app.cfg.choices = []setup.Choice{{label = "Add to PATH", on = true}, {label = "Register as a browser", on = false}}
	app.d.options.choices = app.cfg.choices   // (the view draws with the options it was opened with)
	append(&app.d.choices, true, false)
	session.frames(s, 2)
	testing.expect(t, session.find_text(s, "Register as a browser") != nil)
	session.click(s, "setup_choice_1")
	testing.expect(t, app.d.choices[1], "ticked")
}

@(private = "file")
Scratch :: struct { root, install: string }

// Everything an install touches in a folder of the test's own.
@(private = "file")
scratch_prepare :: proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	sc := (^Scratch)(user)
	o.applications_dir = fmt.tprintf("%s/share/applications", sc.root)
	o.icons_dir = fmt.tprintf("%s/share/icons/hicolor", sc.root)
	o.bin_dir = fmt.tprintf("%s/bin", sc.root)
	o.autostart_dir = fmt.tprintf("%s/config/autostart", sc.root)
	o.config_dir = fmt.tprintf("%s/config", sc.root)
	o.thumbnailers_dir = fmt.tprintf("%s/share/thumbnailers", sc.root)
	o.desktop_dir = fmt.tprintf("%s/Desktop", sc.root)
	o.menu_dir = fmt.tprintf("%s/menu", sc.root)
	o.install_dir = sc.install
	o.machine_root = fmt.tprintf("%s/machine", sc.root)   // (an install for everyone: never the real /opt and /usr/local)
	o.notify_system = false
}

// The dialog reads the install on its thread, then follows the disk: a copy put in the install folder by something else
// shows at once (the watch), with nothing clicked.
@(test)
the_dialog_reads_on_its_thread_and_follows_the_disk :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	sc := Scratch{root = fmt.tprintf("%s/tk_setup_%d", tmp != "" ? tmp : "/tmp", time.now()._nsec)}
	sc.install = fmt.tprintf("%s/programs/sample", sc.root)
	testing.expect(t, os.make_directory_all(sc.root) == nil)
	defer os.remove_all(sc.root)
	app: App
	defer app_end(&app)
	s := session.start(t, {size = {900, 640}, user = &app, build = app_build})
	app.cfg = {identity = desktop.Identity{name = "Sample", slug = "sample", exe_name = "sample", manifest_name = "sample_install.txt"},
		version = "1.0.0", prepare = scratch_prepare, user = &sc}
	app.opening = true   // (the next build opens it: the facts are read on the dialog's thread)
	session.wait_text(s, "Not installed")   // (the state's pill: the facts are read)
	testing.expect(t, app.d.known)
	testing.expect(t, app.d.watcher != nil, "the install is watched")
	// something else puts a program there
	testing.expect(t, os.make_directory_all(sc.install) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sample", sc.install), transmute([]byte)string("x")) == nil)
	session.wait_text(s, "earlier setup")
	session.key(s, .Escape)
	session.wait_until(s, proc(s: ^session.Session) -> bool { return !(^App)(s.user).d.open }, "Escape to close it")
	session.frames(s, 2)
	testing.expect(t, app.d.watcher == nil, "closed: no longer watched")
}

// A program that draws its own screen asks the controller what to offer and closes through it: the same answers as the
// dialog's.
@(test)
a_screen_of_its_own_asks_the_controller :: proc(t: ^testing.T) {
	cfg := setup.Setup_Options{identity = desktop.Identity{name = "Sample"}, version = "1.0.0"}
	d: setup.Dialog
	defer setup.destroy(&d)
	d.open, d.known = true, true
	d.facts = {state = .Not_Installed}
	title, badge := setup.headline(d.facts, cfg)
	testing.expect_value(t, title, "Install Sample")
	testing.expect_value(t, badge, "Not installed")
	testing.expect_value(t, setup.install_label(&d, cfg), "Install")
	testing.expect(t, !setup.can_uninstall(&d), "nothing to uninstall")
	testing.expect(t, !setup.busy(&d))
	testing.expect_value(t, setup.closing(&d, cfg), setup.Closing.Keep_Standalone)
	testing.expect_value(t, setup.close(&d, .Keep_Standalone), setup.Event.Kept_Standalone)
	testing.expect(t, !d.open, "closed")
	testing.expect_value(t, setup.close(&d, .Close), setup.Event.None)   // (closed already: nothing)

	d.open = true
	d.facts = {state = .Other_Copy, version = "0.9.0", exe_there = true, manifest = true}
	testing.expect_value(t, setup.install_label(&d, cfg), "Upgrade to 1.0.0")
	testing.expect(t, setup.can_uninstall(&d))
	testing.expect_value(t, setup.closing(&d, cfg), setup.Closing.Not_Now)
	testing.expect_value(t, setup.close(&d, .Not_Now), setup.Event.Dismissed)

	d.open = true
	d.facts = {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true}
	testing.expect_value(t, setup.install_label(&d, cfg), "Update the shortcuts")
	testing.expect_value(t, setup.close(&d, .Close), setup.Event.None)   // (installed: nothing to remember)
	d.open = true
	d.facts = {state = .Not_Installed}
	testing.expect_value(t, setup.close(&d, .Close), setup.Event.Dismissed)   // (no answer: not again for this version)
}

// After an update the installed copy says its new version; a copy elsewhere changes nothing.
@(test)
an_update_of_the_installed_copy_is_recorded :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	sc := Scratch{root = fmt.tprintf("%s/tk_setup_upd_%d", tmp != "" ? tmp : "/tmp", time.now()._nsec)}
	sc.install = fmt.tprintf("%s/programs/sample", sc.root)
	testing.expect(t, os.make_directory_all(sc.root) == nil)
	defer os.remove_all(sc.root)
	cfg := setup.Setup_Options{identity = desktop.Identity{
		name = "Sample", key = "Sample", slug = "sample", aumid = "GuiToolkit.Sample.Test", description = "A test.",
		vendor = "Gui Toolkit", exe_name = "sample", entry_marker = "X-Sample-Integration", registry_mark = "SampleIntegration",
		vendor_key = "GuiToolkitTest", manifest_name = "sample_install.txt", manifest_header = "# Written by the setup tests.",
		env_prefix = "SAMPLE_DESKTOP_", watch_thread_name = "sample-watch", cleanup_name = "sample_cleanup",
	}, version = "1.0.0", prepare = scratch_prepare, user = &sc}
	ok, exe := setup.install(cfg, false)
	testing.expectf(t, ok, "installed: %s", exe)
	exe = strings.clone(exe, context.temp_allocator)
	testing.expect_value(t, setup.facts(cfg).version, "1.0.0")

	ok, _ = setup.updated(cfg, "1.1.0", exe = fmt.tprintf("%s/elsewhere/sample", sc.root))
	testing.expect(t, ok)
	testing.expect_value(t, setup.facts(cfg).version, "1.0.0")   // (not the installed copy: nothing)

	why: string
	ok, why = setup.updated(cfg, "1.1.0", exe = exe)
	testing.expectf(t, ok, "recorded: %s", why)
	testing.expect_value(t, setup.facts(cfg).version, "1.1.0")
}

// A long label of an option wraps in its tile, never past it: one option per line, its tile as tall as its lines.
@(test)
a_long_option_stays_in_its_tile :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	LONG :: "Start with the session, in the notification area, and keep the history of the clipboard from the first copy"
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0", choices = []setup.Choice{{label = LONG, on = true}, {label = "Add to PATH"}}}
	append(&app.d.choices, true, false)
	app.d.open, app.d.known = true, true
	app.d.facts = {state = .Not_Installed}
	app.opening = true
	s := session.start(t, {size = {560, 760}, user = &app, build = app_build})
	session.frames(s, 3)
	session.save_png(s, "options.png")
	tile := session.find(s, "setup_tile_1")
	words := session.find_text(s, LONG)
	testing.expect(t, tile != nil && words != nil)
	if tile == nil || words == nil { return }
	testing.expectf(t, words.rect.max.x <= tile.rect.max.x && words.rect.max.y <= tile.rect.max.y, "inside: %v in %v", words.rect, tile.rect)
	testing.expect(t, words.rect.max.y - words.rect.min.y > ui.font_size() * 1.8, "on more than one line")
}

// Install for everyone on a test's machine (no administrator: the machine root is the test's), then the move back to
// the person: one install at a time, the other goes once the new one is in place; Uninstall removes what is there.
@(test)
an_install_for_everyone_moves_and_comes_back :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	sc := Scratch{root = fmt.tprintf("%s/tk_setup_scope_%d", tmp != "" ? tmp : "/tmp", time.now()._nsec)}
	sc.install = fmt.tprintf("%s/programs/sample", sc.root)
	testing.expect(t, os.make_directory_all(sc.root) == nil)
	defer os.remove_all(sc.root)
	cfg := setup.Setup_Options{identity = desktop.Identity{
		name = "Sample", key = "Sample", slug = "sample", aumid = "GuiToolkit.Sample.Test", description = "A test.",
		vendor = "Gui Toolkit", exe_name = "sample", entry_marker = "X-Sample-Integration", registry_mark = "SampleIntegration",
		vendor_key = "GuiToolkitTest", manifest_name = "sample_install.txt", manifest_header = "# Written by the setup tests.",
		env_prefix = "SAMPLE_DESKTOP_", watch_thread_name = "sample-watch", cleanup_name = "sample_cleanup",
	}, version = "1.0.0", prepare = scratch_prepare, user = &sc}
	everyone := fmt.tprintf("%s/machine/opt/GuiToolkitTest/Sample/sample", sc.root)
	entry := fmt.tprintf("%s/machine/usr/local/share/applications/sample.desktop", sc.root)

	f := setup.facts(cfg, scope = .System)
	testing.expect_value(t, f.state, setup.State.Not_Installed)
	testing.expect_value(t, f.scope, desktop.Scope.System)   // (none there: the scope asked, and where it would go)
	testing.expect_value(t, f.exe, everyone)

	shortcut := fmt.tprintf("%s/Desktop/sample.desktop", sc.root)
	ok, exe := setup.install(cfg, true, scope = .System)
	testing.expectf(t, ok, "installed for everyone: %s", exe)
	testing.expect(t, os.is_file(shortcut), "the person's shortcut")
	testing.expect_value(t, exe, everyone)
	testing.expect(t, os.is_file(everyone) && os.is_file(entry), "the program and its entry, for every account")
	f = setup.facts(cfg)
	testing.expect_value(t, f.scope, desktop.Scope.System)
	testing.expect(t, f.exe_there && f.manifest && !f.other_scope, "one install, for everyone")

	// back to the person: theirs first, then the one for everyone goes
	ok, exe = setup.install(cfg, true, scope = .User)
	testing.expectf(t, ok, "installed for me: %s", exe)
	testing.expect(t, !os.exists(everyone) && !os.exists(entry), "the install for everyone is gone")
	// (the shortcut has one name in both scopes: the removal of the old one must not take the new one's)
	text, _ := os.read_entire_file(shortcut, context.temp_allocator)
	testing.expectf(t, strings.contains(string(text), exe), "the shortcut runs the person's copy: %s", string(text))
	f = setup.facts(cfg)
	testing.expect_value(t, f.scope, desktop.Scope.User)
	testing.expect(t, f.exe_there && !f.other_scope)

	// and for everyone again, then Uninstall removes it
	testing.expect(t, setup.install_there(cfg, .User), "the person's install is there before the move")
	ok, exe = setup.install(cfg, true, scope = .System)
	testing.expectf(t, ok, "%s", exe)
	testing.expect(t, !setup.install_there(cfg, .User), "the person's install is gone")
	text, _ = os.read_entire_file(shortcut, context.temp_allocator)
	testing.expectf(t, strings.contains(string(text), everyone), "the shortcut runs the copy for everyone: %s", string(text))
	testing.expect(t, !os.exists(fmt.tprintf("%s/sample", sc.install)), "the person's copy is gone")
	removed, leftovers, why := setup.uninstall(cfg)
	defer { for l in leftovers { delete(l) }; delete(leftovers) }
	testing.expectf(t, removed, "uninstalled: %s", why)
	testing.expect(t, !os.exists(everyone), "nothing left for everyone")
	testing.expect_value(t, setup.facts(cfg).state, setup.State.Not_Installed)
}

// A program that must stay the person's offers one scope: no switch, and Install for everyone is refused.
@(test)
a_program_can_stay_the_person_s :: proc(t: ^testing.T) {
	cfg := setup.Setup_Options{identity = desktop.Identity{name = "Sample"}, version = "1.0.0", scopes = {.User}}
	testing.expect_value(t, setup.offered_scopes(cfg), desktop.Scopes{.User})
	ok, _ := setup.install(cfg, false, scope = .System)
	testing.expect(t, !ok, "not offered")
}

// The switch: "For me" and "For everyone", what each means here; the move when an install of the other scope is
// there. Everyone not possible (NixOS): greyed on "For me", the reason under it.
@(test)
the_scope_switch :: proc(t: ^testing.T) {
	app: App
	defer app_end(&app)
	s := shot_start(t, &app, {state = .Not_Installed, exe = "/home/you/.local/opt/FromentSoftware/Sample/sample"}, ui.palette_of("Midnight"))
	session.wait_box(s, "setup_scope_me")
	testing.expect(t, session.find_text(s, "Everyone on this computer") != nil)
	testing.expect_value(t, setup.install_label(&app.d, app.cfg), "Install")
	app.d.scope = .System
	session.frames(s, 2)
	testing.expect(t, session.find(s, "setup_scope_everyone_words") != nil, "what everyone means here")
	// installed for the person, everyone chosen: the move
	delete(app.d.facts.exe)
	app.d.facts = facts_owned({state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true, exe = "/home/you/.local/opt/FromentSoftware/Sample/sample"})
	session.frames(s, 2)
	testing.expect_value(t, setup.install_label(&app.d, app.cfg), "Install for everyone")
	// NixOS: no install for everyone but the Nix package
	delete(app.d.facts.exe)
	app.d.facts = {state = .Not_Installed, system_refusal = .Nix}
	session.frames(s, 2)
	testing.expect_value(t, app.d.scope, desktop.Scope.User)
}

// The example of the switch for the owner: the dialog and the Installation page, each scope, dark and light, the move,
// and NixOS. Written to build/session/<test>/ (save_png).
@(test)
the_scope_switch_shots :: proc(t: ^testing.T) {
	// (each picture a session of its own; the sessions end with the test, so what they draw lives as long)
	apps: [dynamic]^App
	pages: [dynamic]^Page_App
	defer {
		for app in apps { app_end(app); free(app) }
		for pg in pages { setup.destroy(&pg.d); free(pg) }
		delete(apps); delete(pages)
	}
	dialog_shot :: proc(t: ^testing.T, apps: ^[dynamic]^App, f: setup.Facts, scope: desktop.Scope, light: bool, name: string) {
		app := new(App)
		append(apps, app)
		s := shot_start(t, app, f, ui.palette_of(SHOT_THEME, light))
		app.d.scope = scope
		session.wait_box(s, "setup_scope_me")
		session.frames(s, 3)
		session.save_png(s, name)
	}
	for light in ([2]bool{false, true}) {
		mode := light ? "light" : "dark"
		for scope in desktop.Scope {
			who := scope == .System ? "everyone" : "me"
			f := setup.Facts{state = .Not_Installed, running = "/home/you/Downloads/sample", scope = scope,
				exe = scope == .System ? "/opt/FromentSoftware/Sample/sample" : "/home/you/.local/opt/FromentSoftware/Sample/sample"}
			dialog_shot(t, &apps, f, scope, light, fmt.tprintf("dialog_%s_%s.png", who, mode))
			pg := new(Page_App)
			append(&pages, pg)
			s := page_start(t, pg, f, ui.palette_of(SHOT_THEME, light))
			pg.d.scope = scope
			session.wait_box(s, "setup_scope_me")
			session.frames(s, 3)
			session.save_png(s, fmt.tprintf("page_%s_%s.png", who, mode))
		}
	}
	// installed for me, everyone chosen: the move; NixOS: everyone not possible
	here := "/home/you/.local/opt/FromentSoftware/Sample/sample"
	dialog_shot(t, &apps, {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true,
		exe = here, running = here, version = "1.0.0"}, .System, false, "dialog_move_dark.png")
	dialog_shot(t, &apps, {state = .Not_Installed, system_refusal = .Nix, running = "/home/you/Downloads/sample", exe = here, nixos = true},
		.User, false, "dialog_nixos_dark.png")
	// the words in French: the toolkit's, and the sample program's own (its boxes' labels are its words, which its
	// catalogue translates)
	fr, bad := i18n.load("fr", {{"fr", SAMPLE_FRENCH}})
	defer { i18n.use(nil); i18n.destroy(fr) }
	testing.expect_value(t, len(bad), 0)
	i18n.use(fr)
	dialog_shot(t, &apps, {state = .Not_Installed, running = "/home/you/Downloads/sample", scope = .System, exe = "/opt/FromentSoftware/Sample/sample"},
		.System, false, "dialog_everyone_dark_fr.png")
	pg := new(Page_App)
	append(&pages, pg)
	s := page_start(t, pg, {state = .Not_Installed, running = "/home/you/Downloads/sample", exe = here}, ui.palette_of(SHOT_THEME, true))
	session.wait_box(s, "setup_scope_me")
	session.frames(s, 3)
	session.save_png(s, "page_me_light_fr.png")
}

@(private = "file") SHOT_THEME :: "Ember"

// The sample program's catalogue: its description and the labels of its boxes (shot_options).
@(private = "file")
SAMPLE_FRENCH :: `en A program made with the toolkit.
fr Un programme fait avec la boîte à outils.

en Put the program on the PATH
fr Mettre le programme dans le PATH

en Open text files with Sample
fr Ouvrir les fichiers texte avec Sample
`

// Facts whose strings the dialog owns (it frees them when it reads the install again, and at its end).
@(private = "file")
facts_owned :: proc(f: setup.Facts) -> setup.Facts {
	o := f
	o.dir, o.exe, o.running, o.version = strings.clone(f.dir), strings.clone(f.exe), strings.clone(f.running), strings.clone(f.version)
	return o
}

// The options of the pictures: a program with a vendor, a description, two boxes.
@(private = "file")
shot_options :: proc() -> setup.Setup_Options {
	// (in the test's memory: a slice literal here would live on this procedure's stack)
	choices := make([]setup.Choice, 2, context.temp_allocator)
	choices[0] = {label = "Put the program on the PATH", on = true, parts = {.Path}}
	choices[1] = {label = "Open text files with Sample", parts = {.Documents}}
	return {
		identity = desktop.Identity{name = "Sample", vendor = "Froment Software", description = "A program made with the toolkit."},
		version = "1.0.0", vendor_url = "https://example.org", choices = choices,
	}
}

// The dialog with given facts (nothing read from the disk), in a palette.
@(private = "file")
shot_start :: proc(t: ^testing.T, app: ^App, f: setup.Facts, palette: ui.Palette) -> ^session.Session {
	app.cfg = shot_options()
	app.d.open, app.d.known = true, true
	app.d.facts = facts_owned(f)
	app.d.scope = f.scope
	app.d.shortcut = true
	for c in app.cfg.choices { append(&app.d.choices, c.on) }
	app.opening = true
	s := session.start(t, {size = {900, 720}, user = app, build = app_build, palette = palette})
	session.wait_box(s, "setup_scroll")
	return s
}

// The Installation page of the settings: the same Dialog in the flow of a page.
@(private = "file")
Page_App :: struct {
	d:   setup.Dialog,
	cfg: setup.Setup_Options,
}

@(private = "file")
page_build :: proc(s: ^session.Session) {
	pg := (^Page_App)(s.user)
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
	if ui.row(id = "###page_host") {
		ui.space(ui.PAGE_MARGIN)
		ui.next({width = ui.fill(), height = ui.fill()})
		if ui.scroll_y("###page_scroll") {
			ui.space(ui.PAGE_MARGIN)
			_ = setup.page(&pg.d, pg.cfg, em)
		}
		ui.space(ui.PAGE_MARGIN)
	}
}

@(private = "file")
page_start :: proc(t: ^testing.T, pg: ^Page_App, f: setup.Facts, palette: ui.Palette) -> ^session.Session {
	pg.cfg = shot_options()
	pg.d.open, pg.d.known, pg.d.in_page = true, true, true
	pg.d.facts = facts_owned(f)
	pg.d.scope = f.scope
	pg.d.shortcut = true
	for c in pg.cfg.choices { append(&pg.d.choices, c.on) }
	s := session.start(t, {size = {760, 760}, user = pg, build = page_build, palette = palette})
	session.wait_box(s, "setup_page")
	return s
}
