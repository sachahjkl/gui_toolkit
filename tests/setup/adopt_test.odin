// A program that changed its name takes over its earlier install and folders at the start (setup.adopt_earlier,
// src/md/features/identity-change.md), on Linux, in a temporary home: its XDG folders, its menu, its PATH and its
// install folders are the test's, never the person's.
package setup_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import desktop "gt:desktop"
import fsx "gt:fsx"
import platform "gt:platform"
import setup "gt:setup"

@(private = "file")
Home :: struct {
	root:  string,
	saved: [6]Saved,
}

@(private = "file")
Saved :: struct { name, value: string, had: bool }

@(private = "file")
VARIABLES :: [6]string{"HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"}

// A home of the test's: HOME and the XDG folders in a fresh temporary folder, put back by home_end.
@(private = "file")
home_start :: proc(name: string) -> (h: Home) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	h.root = fmt.aprintf("%s/tk_setup_%s_%d", tmp != "" ? tmp : "/tmp", name, time.now()._nsec)
	vars := VARIABLES
	for v, i in vars {
		value, had := os.lookup_env(v, context.allocator)
		h.saved[i] = {v, value, had}
	}
	_ = os.make_directory_all(h.root)
	os.set_env("HOME", fmt.tprintf("%s/home", h.root))
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/home/.config", h.root))
	os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/home/.local/share", h.root))
	os.set_env("XDG_STATE_HOME", fmt.tprintf("%s/home/.local/state", h.root))
	os.set_env("XDG_CACHE_HOME", fmt.tprintf("%s/home/.cache", h.root))
	os.set_env("XDG_RUNTIME_DIR", fmt.tprintf("%s/run", h.root))
	return
}

@(private = "file")
home_end :: proc(h: ^Home) {
	for s in h.saved {
		if s.had { os.set_env(s.name, s.value) } else { os.unset_env(s.name) }
		delete(s.value)
	}
	os.remove_all(h.root)
	delete(h.root)
}

// Every place of an install in the test's home: the menu, the icons, the PATH's link, the autostart, the desktop, the
// install folder per identity (programs/<slug>), the machine's places.
@(private = "file")
home_prepare :: proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	h := (^Home)(user)
	o.applications_dir = fmt.tprintf("%s/home/.local/share/applications", h.root)
	o.icons_dir = fmt.tprintf("%s/home/.local/share/icons/hicolor", h.root)
	o.bin_dir = fmt.tprintf("%s/home/.local/bin", h.root)
	o.autostart_dir = fmt.tprintf("%s/home/.config/autostart", h.root)
	o.config_dir = fmt.tprintf("%s/home/.config", h.root)
	o.thumbnailers_dir = fmt.tprintf("%s/home/.local/share/thumbnailers", h.root)
	o.desktop_dir = fmt.tprintf("%s/home/Desktop", h.root)
	o.install_dir = fmt.tprintf("%s/home/.local/opt/%s", h.root, o.identity.slug)
	o.machine_root = fmt.tprintf("%s/machine", h.root)
	o.notify_system = false
	o.autostart = true
	if len(choices) > 0 { o.add_to_path = choices[0] }
}

@(private = "file")
identity_named :: proc(name, key, slug: string) -> desktop.Identity {
	return {
		name = name, key = key, slug = slug, aumid = fmt.tprintf("GuiToolkit.%s.Test", key), description = "A test.",
		vendor = "Gui Toolkit", exe_name = slug, entry_marker = fmt.tprintf("X-%s-Integration", key),
		registry_mark = fmt.tprintf("%sIntegration", key), vendor_key = "GuiToolkitTest",
		manifest_name = fmt.tprintf("%s_install.txt", slug), manifest_header = "# Written by the setup tests.",
		watch_thread_name = "adopt-watch", cleanup_name = fmt.tprintf("%s_cleanup", slug),
	}
}

@(private = "file")
EARLIER_FOLDER :: "GuiToolkitTest" + platform.USER_DIR_SEPARATOR + "OldApp"
@(private = "file")
NEW_FOLDER :: "GuiToolkitTest" + platform.USER_DIR_SEPARATOR + "NewApp"

