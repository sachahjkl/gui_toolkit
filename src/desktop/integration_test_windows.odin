package tk_desktop

// The Windows backend on a scratch Start menu folder and a scratch registry key (HKCU\Software\TkDesktopTest_<id>): never
// on the real desktop. One test touches the real one, and only when TK_TEST_DESKTOP_REAL=1 is in the environment.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "../fsx"
import "core:time"
import win "core:sys/windows"
import "../process"

// For the helper to delete the files, the folder and itself; it only ends a failing run: each of the helper's looks at the process
// is a run of tasklist, which on a loaded machine takes seconds (the 20 s this was failed one run in ten, the helper still at work).
@(private = "file") CLEANUP_WAIT :: 180 * time.Second
@(private = "file") CLEANUP_POLL :: 200 * time.Millisecond
@(private = "file") WATCHER_WAKE_WAIT :: 5 * time.Second         // for a change to wake the watcher
@(private = "file") WATCHER_WAKE_POLL :: 20 * time.Millisecond
@(private = "file") WATCHER_SETTLE :: 100 * time.Millisecond     // for the notifications of one change to settle

@(private = "file")
Scratch :: struct {
	dir:  string,   // a folder in %TEMP%
	menu: string,   // its "Start menu"
	exe:  string,   // a file standing for the program
	exe2: string,   // the program after an update into another folder
	root: string,   // Software\TkDesktopTest_<id>
	desk: string,   // its "Desktop"
	env:  string,   // Software\TkDesktopTest_<id>\Environment: what stands for HKCU\Environment
	opts: Integration_Options,
}

@(private = "file")
scratch_make :: proc() -> Scratch {
	tmp, _ := os.temp_dir(context.allocator)
	id := test_unique_id()
	s: Scratch
	s.dir = fmt.aprintf("%s\\tk_desktop_test_%s", tmp, id)
	s.menu = fmt.aprintf("%s\\Start Menu\\Programs", s.dir)
	s.exe = fmt.aprintf("%s\\v1\\sample.exe", s.dir)
	s.exe2 = fmt.aprintf("%s\\v2\\sample.exe", s.dir)
	s.root = fmt.aprintf("Software\\TkDesktopTest_%s", id)
	s.desk = fmt.aprintf("%s\\Desktop", s.dir)
	s.env = fmt.aprintf("%s\\Environment", s.root)
	for p in ([]string{s.exe, s.exe2}) {
		dir := p[:strings.last_index_byte(p, '\\')]
		_ = os.make_directory_all(dir)
		_ = os.write_entire_file(p, "MZ not a program")
	}
	s.opts = Integration_Options{
		identity = test_identity(),
		exe = s.exe, register_browser = true, start_menu = true, file_types = split_list(".htm,.html,.svg,.webp", context.temp_allocator),
		menu_dir = s.menu, desktop_dir = s.desk, environment_root = s.env, registry_root = s.root, notify_system = false,
	}
	delete(tmp)
	delete(id)
	return s
}

@(private = "file")
scratch_destroy :: proc(s: ^Scratch) {
	// Each test has a key directly under Software. A shared parent deleted here when it looked empty made RegCreateKeyExW of
	// another test (or of the browser's tests, in another process) fail with ERROR_KEY_DELETED or ERROR_FILE_NOT_FOUND, about
	// 2 % of the time with four threads at it: its PATH value was then never written (the "PATH found empty" of the CI).
	RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(s.root))
	_ = fsx.remove_tree(s.dir)   // (not os.remove_all: it hands the folder to the Windows shell, which meets the shell links the other tests make)
	delete(s.dir); delete(s.menu); delete(s.exe); delete(s.exe2); delete(s.root); delete(s.desk); delete(s.env)
}

@(private = "file")
state_of :: proc(o: ^Integration_Options) -> (State, Status) {
	st := status(o, context.temp_allocator)
	return st.state, st
}

@(test)
windows_round_trip :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	lnk := fmt.tprintf("%s\\Sample.lnk", s.menu)
	client := fmt.tprintf("%s\\Clients\\StartMenuInternet\\Sample", s.root)
	progid := fmt.tprintf("%s\\Classes\\SampleHTML", s.root)

	state, st := state_of(o)
	testing.expect_value(t, state, State.Absent)
	testing.expect_value(t, st.error, Error.None)

	r := install(o)
	testing.expect_value(t, r.error, Error.None)
	if r.error != .None { testing.expect(t, false, r.detail); return }
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, os.is_file(lnk), "the shortcut exists")

	// the shortcut: the executable, its AppUserModelID
	com := com_enter()
	target, aumid, read := read_shortcut(lnk)
	com_leave(com)
	testing.expect(t, read, "the shortcut reads back")
	testing.expect(t, same_path(target, s.exe), fmt.tprintf("shortcut target %q", target))
	testing.expect_value(t, aumid, "GuiToolkit.Sample.Test")

	// the registration, value by value
	get :: proc(t: ^testing.T, path, name, want: string) {
		v, ok := reg_get(path, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q (found %v), want %q", path, name, v, ok, want)
	}
	get(t, client, "", "Sample")
	get(t, fmt.tprintf("%s\\shell\\open\\command", client), "", fmt.tprintf("\"%s\"", s.exe))
	get(t, fmt.tprintf("%s\\DefaultIcon", client), "", fmt.tprintf("%s,0", s.exe))
	caps := fmt.tprintf("%s\\Capabilities", client)
	get(t, caps, "ApplicationName", "Sample")
	get(t, caps, "ApplicationIcon", fmt.tprintf("%s,0", s.exe))
	get(t, fmt.tprintf("%s\\URLAssociations", caps), "http", "SampleHTML")
	get(t, fmt.tprintf("%s\\URLAssociations", caps), "https", "SampleHTML")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".html", "SampleHTML")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".webp", "SampleHTML")
	get(t, fmt.tprintf("%s\\RegisteredApplications", s.root), "Sample", caps)
	get(t, fmt.tprintf("%s\\shell\\open\\command", progid), "", fmt.tprintf("\"%s\" \"%%1\"", s.exe))
	get(t, fmt.tprintf("%s\\Application", progid), "AppUserModelId", "GuiToolkit.Sample.Test")

	// again: nothing changes
	testing.expect_value(t, install(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)

	// removal: all of it, and the status says so
	testing.expect_value(t, remove(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Absent)
	testing.expect(t, !os.exists(lnk), "the shortcut is gone")
	testing.expect(t, !reg_key_exists(client), "the browser entry is gone")
	testing.expect(t, !reg_key_exists(progid), "the ProgID is gone")
	_, still := reg_get(fmt.tprintf("%s\\RegisteredApplications", s.root), "Sample")
	testing.expect(t, !still, "the list entry is gone")
	// removing again is not an error
	testing.expect_value(t, remove(o).error, Error.None)
}

@(test)
windows_repair_states :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	testing.expect_value(t, install(o).error, Error.None)

	// the program moved: same integration, another executable
	moved := o^
	moved.exe = s.exe2
	state, st := state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, same_path(st.stale_exe, s.exe), fmt.tprintf("points to the old executable, got %q", st.stale_exe))
	testing.expect(t, st.parts[.Launcher].stale && st.parts[.Registration].stale, "both parts are stale")
	testing.expect(t, !st.incomplete, "nothing is missing")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// a piece of the registration is gone
	progid := fmt.tprintf("%s\\Classes\\SampleHTML", s.root)
	testing.expect(t, reg_delete_tree(progid), "delete the ProgID")
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.incomplete, "incomplete")
	testing.expect(t, st.parts[.Registration].partial, "the registration is partial")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// only the shortcut left (the keys were removed by hand): to repair
	client := fmt.tprintf("%s\\Clients\\StartMenuInternet\\Sample", s.root)
	reg_delete_tree(client)
	reg_delete_tree(progid)
	reg_delete_value(fmt.tprintf("%s\\RegisteredApplications", s.root), "Sample")
	for name in o.identity.url_schemes { reg_delete_tree(fmt.tprintf("%s\\Classes\\%s", s.root, name)) }
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, !st.parts[.Registration].present, "no registration")

	// ... which is fine when the options do not ask for one
	no_reg := moved
	no_reg.register_browser = false
	state, _ = state_of(&no_reg)
	testing.expect_value(t, state, State.Installed)
	testing.expect_value(t, remove(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Absent)
}

