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
	testing.expect(t, session.find_text(s, "this is the installed copy") != nil)
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
	o.desktop_dir = fmt.tprintf("%s/Desktop", sc.root)
	o.menu_dir = fmt.tprintf("%s/menu", sc.root)
	o.install_dir = sc.install
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
	session.wait_text(s, "Install Sample")   // (the title the facts give: "not installed" is also in the line of the versions)
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