// The program under its earlier name, and under its new one with that earlier name to adopt. The box of the PATH is
// off by default in the new one: its value comes from the earlier install.
@(private = "file")
programs :: proc(h: ^Home, earlier_folder := EARLIER_FOLDER, prepare := home_prepare) -> (earlier, current: setup.Setup_Options) {
	old := identity_named("Old App", "OldApp", "old-app")
	choices := make([]setup.Choice, 1, context.temp_allocator)
	choices[0] = {label = "PATH", on = false, parts = {.Path}}
	earlier = {identity = old, version = "1.4.0", prepare = prepare, user = h, choices = choices, program_folder = earlier_folder}
	list := make([]setup.Earlier, 1, context.temp_allocator)
	list[0] = {identity = old, program_folder = earlier_folder}
	current = {identity = identity_named("New App", "NewApp", "new-app"), version = "2.0.0", prepare = prepare, user = h,
		choices = choices, program_folder = NEW_FOLDER, earlier = list}
	return
}

@(private = "file")
put :: proc(path, text: string) {
	_ = os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
read :: proc(path: string) -> string {
	data, _ := os.read_entire_file(path, context.temp_allocator)
	return string(data)
}

// The update bridge put the new program in the earlier install's folder; its start adopts: the new install with the
// earlier one's choices, the earlier one gone with its menu entry, its link and its autostart, the settings moved, and
// the adopted copy started in its place, which says the news once.
@(test)
an_earlier_install_is_adopted :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt")
	defer home_end(&h)
	earlier, current := programs(&h)
	home := fmt.tprintf("%s/home", h.root)

	ok, old_exe := setup.install(earlier, true, []bool{true})
	testing.expectf(t, ok, "the earlier install: %s", old_exe)
	old_exe = strings.clone(old_exe, context.temp_allocator)
	old_entry := fmt.tprintf("%s/.local/share/applications/old-app.desktop", home)
	old_link := fmt.tprintf("%s/.local/bin/old-app", home)
	testing.expect(t, os.is_file(old_entry) && os.exists(old_link), "the earlier menu entry and command")
	put(fmt.tprintf("%s/.config/%s/prefs.ini", home, EARLIER_FOLDER), "theme = dusk\n")
	put(fmt.tprintf("%s/.local/state/%s/logs/old-app.log", home, EARLIER_FOLDER), "a line\n")

	// (the running program is the earlier install's file: the update bridge placed it there)
	a := setup.adopt_earlier(current, exe = old_exe)
	defer setup.adoption_destroy(&a)
	testing.expect_value(t, a.install, setup.Adopt_Outcome.Done)
	testing.expect_value(t, a.folders, setup.Adopt_Outcome.Done)
	new_dir := fmt.tprintf("%s/.local/opt/new-app", home)
	new_exe := fmt.tprintf("%s/new-app", new_dir)
	testing.expect_value(t, a.relaunch, new_exe)
	testing.expect(t, !a.news, "the adopted copy says it, not this one")

	testing.expect(t, os.is_file(new_exe), "the program in its new folder")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/opt/old-app", home)), "the earlier folder is gone")
	testing.expect(t, !os.exists(old_entry) && !os.exists(old_link), "the earlier menu entry and command are gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.config/autostart/old-app.desktop", home)), "the earlier autostart is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/Desktop/old-app.desktop", home)), "the earlier desktop shortcut is gone")
	entry := read(fmt.tprintf("%s/.local/share/applications/new-app.desktop", home))
	testing.expectf(t, strings.contains(entry, new_exe), "the new menu entry runs the new program: %s", entry)
	target, _ := os.read_link(fmt.tprintf("%s/.local/bin/new-app", home), context.temp_allocator)
	testing.expect_value(t, target, new_exe)   // (the PATH box, off by default, came on from the earlier install)
	testing.expect(t, os.is_file(fmt.tprintf("%s/.config/autostart/new-app.desktop", home)), "the new autostart")
	testing.expect(t, os.is_file(fmt.tprintf("%s/Desktop/new-app.desktop", home)), "the new desktop shortcut")
	testing.expect_value(t, read(fmt.tprintf("%s/.config/%s/prefs.ini", home, NEW_FOLDER)), "theme = dusk\n")
	testing.expect_value(t, read(fmt.tprintf("%s/.local/state/%s/logs/old-app.log", home, NEW_FOLDER)), "a line\n")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.config/%s", home, EARLIER_FOLDER)), "the earlier settings folder moved")
	f := setup.facts(current)
	testing.expect_value(t, f.state, setup.State.Other_Copy)   // (installed whole; this test's binary is not it)
	testing.expect(t, f.start_lnk && f.record && f.on_path && f.autostart && f.desk_lnk, "the new install is whole")

	// the adopted copy's start: the news, once
	b := setup.adopt_earlier(current, exe = new_exe)
	defer setup.adoption_destroy(&b)
	testing.expect(t, b.news && b.relaunch == "", "the adopted copy says it")
	words, bad := setup.adoption_words(b)
	testing.expect(t, !bad, words)
	testing.expect(t, strings.contains(words, "New App replaces the install of Old App."), words)
	testing.expect(t, strings.contains(words, "The command old-app is now new-app."), words)
	c := setup.adopt_earlier(current, exe = new_exe)
	defer setup.adoption_destroy(&c)
	testing.expect_value(t, c.earlier, "")   // (said once)
}