@(test)
windows_without_browser_registration :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	testing.expect_value(t, install(o).error, Error.None)
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Launcher].present && !st.parts[.Registration].present, "only the shortcut")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Sample", s.root)), "no browser entry")

	// registering later completes it; turning it off again removes the keys
	o.register_browser = true
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Repair)
	testing.expect_value(t, install(o).error, Error.None)
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Installed)
	o.register_browser = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Sample", s.root)), "the keys went with the option")
}

@(test)
windows_removal_leaves_what_is_not_the_programs :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts

	// a shortcut of the same name made by someone else, keys of other programs, a user's default for .html
	_ = os.make_directory_all(s.menu)
	lnk := fmt.tprintf("%s\\Sample.lnk", s.menu)
	_ = os.write_entire_file(lnk, "not a shortcut at all")
	other := fmt.tprintf("%s\\Classes\\OtherHTML", s.root)
	testing.expect(t, reg_set(fmt.tprintf("%s\\shell\\open\\command", other), "", "\"C:\\other\\other.exe\" \"%1\""), "other ProgID")
	testing.expect(t, reg_set(fmt.tprintf("%s\\Classes\\.html", s.root), "", "OtherHTML"), "extension key")
	testing.expect(t, reg_set(fmt.tprintf("%s\\RegisteredApplications", s.root), "Other", "Software\\Other\\Capabilities"), "other registered app")
	testing.expect(t, reg_set(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Other\\shell\\open\\command", s.root), "", "\"C:\\other\\other.exe\""), "other browser")

	state, _ := state_of(o)
	testing.expect_value(t, state, State.Absent)   // the unreadable file is not the program's
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, os.is_file(lnk), "a file that is not the program's shortcut stays")

	// installed, then removed: the neighbours are untouched
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	v, ok := reg_get(fmt.tprintf("%s\\Classes\\.html", s.root), "")
	testing.expect(t, ok && v == "OtherHTML", "the extension key is untouched")
	testing.expect(t, reg_key_exists(other), "another program's ProgID stays")
	_, ok = reg_get(fmt.tprintf("%s\\RegisteredApplications", s.root), "Other")
	testing.expect(t, ok, "another program's list entry stays")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\Clients\\StartMenuInternet\\Other", s.root)), "another browser's entry stays")
}

// The program's own URL schemes: a key each with the registration, gone with it, and the keys of
// the default browser (the user's choice for http and https, another program's scheme) never touched.
@(test)
windows_link_schemes :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	classes := fmt.tprintf("%s\\Classes", s.root)
	choice := fmt.tprintf("%s\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\https\\UserChoice", s.root)
	testing.expect(t, reg_set(choice, "ProgId", "OtherHTML"), "the user's default browser")
	testing.expect(t, reg_set(fmt.tprintf("%s\\http\\shell\\open\\command", classes), "", "\"C:\\other\\other.exe\" \"%1\""), "the http class")
	testing.expect(t, reg_set(fmt.tprintf("%s\\other-https\\shell\\open\\command", classes), "", "\"C:\\other\\other.exe\" \"%1\""), "another program's scheme")

	testing.expect_value(t, install(o).error, Error.None)
	for name in ([]string{"sample-http", "sample-https"}) {
		key := fmt.tprintf("%s\\%s", classes, name)
		v, ok := reg_get(key, "")
		testing.expectf(t, ok && v == "URL:Sample", "%s: %q", name, v)
		v, ok = reg_get(key, "URL Protocol")
		testing.expectf(t, ok && v == "", "%s is a URL protocol (%v)", name, ok)
		v, ok = reg_get(fmt.tprintf("%s\\shell\\open\\command", key), "")
		testing.expectf(t, ok && v == fmt.tprintf("\"%s\" --open-url \"%%1\"", s.exe), "%s runs %q", name, v)
	}
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)

	// one gone: to repair, and Repair writes it again
	testing.expect(t, reg_delete_tree(fmt.tprintf("%s\\sample-http", classes)), "delete a scheme")
	state, st = state_of(o)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.parts[.Registration].partial, "the registration is partial")
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\sample-http", classes)), "written again")

	// the program moved: they point to the old executable until Update
	moved := o^
	moved.exe = s.exe2
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.parts[.Registration].stale, "stale")
	testing.expect_value(t, install(&moved).error, Error.None)
	v, _ := reg_get(fmt.tprintf("%s\\sample-https\\shell\\open\\command", classes), "")
	testing.expect_value(t, v, fmt.tprintf("\"%s\" --open-url \"%%1\"", s.exe2))

	testing.expect_value(t, remove(&moved).error, Error.None)
	for name in ([]string{"sample-http", "sample-https"}) {
		testing.expectf(t, !reg_key_exists(fmt.tprintf("%s\\%s", classes, name)), "%s is gone", name)
	}
	v, _ = reg_get(choice, "ProgId")
	testing.expect_value(t, v, "OtherHTML")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\http\\shell\\open\\command", classes)), "the http class stays")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\other-https", classes)), "another program's scheme stays")
}

// The windows of the process carry the AppUserModelID the shortcut has: what makes pinning and grouping work.
@(test)
windows_process_identity_is_the_shortcuts :: proc(t: ^testing.T) {
	id := test_identity()
	id.aumid = "GuiToolkit.Sample.ProcessTest"
	set_process_identity(id)
	got: cstring16
	testing.expect(t, GetCurrentProcessExplicitAppUserModelID(&got) >= 0 && got != nil, "the process has an explicit AppUserModelID")
	if got == nil { return }
	defer win.CoTaskMemFree(rawptr(got))
	s, _ := win.wstring_to_utf8(got, -1, context.temp_allocator)
	testing.expect_value(t, s, id.aumid)
}

@(test)
windows_command_program :: proc(t: ^testing.T) {
	testing.expect_value(t, command_program(`"C:\a b\sample.exe" "%1"`), `C:\a b\sample.exe`)
	testing.expect_value(t, command_program(`C:\x\sample.exe %1`), `C:\x\sample.exe`)
	testing.expect_value(t, command_program(``), ``)
}

