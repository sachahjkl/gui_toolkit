// The setup (src/setup): what the facts make of an install, when a start offers the dialog, and the dialog itself: the
// buttons each state shows, what a choice tells the program. Nothing is installed: the facts are given.
//   odin test tests/setup -vet -define:ODIN_TEST_THREADS=1
package setup_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
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
	app.d.open, app.d.known = true, true
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

// A path is copied by its button (or by a click on it); the button shows a check until the pointer leaves.
@(test)
a_path_is_copied :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	path := `C:\Users\someone\AppData\Local\Programs\sample\sample.exe`
	s := start(t, &app, {state = .This_Copy, exe = strings.clone(path), running = strings.clone(path), exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	session.click(s, "copy")
	testing.expect_value(t, ui.window_clipboard_get(), path)
	testing.expect(t, app.d.copied != "", "the button shows it")
}

// A newer copy is installed: this one goes back to its version, and says so.
@(test)
a_newer_copy_is_named_as_such :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .Other_Copy, version = strings.clone("1.2.0"), exe_there = true, manifest = true})
	testing.expect(t, session.find_text(s, "A newer copy is installed (1.2.0)") != nil)
	testing.expect(t, session.find_text(s, "Go back to 1.0.0") != nil)
}

// Uninstall asks once: the first click changes the button, Escape takes it back.
@(test)
uninstall_asks_first :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .This_Copy, exe_there = true, manifest = true, running_it = true, start_lnk = true, record = true})
	session.click(s, "setup_uninstall")
	testing.expect(t, session.find_text(s, "Click again to uninstall") != nil)
	testing.expect(t, app.d.job == nil, "nothing is removed yet")
}

// The program's options are boxes; what is ticked is what the dialog keeps for prepare.
@(test)
the_program_s_choices_are_boxes :: proc(t: ^testing.T) {
	app: App
	defer setup.destroy(&app.d)
	s := start(t, &app, {state = .Not_Installed})
	app.cfg.choices = []setup.Choice{{label = "Add to PATH", on = true}, {label = "Register as a browser", on = false}}
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
scratch_prepare :: proc(o: ^desktop.Options, choices: []bool, user: rawptr) {
	sc := (^Scratch)(user)
	o.applications_dir = fmt.tprintf("%s/share/applications", sc.root)
	o.icons_dir = fmt.tprintf("%s/share/icons/hicolor", sc.root)
	o.bin_dir = fmt.tprintf("%s/bin", sc.root)
	o.autostart_dir = fmt.tprintf("%s/config/autostart", sc.root)
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
	defer setup.destroy(&app.d)
	s := session.start(t, {size = {900, 640}, user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ev := setup.dialog(&app.d, app.cfg, ui.font_size()); ev != .None { app.event = ev }
	}})
	app.cfg = {identity = desktop.Identity{name = "Sample", slug = "sample", exe_name = "sample", manifest_name = "sample_install.txt"},
		version = "1.0.0", prepare = scratch_prepare, user = &sc}
	setup.open(&app.d, app.cfg)
	session.wait_text(s, "Install Sample")   // (the title the facts give: "not installed" is also in the line of the versions)
	testing.expect(t, app.d.known)
	testing.expect(t, app.d.watcher != nil, "the install is watched")
	// something else puts a program there
	testing.expect(t, os.make_directory_all(sc.install) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sample", sc.install), transmute([]byte)string("x")) == nil)
	session.wait_text(s, "earlier setup")
	session.key(s, .Escape)
	session.frames(s, 2)
	testing.expect(t, app.d.watcher == nil, "closed: no longer watched")
}

// A program that draws its own screen asks the controller what to offer and closes through it: the same answers as the
// dialog's.
@(test)
a_screen_of_its_own_asks_the_controller :: proc(t: ^testing.T) {
	cfg := setup.Config{identity = desktop.Identity{name = "Sample"}, version = "1.0.0"}
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
	cfg := setup.Config{identity = desktop.Identity{
		name = "Sample", key = "Sample", slug = "sample", aumid = "GuiToolkit.Sample.Test", description = "A test.",
		vendor = "Gui Toolkit", exe_name = "sample", entry_marker = "X-Sample-Integration", registry_mark = "SampleIntegration",
		vendor_key = "GuiToolkitTest", manifest_name = "sample_install.txt", manifest_header = "# Written by the setup tests.",
		cli_flag = "--desktop-integration", env_prefix = "SAMPLE_DESKTOP_", watch_thread_name = "sample-watch", cleanup_name = "sample_cleanup",
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
	defer setup.destroy(&app.d)
	LONG :: "Start with the session, in the notification area, and keep the history of the clipboard from the first copy"
	app.cfg = {identity = desktop.Identity{name = "Sample", vendor = "Someone"}, version = "1.0.0", choices = []setup.Choice{{label = LONG, on = true}, {label = "Add to PATH"}}}
	append(&app.d.choices, true, false)
	app.d.open, app.d.known = true, true
	app.d.facts = {state = .Not_Installed}
	s := session.start(t, {size = {560, 760}, user = &app, build = proc(s: ^session.Session) {
		app := (^App)(s.user)
		if ev := setup.dialog(&app.d, app.cfg, ui.font_size()); ev != .None { app.event = ev }
	}})
	session.frames(s, 3)
	session.save_png(s, "options.png")
	tile := session.find(s, "setup_tile_1")
	words := session.find_text(s, LONG)
	testing.expect(t, tile != nil && words != nil)
	if tile == nil || words == nil { return }
	testing.expectf(t, words.rect.max.x <= tile.rect.max.x && words.rect.max.y <= tile.rect.max.y, "inside: %v in %v", words.rect, tile.rect)
	testing.expect(t, words.rect.max.y - words.rect.min.y > ui.font_size() * 1.8, "on more than one line")
}