// The folders' move is one rename per kind: interrupted after one kind, the next start moves the others and says it
// was done; a new folder that is there already stays, the earlier one stays too, and the result names it.
@(test)
an_interrupted_move_of_the_folders_resumes :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt_resume")
	defer home_end(&h)
	_, current := programs(&h)
	home := fmt.tprintf("%s/home", h.root)
	put(fmt.tprintf("%s/.local/share/%s/drafts.txt", home, EARLIER_FOLDER), "a draft\n")
	put(fmt.tprintf("%s/.cache/%s/index", home, EARLIER_FOLDER), "x")
	// (the start that began: its record says the folders begun, and it moved the configuration before it ended)
	put(fmt.tprintf("%s/.config/%s/prefs.ini", home, NEW_FOLDER), "theme = dusk\n")
	record := fmt.tprintf("%s/.local/state/%s.adoption", home, NEW_FOLDER)
	put(record, "old-app.folders=Begun\n")

	a := setup.adopt_earlier(current)
	defer setup.adoption_destroy(&a)
	testing.expect_value(t, a.folders, setup.Adopt_Outcome.Done)
	testing.expect_value(t, a.install, setup.Adopt_Outcome.None)   // (no earlier install here)
	testing.expect(t, a.news, "said")
	testing.expect_value(t, read(fmt.tprintf("%s/.local/share/%s/drafts.txt", home, NEW_FOLDER)), "a draft\n")
	testing.expect(t, os.is_file(fmt.tprintf("%s/.cache/%s/index", home, NEW_FOLDER)), "the cache moved")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/share/%s", home, EARLIER_FOLDER)), "nothing left behind")
	testing.expect(t, strings.contains(read(record), "old-app.folders=Done"), read(record))

	// interrupted after every kind moved: nothing is left to move, and the start that began did it
	put(record, "old-app.folders=Begun\n")
	b := setup.adopt_earlier(current)
	defer setup.adoption_destroy(&b)
	testing.expect_value(t, b.folders, setup.Adopt_Outcome.Done)

	// a new folder there already: the new stays, the earlier stays, the result says where; once
	_ = os.remove(record)
	put(fmt.tprintf("%s/.config/%s/prefs.ini", home, EARLIER_FOLDER), "theme = night\n")
	c := setup.adopt_earlier(current)
	defer setup.adoption_destroy(&c)
	testing.expect_value(t, c.folders, setup.Adopt_Outcome.Kept_Both)
	testing.expect_value(t, read(fmt.tprintf("%s/.config/%s/prefs.ini", home, NEW_FOLDER)), "theme = dusk\n")
	testing.expect_value(t, read(fmt.tprintf("%s/.config/%s/prefs.ini", home, EARLIER_FOLDER)), "theme = night\n")
	words, bad := setup.adoption_words(c)
	testing.expect(t, bad && strings.contains(words, fmt.tprintf("%s/.config/%s", home, EARLIER_FOLDER)), words)
	d := setup.adopt_earlier(current)
	defer setup.adoption_destroy(&d)
	testing.expect_value(t, d.earlier, "")   // (a final outcome: not tried again, said once)
}