// The real desktop: only with TK_TEST_DESKTOP_REAL=1, with an identity of its own that no installed program shares.
@(test)
windows_real_desktop :: proc(t: ^testing.T) {
	if v, ok := os.lookup_env("TK_TEST_DESKTOP_REAL", context.temp_allocator); !ok || v != "1" { return }
	exe := process.executable_path()
	o := Integration_Options{
		identity = real_identity(),
		exe = exe, register_browser = true, start_menu = true, file_types = {".html"}, notify_system = true,
	}
	defer remove(&o)
	testing.expect_value(t, install(&o).error, Error.None)
	state, _ := state_of(&o)
	testing.expect_value(t, state, State.Installed)
	testing.expect_value(t, remove(&o).error, Error.None)
	state, _ = state_of(&o)
	testing.expect_value(t, state, State.Absent)
}

////////////////////////////////
// The parts an installed copy adds: the desktop shortcut, the PATH, the Apps-list record, the file a running program holds

@(test)
windows_desktop_shortcut_is_an_option :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	desk_lnk := fmt.tprintf("%s\\Sample.lnk", s.desk)
	start_lnk := fmt.tprintf("%s\\Sample.lnk", s.menu)

	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, os.is_file(start_lnk) && !os.exists(desk_lnk), "only the Start menu entry by default")

	o.desktop_shortcut = true
	state, st := state_of(o)
	testing.expect_value(t, state, State.Repair)   // wanted and missing
	testing.expect(t, !st.parts[.Desktop_Shortcut].present, "not there yet")
	testing.expect_value(t, install(o).error, Error.None)
	state, st = state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Desktop_Shortcut].present && !st.parts[.Desktop_Shortcut].stale, "present and running this exe")
	com := com_enter()
	target, aumid, read := read_shortcut(desk_lnk)
	com_leave(com)
	testing.expect(t, read && same_path(target, s.exe) && aumid == "GuiToolkit.Sample.Test", "the desktop shortcut runs the exe with the AppUserModelID")

	// the program moved: the desktop shortcut is stale too
	moved := o^
	moved.exe = s.exe2
	state, st = state_of(&moved)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.parts[.Desktop_Shortcut].stale, "the desktop shortcut points to the old executable")
	testing.expect_value(t, install(&moved).error, Error.None)
	state, _ = state_of(&moved)
	testing.expect_value(t, state, State.Installed)

	// turning it off removes it (and only it)
	moved.desktop_shortcut = false
	testing.expect_value(t, install(&moved).error, Error.None)
	testing.expect(t, !os.exists(desk_lnk) && os.is_file(start_lnk), "the desktop shortcut went with the option, the menu entry stays")

	// the Start menu is an option too
	moved.start_menu = false
	testing.expect_value(t, install(&moved).error, Error.None)
	testing.expect(t, !os.exists(start_lnk), "the Start menu entry went with its option")
	testing.expect_value(t, remove(&moved).error, Error.None)
}

@(test)
windows_other_programs_shortcut_on_the_desktop_stays :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	_ = os.make_directory_all(s.desk)
	desk_lnk := fmt.tprintf("%s\\Sample.lnk", s.desk)
	_ = os.write_entire_file(desk_lnk, "somebody else's file")
	o.desktop_shortcut = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, os.is_file(desk_lnk), "a file that is not the program's shortcut stays")
}

@(private = "file")
path_value :: proc(s: ^Scratch) -> (string, bool) {
	v, _, ok := reg_get_any(s.env, "Path")
	return v, ok
}

@(test)
windows_path_is_added_once_and_taken_out_with_its_mark :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\v1", s.dir)
	testing.expect(t, reg_set_kind(s.env, "Path", `C:\Tools;%USERPROFILE%\bin`, true), "the user's PATH")

	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	v, ok := path_value(&s)
	testing.expect(t, ok && v == fmt.tprintf("C:\\Tools;%%USERPROFILE%%\\bin;%s", dir), fmt.tprintf("appended, %%VARS%% untouched: %q", v))
	_, expand, _ := reg_get_any(s.env, "Path")
	testing.expect(t, expand, "REG_EXPAND_SZ")
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Path].present, "the PATH part is present")

	// again, and with a trailing separator or another spelling: no second entry
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("%s\\;C:\\Tools", strings.to_upper(dir, context.temp_allocator)), true), "another spelling")
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(strings.to_lower(v, context.temp_allocator), strings.to_lower(dir, context.temp_allocator)), 1)

	// the option off: the folder goes (it was ours), the rest stays
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("C:\\Tools;%s", dir), true), "reset")
	testing.expect(t, reg_set(fmt.tprintf("%s\\GuiToolkitTest\\Sample", s.root), "PathDir", dir), "the mark")
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, v, `C:\Tools`)
	_, marked := reg_get(fmt.tprintf("%s\\GuiToolkitTest\\Sample", s.root), "PathDir")
	testing.expect(t, !marked, "the mark went too")
}

@(test)
windows_path_entry_the_user_added_is_not_taken_out :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\v1", s.dir)
	testing.expect(t, reg_set_kind(s.env, "Path", fmt.tprintf("C:\\Tools;%s", dir), false), "the user put it there, as REG_SZ")
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	v, _ := path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)   // already there: nothing added, and no mark
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, strings.count(v, dir), 1)   // not ours: still there
	// but a folder that is about to be deleted comes out whatever put it there
	testing.expect_value(t, forget_path(o, dir).error, Error.None)
	v, _ = path_value(&s)
	testing.expect_value(t, v, `C:\Tools`)
	testing.expect_value(t, forget_path(o, dir).error, Error.None)   // again: fine
}

@(test)
windows_path_value_is_deleted_when_it_empties :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)   // no Path value at all before: made by us
	_, ok := path_value(&s)
	testing.expect(t, ok, "made")
	testing.expect_value(t, remove(o).error, Error.None)
	_, ok = path_value(&s)
	testing.expect(t, !ok, "an empty PATH is not left behind")
}

@(private = "file") LAUNCHER_V1 :: "MZ launcher " + "(Sample console launcher)" + " v1"
@(private = "file") LAUNCHER_V2 :: "MZ launcher " + "(Sample console launcher)" + " version 2"

@(test)
windows_console_launcher_follows_the_path_option :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.launcher = transmute([]byte)string(LAUNCHER_V1)
	com := fmt.tprintf("%s\\v1\\sample.com", s.dir)

	// the option off: no launcher
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !os.exists(com), "no PATH entry, no launcher")

	// on: written beside the executable, nowhere else; the status sees it
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, read_file(com), LAUNCHER_V1)
	testing.expect(t, !os.exists(fmt.tprintf("%s\\v2\\sample.com", s.dir)), "only beside the program")
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Path].present && !st.parts[.Path].partial, "the PATH part is complete")

	// gone from the disk: the PATH part is incomplete, and installing again puts it back
	testing.expect(t, os.remove(com) == nil, "removed by hand")
	state, st = state_of(o)
	testing.expect_value(t, state, State.Repair)
	testing.expect(t, st.parts[.Path].partial, "the launcher is missing")
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, read_file(com), LAUNCHER_V1)

	// another version of the program: replaced, nothing left behind
	o.launcher = transmute([]byte)string(LAUNCHER_V2)
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, read_file(com), LAUNCHER_V2)
	testing.expect(t, !os.exists(fmt.tprintf("%s.old", com)) && !os.exists(fmt.tprintf("%s.new", com)), "no .old / .new left")

	// the option off again: it goes with the PATH entry
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !os.exists(com), "unticked: removed")

	// removal takes it too
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, os.is_file(com), "back")
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, !os.exists(com), "removed with the integration")
}