// The new program installed already (from a download): the earlier install goes, the new one keeps its own choices.
@(test)
an_earlier_install_beside_the_new_one_goes :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt_beside")
	defer home_end(&h)
	earlier, current := programs(&h)
	home := fmt.tprintf("%s/home", h.root)
	ok, why := setup.install(earlier, false, []bool{true})
	testing.expectf(t, ok, "%s", why)
	ok, why = setup.install(current, false, []bool{false})
	testing.expectf(t, ok, "%s", why)
	a := setup.adopt_earlier(current)
	defer setup.adoption_destroy(&a)
	testing.expect_value(t, a.install, setup.Adopt_Outcome.Done)
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/opt/old-app", home)), "the earlier install is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/bin/new-app", home)), "the new install keeps its own choice: no PATH")
	testing.expect(t, os.is_file(fmt.tprintf("%s/.local/share/applications/new-app.desktop", home)), "its menu entry stays")
}

// A folder that cannot move ends the start, which says so, and the new folder is not made: the program would start
// empty, and the next start would find two folders. After ADOPT_TRIES such starts, the next one copies the folder and
// leaves the earlier one.
@(test)
a_folder_that_cannot_move_ends_the_start_then_is_copied :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	if os.get_euid() == 0 { return }   // (root renames in a folder closed to writing)
	h := home_start("adopt_copy")
	defer home_end(&h)
	_, current := programs(&h, earlier_folder = "OldVendor" + platform.USER_DIR_SEPARATOR + "OldApp")
	home := fmt.tprintf("%s/home", h.root)
	vendor := fmt.tprintf("%s/.config/OldVendor", home)
	put(fmt.tprintf("%s/OldApp/prefs.ini", vendor), "theme = dusk\n")
	// (a folder closed to writing: its folder cannot be renamed out of it, as a file held open on Windows)
	testing.expect_value(t, os.chmod(vendor, {.Read_User, .Execute_User}), nil)
	defer os.chmod(vendor, {.Read_User, .Write_User, .Execute_User})
	new_config := fmt.tprintf("%s/.config/%s", home, NEW_FOLDER)

	for i in 0 ..< setup.ADOPT_TRIES {
		a := setup.adopt_earlier(current, wait = 0)
		defer setup.adoption_destroy(&a)
		testing.expectf(t, a.folders == .Failed && a.stop && a.news, "start %d ends: %v", i, a)
		words, bad := setup.adoption_words(a)
		testing.expect(t, bad && strings.contains(words, "they stay where they were. Start New App again"), words)
		testing.expect(t, !os.exists(new_config), "no new folder")
	}
	// (a copy that an interrupted start left beside the new folder: begun again)
	put(fmt.tprintf("%s.adopting/half", new_config), "x")
	b := setup.adopt_earlier(current, wait = 0)
	defer setup.adoption_destroy(&b)
	testing.expect_value(t, b.folders, setup.Adopt_Outcome.Copied)
	testing.expect(t, !b.stop && b.news, "the start goes on")
	testing.expect_value(t, read(fmt.tprintf("%s/prefs.ini", new_config)), "theme = dusk\n")
	testing.expect(t, !os.exists(fmt.tprintf("%s/half", new_config)), "nothing of the interrupted copy")
	testing.expect(t, !os.exists(fmt.tprintf("%s.adopting", new_config)), "no copy left beside")
	testing.expect_value(t, read(fmt.tprintf("%s/OldApp/prefs.ini", vendor)), "theme = dusk\n")   // (the earlier one stays)
	words, _ := setup.adoption_words(b)
	testing.expect(t, strings.contains(words, "as a copy"), words)
	c := setup.adopt_earlier(current, wait = 0)
	defer setup.adoption_destroy(&c)
	testing.expect_value(t, c.earlier, "")   // (said once)
}

// One start adopts at a time: another one that finds the lock held ends, and moves nothing; once the lock is free, it
// adopts.
@(test)
a_second_start_does_not_adopt_beside_the_first :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt_lock")
	defer home_end(&h)
	_, current := programs(&h)
	home := fmt.tprintf("%s/home", h.root)
	put(fmt.tprintf("%s/.config/%s/prefs.ini", home, EARLIER_FOLDER), "theme = dusk\n")
	put(fmt.tprintf("%s/.local/state/%s.adoption.lock", home, NEW_FOLDER), "")
	held, got := fsx.file_lock(fmt.tprintf("%s/.local/state/%s.adoption.lock", home, NEW_FOLDER), 0)
	testing.expect_value(t, got, fsx.Lock_Result.Locked)

	a := setup.adopt_earlier(current, wait = 0)
	defer setup.adoption_destroy(&a)
	testing.expect(t, a.folders == .Busy && a.stop && a.news, "it ends")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/.config/%s", home, EARLIER_FOLDER)), "nothing moved")
	fsx.file_unlock(&held)

	b := setup.adopt_earlier(current, wait = 0)
	defer setup.adoption_destroy(&b)
	testing.expect_value(t, b.folders, setup.Adopt_Outcome.Done)
	testing.expect_value(t, read(fmt.tprintf("%s/.config/%s/prefs.ini", home, NEW_FOLDER)), "theme = dusk\n")
}