@(test)
windows_console_launcher_never_replaces_or_deletes_another_program :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.launcher = transmute([]byte)string(LAUNCHER_V1)
	o.add_to_path = true
	com := fmt.tprintf("%s\\v1\\sample.com", s.dir)
	testing.expect(t, os.write_entire_file(com, "somebody else's sample.com") == nil, "a file of that name")
	r := install(o)
	testing.expect_value(t, r.error, Error.Io)
	testing.expect(t, strings.contains(r.detail, "not Sample's console launcher"), r.detail)
	testing.expect_value(t, read_file(com), "somebody else's sample.com")
	o.add_to_path = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect_value(t, read_file(com), "somebody else's sample.com")
	// and an executable without a launcher in its options writes none
	_ = os.remove(com)
	o.launcher = nil
	o.add_to_path = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !os.exists(com), "the program ships without one")
}

@(test)
windows_console_launcher_goes_with_the_install_folder :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	com := fmt.tprintf("%s\\sample.com", tr.dst)
	testing.expect(t, os.write_entire_file(com, LAUNCHER_V1) == nil, "the launcher install wrote")
	r := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 0)
	testing.expect(t, !os.exists(com), "gone")
	testing.expect(t, r.folder && !os.exists(tr.dst), "so is the folder")

	// a sample.com of someone else keeps the folder
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	testing.expect(t, os.write_entire_file(com, "not ours") == nil, "another program")
	r = files_remove(&tr.opts, tr.dst)
	testing.expect(t, os.is_file(com) && !r.folder, "it stays, and the folder with it")
}

@(private = "file")
read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? string(data) : "<unreadable>"
}

@(test)
windows_record_locates_the_installed_copy :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	dir := fmt.tprintf("%s\\installed", s.dir)
	testing.expect_value(t, windows_locate(o, context.temp_allocator), "")
	testing.expect_value(t, install_recorded(o), "")   // no record: no folder, not the default
	testing.expect_value(t, record_install(o, dir, "0.3.0").error, Error.None)
	key := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Sample", s.root)
	get :: proc(t: ^testing.T, key, name, want: string) {
		v, ok := reg_get(key, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q, want %q", key, name, v, want)
	}
	get(t, key, "DisplayName", "Sample")
	get(t, key, "DisplayVersion", "0.3.0")
	get(t, key, "InstallLocation", dir)
	get(t, key, "UninstallString", fmt.tprintf("\"%s\\%s\" --uninstall", dir, exe_name_of(o.identity)))
	testing.expect_value(t, windows_locate(o, context.temp_allocator), dir)
	testing.expect_value(t, install_target(o), dir)   // no install_dir option: the record says where
	testing.expect_value(t, install_recorded(o), dir)
	// a record of the default folder is a record (setup.facts took it for none: an install "to repair")
	default := windows_default_install_dir(o, context.temp_allocator)
	testing.expect_value(t, record_install(o, default, "0.3.0").error, Error.None)
	testing.expect_value(t, install_recorded(o), default)
	testing.expect_value(t, record_install(o, dir, "0.3.0").error, Error.None)
	o.install_dir = `X:\elsewhere`
	testing.expect_value(t, install_target(o), `X:\elsewhere`)   // the option wins
	o.install_dir = ""

	// a key of the same name that is not ours is neither read nor deleted
	other := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Sample", s.root)
	reg_delete_tree(other)
	testing.expect(t, reg_set(other, "InstallLocation", `D:\not ours`), "someone else's key")
	testing.expect_value(t, windows_locate(o, context.temp_allocator), "")
	testing.expect_value(t, unrecord_install(o).error, Error.None)
	testing.expect(t, reg_key_exists(other), "not deleted")
	reg_delete_tree(other)

	testing.expect_value(t, record_install(o, dir, "0.3.0").error, Error.None)
	testing.expect_value(t, unrecord_install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(key), "the record is removed")
}

@(test)
windows_remove_files_reports_what_a_program_holds :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	held := fmt.tprintf("%s\\sample.exe", tr.dst)
	// open without FILE_SHARE_DELETE: it can be neither deleted nor renamed, which is what a loaded image is for delete
	h := win.CreateFileW(win.utf8_to_wstring(held, context.temp_allocator), win.GENERIC_READ, win.FILE_SHARE_READ, nil, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, nil)
	testing.expect(t, h != win.INVALID_HANDLE_VALUE, "opened")
	r := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 1)
	testing.expect(t, len(r.leftovers) == 1 && same_path(r.leftovers[0], held), "the held file is reported")
	testing.expect(t, !os.exists(fmt.tprintf("%s\\vcruntime140.dll", tr.dst)), "the others are gone")
	testing.expect(t, os.is_file(fmt.tprintf("%s\\%s", tr.dst, tr.opts.identity.manifest_name)), "the manifest stays while something is left")
	testing.expect(t, !r.folder, "and so does the folder")
	win.CloseHandle(h)
	// after the program ends: the next removal finishes
	r = files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 0)
	testing.expect(t, r.folder && !os.exists(tr.dst), "everything is gone")
}

@(test)
windows_cleanup_script_waits_for_the_process_and_escapes_percent :: proc(t: ^testing.T) {
	text := cleanup_script({`C:\a b\sample.exe`, `C:\100%\x.dll`}, `C:\a b`, 4242)
	testing.expect(t, strings.contains(text, `tasklist /nh /fi "PID eq 4242"`), "waits for the process")
	testing.expect(t, strings.contains(text, `del /f /q "C:\a b\sample.exe"`), "deletes a file with a space in its path")
	testing.expect(t, strings.contains(text, `"C:\100%%\x.dll"`), "a percent sign is doubled")
	testing.expect(t, strings.contains(text, `rmdir "C:\a b"`), "then the folder")
	testing.expect(t, strings.contains(text, `del "%~f0"`), "and itself")
	testing.expect(t, !strings.contains(cleanup_script({`C:\x`}, "", 0), "tasklist"), "no process to wait for")
}

// The helper for real: a process stands for the running program; once it has ended, the files it held are deleted, then the
// folder, and the batch file deletes itself.
@(test)
windows_cleanup_later_deletes_after_the_process_ends :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	dir := fmt.tprintf("%s\\held", tr.root)
	_ = os.make_directory_all(dir)
	a, b := fmt.tprintf("%s\\a.exe.old", dir), fmt.tprintf("%s\\sample_install.txt", dir)
	_ = os.write_entire_file(a, "x")
	_ = os.write_entire_file(b, "x")
	// (a shell reading a pipe nobody writes to lives until the test ends it: the end of the program is the test's to decide, not a time)
	input, feed, perr := os.pipe()
	testing.expect(t, perr == nil, "a pipe")
	if perr != nil { return }
	defer os.close(feed)
	p, err := os.process_start(os.Process_Desc{command = {"cmd.exe", "/d", "/q"}, stdin = input})
	os.close(input)
	testing.expect(t, err == nil, "a process to wait for")
	if err != nil { return }
	ok := cleanup_later(&tr.opts, {a, b}, dir, u32(p.pid))
	testing.expect(t, ok, "the helper starts")
	testing.expect(t, os.exists(a) && os.exists(b), "nothing is deleted while the process lives")
	_ = os.process_kill(p)
	t0 := time.now()
	for time.since(t0) < CLEANUP_WAIT && os.exists(dir) { time.sleep(CLEANUP_POLL) }
	_, _ = os.process_wait(p)
	testing.expect(t, !os.exists(a) && !os.exists(b), "the files are deleted")
	testing.expect(t, !os.exists(dir), "and the folder")
	script := fmt.tprintf("%s\\sample_cleanup_%d.cmd", strings.trim_right(os.temp_dir(context.temp_allocator) or_else "", "\\/"), win.GetCurrentProcessId())
	for time.since(t0) < CLEANUP_WAIT && os.exists(script) { time.sleep(CLEANUP_POLL) }
	testing.expect(t, !os.exists(script), "the batch file deleted itself")
}
// The watcher: a change in the registry subtree, the PATH key, the Start menu folder and the Desktop folder each wake the
// program; stopping it joins its thread.
@(private = "file")
watch_counter: int