// A copy that is not the bridge's (a download, a portable copy, a build) moves the folders and installs nothing: the
// setup offers the install. Once the new install is there, the next start removes the earlier one.
@(test)
a_copy_that_is_not_the_bridge_installs_nothing :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt_offer")
	defer home_end(&h)
	earlier, current := programs(&h)
	home := fmt.tprintf("%s/home", h.root)
	ok, old_exe := setup.install(earlier, false, []bool{true})
	testing.expectf(t, ok, "%s", old_exe)
	old_exe = strings.clone(old_exe, context.temp_allocator)
	put(fmt.tprintf("%s/.config/%s/prefs.ini", home, EARLIER_FOLDER), "theme = dusk\n")
	download := fmt.tprintf("%s/Downloads/new-app", home)

	a := setup.adopt_earlier(current, exe = download, wait = 0)
	defer setup.adoption_destroy(&a)
	testing.expect_value(t, a.folders, setup.Adopt_Outcome.Done)
	testing.expect_value(t, a.install, setup.Adopt_Outcome.None)   // (Pending: nothing said)
	testing.expect(t, a.relaunch == "" && !a.stop, "it starts")
	testing.expect(t, os.is_file(old_exe), "the earlier install stays")
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/opt/new-app", home)), "nothing installed")
	testing.expect_value(t, setup.facts(current, exe = download).state, setup.State.Not_Installed)   // (the setup offers it)

	ok, _ = setup.install(current, false, []bool{false})
	testing.expect(t, ok, "the person installs it")
	b := setup.adopt_earlier(current, exe = download, wait = 0)
	defer setup.adoption_destroy(&b)
	testing.expect_value(t, b.install, setup.Adopt_Outcome.Done)
	testing.expect_value(t, b.folders, setup.Adopt_Outcome.None)   // (said already)
	testing.expect(t, !os.exists(fmt.tprintf("%s/.local/opt/old-app", home)), "the earlier install is gone")
}

// The earlier install in one of its own folders (its data folder): it goes first, then the folder moves without it.
@(private = "file")
install_in_data :: proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr) {
	home_prepare(o, choices, user)
	if o.identity.slug == "old-app" {
		o.install_dir = fmt.tprintf("%s/home/.local/share/%s/app", (^Home)(user).root, EARLIER_FOLDER)
	}
}

@(test)
an_earlier_install_in_its_data_folder_goes_first :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux { return }
	h := home_start("adopt_inside")
	defer home_end(&h)
	earlier, current := programs(&h, prepare = install_in_data)
	home := fmt.tprintf("%s/home", h.root)
	ok, old_exe := setup.install(earlier, false, []bool{true})
	testing.expectf(t, ok, "%s", old_exe)
	old_exe = strings.clone(old_exe, context.temp_allocator)
	put(fmt.tprintf("%s/.local/share/%s/drafts.txt", home, EARLIER_FOLDER), "a draft\n")

	a := setup.adopt_earlier(current, exe = old_exe, wait = 0)
	defer setup.adoption_destroy(&a)
	testing.expect_value(t, a.install, setup.Adopt_Outcome.Done)
	testing.expect_value(t, a.folders, setup.Adopt_Outcome.Done)
	testing.expect_value(t, a.relaunch, fmt.tprintf("%s/.local/opt/new-app/new-app", home))
	data := fmt.tprintf("%s/.local/share/%s", home, NEW_FOLDER)
	testing.expect_value(t, read(fmt.tprintf("%s/drafts.txt", data)), "a draft\n")
	testing.expect(t, !os.exists(fmt.tprintf("%s/app", data)), "the earlier program did not move with the data")
}