@(test)
windows_watcher_wakes_on_every_place_it_watches :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	_ = os.make_directory_all(s.menu)
	_ = os.make_directory_all(s.desk)
	testing.expect(t, reg_set(s.env, "Path", "C:\\scratch"), "the scratch environment key exists")
	sync.atomic_store(&watch_counter, 0)
	w := watch_start(o, proc(user: rawptr) { sync.atomic_add(&watch_counter, 1) }, nil)
	testing.expect(t, w != nil, "the watcher starts")
	if w == nil { return }
	defer watch_stop(w)

	woken :: proc(before: int) -> bool {
		t0 := time.now()
		for time.since(t0) < WATCHER_WAKE_WAIT {
			if sync.atomic_load(&watch_counter) > before { return true }
			time.sleep(WATCHER_WAKE_POLL)
		}
		return false
	}
	step :: proc(t: ^testing.T, what: string, change: proc() -> bool) {
		before := sync.atomic_load(&watch_counter)
		testing.expect(t, change(), what)
		testing.expectf(t, woken(before), "%s wakes the watcher", what)
		time.sleep(WATCHER_SETTLE)
	}
	@(static) sc: ^Scratch
	sc = &s
	defer sc = nil
	step(t, "a file in the Start menu folder", proc() -> bool { return os.write_entire_file(fmt.tprintf("%s\\a.lnk", sc.menu), "x") == nil })
	step(t, "a file in the Desktop folder", proc() -> bool { return os.write_entire_file(fmt.tprintf("%s\\a.lnk", sc.desk), "x") == nil })
	step(t, "a value in the environment key", proc() -> bool { return reg_set(sc.env, "Path", "C:\\scratch;C:\\more") })
	step(t, "a key in the registry subtree", proc() -> bool { return reg_set(fmt.tprintf("%s\\Clients\\X", sc.root), "", "x") })

	// a place that goes does not end the watcher: it is a change, and it is watched again when it comes back
	step(t, "the environment key deleted", proc() -> bool { return reg_delete_tree(sc.env) })
	step(t, "the Desktop folder deleted", proc() -> bool { return fsx.remove_tree(sc.desk) })
	step(t, "the Desktop folder back", proc() -> bool { return os.make_directory_all(sc.desk) == nil })
	step(t, "a file in the Desktop folder again", proc() -> bool { return os.write_entire_file(fmt.tprintf("%s\\b.lnk", sc.desk), "x") == nil })
	step(t, "the environment key back", proc() -> bool { return reg_set(sc.env, "Path", "C:\\scratch") })
	step(t, "a value in it again", proc() -> bool { return reg_set(sc.env, "Path", "C:\\scratch;C:\\x") })
}

@(private = "file")
real_identity :: proc() -> Identity {
	id := test_identity()
	id.name, id.key, id.slug, id.aumid = "Tk Desktop Test", "TkDesktopTest", "tk-desktop-test", "GuiToolkit.DesktopTest"
	id.description = "Removed by its own test."
	return id
}

@(test)
windows_scratch_roots_only :: proc(t: ^testing.T) {
	id := test_identity()
	testing.expect(t, !delete_scratch_root(id, `Software\Classes`), "a real key is refused")
	testing.expect(t, !delete_scratch_root(id, `Software\TkDesktopTest_`), "the prefix alone is refused")
	testing.expect(t, !delete_scratch_root(id, `Software\TkDesktopTest_1\..\..\Classes`), "no way up")
	root := fmt.tprintf(`Software\TkDesktopTest_%d_scratch`, os.get_pid())
	testing.expect(t, reg_set(root, "x", "y"), "a scratch key")
	testing.expect(t, delete_scratch_root(id, root), "a scratch key is deleted")
	testing.expect(t, !reg_key_exists(root), "gone")
}

// The Autostart part: the Run value named by the key, the executable and its arguments; repaired when they change; taken
// out with the option and by remove. (A scratch registry root: the user's own Run key is never touched.)
@(test)
windows_autostart :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	run := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Run", s.root)
	o.autostart, o.autostart_arguments = true, "--hidden"
	testing.expect_value(t, install(o).error, Error.None)
	cmd, ok := reg_get(run, o.identity.key)
	testing.expect(t, ok, "the Run value")
	testing.expect_value(t, cmd, fmt.tprintf("\"%s\" --hidden", s.exe))
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Autostart].present, "the part is there")

	o.autostart_arguments = "--tray"
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Repair)
	testing.expect_value(t, install(o).error, Error.None)
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Installed)

	o.autostart = false
	testing.expect_value(t, install(o).error, Error.None)
	_, ok = reg_get(run, o.identity.key)
	testing.expect(t, !ok, "taken out with the option")
	o.autostart = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	_, ok = reg_get(run, o.identity.key)
	testing.expect(t, !ok, "removed")
}

@(private = "file") DOCUMENT_TYPES := [?]Document_Type{{".pdf", "application/pdf", "PDF Document"}, {".fdf", "application/vnd.fdf", ""}}

// The Documents part: a ProgID per type and the three lists that name it; to repair when a piece goes; a type taken out
// of the list goes at the next install; the option off and remove take it all away, and leave another program's
// ProgID, its OpenWithProgids value and the person's UserChoice. (A scratch registry root: the user's own Classes are
// never touched.)
@(test)
windows_documents :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	o.document_types = DOCUMENT_TYPES[:]
	o.open_documents = true
	classes := fmt.tprintf("%s\\Classes", s.root)
	progid := fmt.tprintf("%s\\GuiToolkitTest.Sample.pdf", classes)
	open_with := fmt.tprintf("%s\\.pdf\\OpenWithProgids", classes)
	app := fmt.tprintf("%s\\Applications\\sample.exe", classes)
	caps := fmt.tprintf("%s\\GuiToolkitTest\\Sample\\Capabilities", s.root)
	registered := fmt.tprintf("%s\\RegisteredApplications", s.root)
	choice := fmt.tprintf("%s\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\.pdf\\UserChoice", s.root)
	testing.expect(t, reg_set(choice, "ProgId", "OtherPDF"), "the person's default")
	testing.expect(t, reg_set(fmt.tprintf("%s\\OtherPDF\\shell\\open\\command", classes), "", `"C:\other\other.exe" "%1"`), "another program's ProgID")
	testing.expect(t, reg_set(open_with, "OtherPDF", ""), "another program in Open with")

	testing.expect_value(t, install(o).error, Error.None)
	get :: proc(t: ^testing.T, path, name, want: string, loc := #caller_location) {
		v, ok := reg_get(path, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q (found %v), want %q", path, name, v, ok, want, loc = loc)
	}
	get(t, progid, "", "PDF Document")
	get(t, progid, "AppUserModelID", "GuiToolkit.Sample.Test")
	get(t, fmt.tprintf("%s\\DefaultIcon", progid), "", fmt.tprintf("%s,0", s.exe))
	get(t, fmt.tprintf("%s\\shell\\open\\command", progid), "", fmt.tprintf("\"%s\" \"%%1\"", s.exe))
	get(t, fmt.tprintf("%s\\GuiToolkitTest.Sample.fdf", classes), "", "Sample")   // (no description: the program's name)
	get(t, open_with, "GuiToolkitTest.Sample.pdf", "")
	get(t, fmt.tprintf("%s\\SupportedTypes", app), ".pdf", "")
	get(t, fmt.tprintf("%s\\shell\\open\\command", app), "", fmt.tprintf("\"%s\" \"%%1\"", s.exe))
	get(t, caps, "ApplicationName", "Sample")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".pdf", "GuiToolkitTest.Sample.pdf")
	get(t, fmt.tprintf("%s\\FileAssociations", caps), ".fdf", "GuiToolkitTest.Sample.fdf")
	get(t, registered, "Sample.Documents", caps)
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Documents].present && !st.parts[.Documents].partial && !st.parts[.Documents].stale, "the part is there")
	testing.expect(t, .Default_Documents not_in supported_parts(), "Windows has no default part")

	// a piece gone: to repair, then repaired
	testing.expect(t, reg_delete_value(open_with, "GuiToolkitTest.Sample.pdf"), "out of Open with")
	_, st = state_of(o)
	testing.expect(t, st.parts[.Documents].partial, "a list does not name the ProgID")
	testing.expect_value(t, install(o).error, Error.None)
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Installed)

	// the program moved: stale
	moved := o^
	moved.exe = s.exe2
	_, st = state_of(&moved)
	testing.expect(t, st.parts[.Documents].stale, "it runs the old program")

	// a type taken out of the list goes at the next install
	o.document_types = DOCUMENT_TYPES[:1]
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\GuiToolkitTest.Sample.fdf", classes)), "the old type's ProgID")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\.fdf", classes)), "its extension's keys, left empty")
	_, still := reg_get(fmt.tprintf("%s\\FileAssociations", caps), ".fdf")
	testing.expect(t, !still, "its association")

	// the option off: all of it goes, the neighbours stay
	o.open_documents = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(progid) && !reg_key_exists(app) && !reg_key_exists(caps), "the keys went with the option")
	_, still = reg_get(registered, "Sample.Documents")
	testing.expect(t, !still, "the list entry went")
	_, still = reg_get(open_with, "GuiToolkitTest.Sample.pdf")
	testing.expect(t, !still, "out of Open with")
	_, still = reg_get(open_with, "OtherPDF")
	testing.expect(t, still, "another program stays in Open with")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\OtherPDF", classes)), "another program's ProgID stays")
	_, st = state_of(o)
	testing.expect(t, !st.parts[.Documents].present, "taken out with the option")

	// remove: the same, and the person's choice is never edited
	o.document_types, o.open_documents, o.default_documents = DOCUMENT_TYPES[:], false, true   // (the default implies the association)
	testing.expect_value(t, install(o).error, Error.None)
	_, st = state_of(o)
	testing.expect(t, st.parts[.Documents].present, "the default asks for the association")
	testing.expect(t, documents_default_elsewhere(o), "the person's default is another program")
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, !reg_key_exists(progid) && !reg_key_exists(app) && !reg_key_exists(caps), "removed")
	_, st = state_of(o)
	testing.expect(t, !st.parts[.Documents].present, "removed")
	v, _ := reg_get(choice, "ProgId")
	testing.expect_value(t, v, "OtherPDF")
}

@(private = "file") THUMBNAIL_CLSID :: "{0b6a3f3e-2d1c-4b8e-9a7f-5c4d3e2f1a0b}"
@(private = "file") THUMBNAIL_SLOT :: "ShellEx\\{e357fccd-a995-4576-b01f-234630154e96}"   // (written out: the test checks the backend's constant)

// The Thumbnails part: the DLL beside the executable, its CLSID and server, the slot of each type and of its ProgID; to
// repair when an update brings other bytes; a type taken out of the list goes at the next install; the option off and
// remove take it all away, the DLL too, and leave another program's handler. (A scratch registry root and folder.)
@(test)
windows_thumbnails :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	o.document_types = DOCUMENT_TYPES[:]
	o.open_documents = true
	o.thumbnails = true
	o.thumbnail_clsid = THUMBNAIL_CLSID
	o.thumbnail_dll = transmute([]byte)string("MZ thumbnails v1")
	classes := fmt.tprintf("%s\\Classes", s.root)
	clsid := fmt.tprintf("%s\\CLSID\\%s", classes, THUMBNAIL_CLSID)
	dll := fmt.tprintf("%s\\v1\\sample_thumbnails.dll", s.dir)
	other_slot := fmt.tprintf("%s\\.fdf\\%s", classes, THUMBNAIL_SLOT)

	// without a CLSID: refused
	o.thumbnail_clsid = ""
	testing.expect_value(t, install(o).error, Error.Bad_Options)
	o.thumbnail_clsid = THUMBNAIL_CLSID

	testing.expect_value(t, install(o).error, Error.None)
	get :: proc(t: ^testing.T, path, name, want: string, loc := #caller_location) {
		v, ok := reg_get(path, name)
		testing.expectf(t, ok && v == want, "%s [%s] = %q (found %v), want %q", path, name, v, ok, want, loc = loc)
	}
	testing.expect_value(t, read_file(dll), "MZ thumbnails v1")
	get(t, clsid, "", "Sample thumbnails")
	get(t, fmt.tprintf("%s\\InprocServer32", clsid), "", dll)
	get(t, fmt.tprintf("%s\\InprocServer32", clsid), "ThreadingModel", "Apartment")
	get(t, fmt.tprintf("%s\\.pdf\\%s", classes, THUMBNAIL_SLOT), "", THUMBNAIL_CLSID)
	get(t, other_slot, "", THUMBNAIL_CLSID)
	get(t, fmt.tprintf("%s\\GuiToolkitTest.Sample.pdf\\%s", classes, THUMBNAIL_SLOT), "", THUMBNAIL_CLSID)
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.Thumbnails].present && !st.parts[.Thumbnails].partial && !st.parts[.Thumbnails].stale, "the part is there")

	// an update: other bytes, to repair, then the new DLL in place and nothing left beside it
	o.thumbnail_dll = transmute([]byte)string("MZ thumbnails, version 2")
	_, st = state_of(o)
	testing.expect(t, st.parts[.Thumbnails].partial, "the DLL is another version's")
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, read_file(dll), "MZ thumbnails, version 2")
	testing.expect(t, !os.exists(fmt.tprintf("%s.old", dll)) && !os.exists(fmt.tprintf("%s.new", dll)), "no .old / .new left")

	// the program moved: stale, and it names the old executable
	moved := o^
	moved.exe = s.exe2
	_, st = state_of(&moved)
	testing.expect(t, st.parts[.Thumbnails].stale, "it serves the old program's DLL")
	testing.expect(t, same_path(st.parts[.Thumbnails].target, s.exe), st.parts[.Thumbnails].target)

	// a type taken out of the list goes at the next install
	o.document_types = DOCUMENT_TYPES[:1]
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(other_slot), "the old type's slot")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\.fdf", classes)), "its extension's keys, left empty")

	// the option off: the keys and the DLL go; another program's handler of a type stays
	testing.expect(t, reg_set(other_slot, "", "{11111111-2222-3333-4444-555555555555}"), "another program's handler")
	o.document_types = DOCUMENT_TYPES[:]
	o.thumbnails = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(clsid), "the CLSID")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\.pdf\\ShellEx", classes)), "the slot")
	testing.expect(t, !os.exists(dll), "the DLL")
	get(t, other_slot, "", "{11111111-2222-3333-4444-555555555555}")
	_, st = state_of(o)
	testing.expect(t, !st.parts[.Thumbnails].present, "taken out with the option")

	// remove: the same
	o.thumbnails = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, !reg_key_exists(clsid) && !os.exists(dll), "removed")
	_, st = state_of(o)
	testing.expect(t, !st.parts[.Thumbnails].present, "removed")

	// a build without a provider has no part to want: never to repair for it
	o.thumbnail_dll = nil
	when BUILT_THUMBNAIL_DLL_FILE == "" {
		testing.expect(t, !thumbnails_wanted(o), "no DLL, no part")
	}
}

// The uninstall takes the provider with the files it placed, though the manifest does not name it.
@(test)
windows_thumbnail_dll_goes_with_the_install_folder :: proc(t: ^testing.T) {
	tr := tree_make()
	defer tree_destroy(&tr)
	testing.expect_value(t, files_install(plan_of(&tr)).error, Error.None)
	dll := fmt.tprintf("%s\\sample_thumbnails.dll", tr.dst)
	testing.expect(t, os.write_entire_file(dll, "MZ thumbnails") == nil, "the provider install wrote")
	r := files_remove(&tr.opts, tr.dst)
	testing.expect_value(t, len(r.leftovers), 0)
	testing.expect(t, !os.exists(dll), "gone")
	testing.expect(t, r.folder && !os.exists(tr.dst), "so is the folder")
}

// The File_Manager part: Win+E's new window and the default verb of folders and drives run the program; to repair when
// a piece goes; taken out with the option and by remove, the system's default verb back and another program's left.
// (A scratch registry root: the user's own Classes are never touched.)
@(private = "file")
FILE_EXPLORER_KEY :: "{52205fd8-5dfb-447d-801a-d0b52f2e83e1}"   // (written out: the test checks the backend's constant)

@(test)
windows_file_manager :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	explorer := fmt.tprintf("%s\\Classes\\CLSID\\%s", s.root, FILE_EXPLORER_KEY)
	window := fmt.tprintf("%s\\shell\\opennewwindow", explorer)
	folders := fmt.tprintf("%s\\Classes\\Directory\\shell", s.root)
	drives := fmt.tprintf("%s\\Classes\\Drive\\shell", s.root)
	o.default_file_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	cmd, ok := reg_get(fmt.tprintf("%s\\command", window), "")
	testing.expect(t, ok && cmd == fmt.tprintf("\"%s\"", s.exe), "Win+E runs the program")
	delegate, delegate_ok := reg_get(fmt.tprintf("%s\\command", window), "DelegateExecute")
	testing.expect(t, delegate_ok && delegate == "", "DelegateExecute is there and empty")
	for shell in ([]string{folders, drives}) {
		verb, _ := reg_get(shell, "")
		testing.expect_value(t, verb, "Sample.open")
	}
	open, _ := reg_get(fmt.tprintf("%s\\Sample.open\\command", folders), "")
	testing.expect_value(t, open, fmt.tprintf("\"%s\" \"%%1\"", s.exe))
	open, _ = reg_get(fmt.tprintf("%s\\Sample.open\\command", drives), "")
	testing.expect_value(t, open, fmt.tprintf("\"%s\" %%1", s.exe))   // ("C:\" quoted would read as C:")
	state, st := state_of(o)
	testing.expect_value(t, state, State.Installed)
	testing.expect(t, st.parts[.File_Manager].present && !st.parts[.File_Manager].partial && !st.parts[.File_Manager].stale, "the part is there")

	// another default verb for folders: to repair, then repaired
	testing.expect(t, reg_set(folders, "", "open"))
	_, st = state_of(o)
	testing.expect(t, st.parts[.File_Manager].partial, "the folders' default is another verb")
	testing.expect_value(t, install(o).error, Error.None)
	state, _ = state_of(o)
	testing.expect_value(t, state, State.Installed)

	// the program moved: stale
	moved := o^
	moved.exe = s.exe2
	_, st = state_of(&moved)
	testing.expect(t, st.parts[.File_Manager].stale, "it runs the old program")

	// the option off: everything goes, the empty parents too
	o.default_file_manager = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(window), "Win+E is File Explorer's again")
	testing.expect(t, !reg_key_exists(explorer), "nothing of ours under the CLSID")
	testing.expect(t, !reg_key_exists(folders) && !reg_key_exists(drives), "the default verbs are the system's again")
	_, st = state_of(o)
	testing.expect(t, !st.parts[.File_Manager].present, "taken out with the option")

	// remove: another program's verb stays, and the default it set too
	o.default_file_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, reg_set(fmt.tprintf("%s\\Other.open\\command", drives), "", `"C:\other\other.exe" "%1"`))
	testing.expect(t, reg_set(drives, "", "Other.open"))
	testing.expect_value(t, remove(o).error, Error.None)
	_, st = state_of(o)
	testing.expect(t, !st.parts[.File_Manager].present, "removed")
	verb, _ := reg_get(drives, "")
	testing.expect_value(t, verb, "Other.open")
	testing.expect(t, reg_key_exists(fmt.tprintf("%s\\Other.open", drives)), "another program's verb stays")
	_, verb_ok := reg_get(folders, "")
	testing.expect(t, !verb_ok, "the folders' default is the system's again")
}

// The verbs a program names (ShellExecute "open", "explore"): the program's under Directory and Drive, hidden from the
// context menu; one that another program made stays its own, and the part is whole without it; removal leaves it.
@(test)
windows_file_manager_named_verbs :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	folders := fmt.tprintf("%s\\Classes\\Directory\\shell", s.root)
	drives := fmt.tprintf("%s\\Classes\\Drive\\shell", s.root)
	// another program's "explore" of drives, there first
	other := fmt.tprintf("%s\\explore\\command", drives)
	testing.expect(t, reg_set(other, "", `"C:\other\other.exe" %1`))
	o.default_file_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	for verb in ([]string{"open", "explore"}) {
		key := fmt.tprintf("%s\\%s", folders, verb)
		cmd, ok := reg_get(fmt.tprintf("%s\\command", key), "")
		testing.expect(t, ok && cmd == fmt.tprintf("\"%s\" \"%%1\"", s.exe), "a folder's named verb runs the program")
		hidden, hidden_ok := reg_get(key, "ProgrammaticAccessOnly")
		testing.expect(t, hidden_ok && hidden == "", "not in the context menu")
		delegate, delegate_ok := reg_get(fmt.tprintf("%s\\command", key), "DelegateExecute")
		testing.expect(t, delegate_ok && delegate == "", "the command, not File Explorer's handler")
	}
	open, _ := reg_get(fmt.tprintf("%s\\open\\command", drives), "")
	testing.expect_value(t, open, fmt.tprintf("\"%s\" %%1", s.exe))
	kept, _ := reg_get(other, "")
	testing.expect_value(t, kept, `"C:\other\other.exe" %1`)
	st := status(o, context.temp_allocator)
	testing.expect(t, st.parts[.File_Manager].present && !st.parts[.File_Manager].partial, "whole without another program's verb")

	// an install from before the named verbs: to repair, then repaired
	testing.expect(t, reg_delete_tree(fmt.tprintf("%s\\open", folders)))
	testing.expect(t, status(o, context.temp_allocator).parts[.File_Manager].partial, "a named verb is missing")
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !status(o, context.temp_allocator).parts[.File_Manager].partial, "repaired")

	testing.expect_value(t, remove(o).error, Error.None)
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\open", folders)) && !reg_key_exists(fmt.tprintf("%s\\explore", folders)), "the program's named verbs gone")
	testing.expect(t, !reg_key_exists(fmt.tprintf("%s\\open", drives)), "the drives' too")
	kept, _ = reg_get(other, "")
	testing.expect_value(t, kept, `"C:\other\other.exe" %1`)
}

// The Task_Manager part on a test's roots: a key under HKCU in place of HKLM's Image File Execution Options and a
// scratch folder in place of Program Files, so no administrator is asked. The Debugger runs the machine copy; the one
// there before (of its kind) comes back with Off; another program's taken since stays; removal takes the copy.
@(test)
windows_task_manager :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.image_options_root = fmt.tprintf("%s\\Image File Execution Options", s.root)
	key := fmt.tprintf("%s\\taskmgr.exe", o.image_options_root)
	o.task_manager = true

	// a test's key needs its own folder for the copy: never Program Files
	testing.expect_value(t, install(o).error, Error.Bad_Options)
	o.machine_dir = fmt.tprintf("%s\\Program Files\\Sample", s.dir)
	copy := fmt.tprintf("%s\\sample.exe", o.machine_dir)
	testing.expect_value(t, task_manager_copy(o), copy)

	before := `%SystemRoot%\Tools\other.exe`
	testing.expect(t, reg_set_kind(key, "Debugger", before, expand = true))
	testing.expect_value(t, install(o).error, Error.None)
	debugger, expand, ok := reg_get_any(key, "Debugger")
	testing.expect(t, ok && !expand, "a REG_SZ Debugger")
	testing.expect_value(t, debugger, fmt.tprintf("\"%s\"", copy))
	mark, _ := reg_get(key, "SampleIntegration")
	testing.expect_value(t, mark, "GuiToolkit.Sample.Test")
	kept, kept_expand, _ := reg_get_any(key, "SampleIntegrationPrevious")
	testing.expect(t, kept == before && kept_expand, "the Debugger before, of its kind")
	data, read_err := os.read_entire_file(copy, context.temp_allocator)
	testing.expect(t, read_err == nil && string(data) == "MZ not a program", "the machine copy is the program")
	st := status(o, context.temp_allocator)
	ps := st.parts[.Task_Manager]
	testing.expect(t, ps.present && !ps.partial && !ps.stale, "the part is there")
	testing.expect_value(t, st.state, State.Installed)

	// the machine copy gone: to repair, then repaired
	testing.expect(t, os.remove(copy) == nil)
	testing.expect(t, status(o, context.temp_allocator).parts[.Task_Manager].partial, "no machine copy")
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, os.is_file(copy), "copied again")

	// off: the Debugger before, exactly; nothing of ours
	o.task_manager = false
	testing.expect_value(t, install(o).error, Error.None)
	debugger, expand, ok = reg_get_any(key, "Debugger")
	testing.expect(t, ok && expand && debugger == before, "given back with its kind")
	_, marked := reg_get(key, "SampleIntegration")
	_, kept_ok := reg_get(key, "SampleIntegrationPrevious")
	testing.expect(t, !marked && !kept_ok, "the marks gone")
	testing.expect(t, !os.is_file(copy), "the machine copy gone")
	testing.expect(t, !status(o, context.temp_allocator).parts[.Task_Manager].present, "the part is gone")

	// none before: none after, and the key goes
	testing.expect(t, reg_delete_value(key, "Debugger"))
	o.task_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	o.task_manager = false
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !reg_key_exists(key), "nothing of ours left in the key")

	// another program takes Task Manager after ours: stale; removal leaves its Debugger, takes the marks and the copy
	o.task_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, reg_set(key, "Debugger", `"C:\Tools\systeminformer.exe"`))
	ps = status(o, context.temp_allocator).parts[.Task_Manager]
	testing.expect(t, ps.present && ps.stale, "another program's now")
	testing.expect_value(t, remove(o).error, Error.None)
	debugger, _ = reg_get(key, "Debugger")
	testing.expect_value(t, debugger, `"C:\Tools\systeminformer.exe"`)
	_, marked = reg_get(key, "SampleIntegration")
	testing.expect(t, !marked && !os.is_file(copy), "the marks and the copy gone")
}

// This account's record (HKCU): On sets it, Off and removal take it. Another account's part (marks and Debugger in the
// machine's key, no record here) stays at this account's Uninstall: nothing is asked, nothing is changed.
@(test)
windows_task_manager_of_another_account :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.image_options_root = fmt.tprintf("%s\\Image File Execution Options", s.root)
	o.machine_dir = fmt.tprintf("%s\\Program Files\\Sample", s.dir)
	key := fmt.tprintf("%s\\taskmgr.exe", o.image_options_root)
	record := fmt.tprintf("%s\\GuiToolkitTest\\Sample", s.root)
	copy := task_manager_copy(o)

	o.task_manager = true
	testing.expect_value(t, install(o).error, Error.None)
	here, here_ok := reg_get(record, "TaskManagerSetHere")
	testing.expect(t, here_ok && here == "1", "this account put it")
	o.task_manager = false
	testing.expect_value(t, install(o).error, Error.None)
	_, here_ok = reg_get(record, "TaskManagerSetHere")
	testing.expect(t, !here_ok, "taken with the part")

	// another account's: written in the machine's key, no record of this one
	testing.expect_value(t, task_manager_write(o, true).error, Error.None)
	_, here_ok = reg_get(record, "TaskManagerSetHere")
	testing.expect(t, !here_ok, "not this account's")
	testing.expect_value(t, remove(o).error, Error.None)
	debugger, _ := reg_get(key, "Debugger")
	testing.expect_value(t, debugger, fmt.tprintf("\"%s\"", copy))
	testing.expect(t, os.is_file(copy), "its machine copy stays")
	testing.expect(t, status(o, context.temp_allocator).parts[.Task_Manager].present, "the part stays")

	// the box unticked by a person of this account: an explicit request, whoever put the part
	testing.expect_value(t, install(o).error, Error.None)
	testing.expect(t, !status(o, context.temp_allocator).parts[.Task_Manager].present, "given back")
}

// The machine copy is this very process's image, read through a handle that holds it (not the file at a path).
@(test)
windows_image_copy_self :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	dst := fmt.tprintf("%s\\Program Files\\Sample\\sample.exe", s.dir)
	testing.expect_value(t, image_copy_self(dst).error, Error.None)
	got, got_err := os.read_entire_file(dst, context.temp_allocator)
	want, want_err := os.read_entire_file(process.executable_path(), context.temp_allocator)
	testing.expect(t, got_err == nil && want_err == nil && len(got) > 0 && string(got) == string(want), "the bytes of the running program")
	// again over the first: replaced, no file left beside it
	testing.expect_value(t, image_copy_self(dst).error, Error.None)
	testing.expect(t, !os.exists(fmt.tprintf("%s.new", dst)), "no .new left")
}
