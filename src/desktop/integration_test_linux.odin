package tk_desktop

// The Linux backend on scratch applications, icons and bin directories (never the real ones).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
Scratch :: struct {
	dir:  string,
	exe:  string,
	exe2: string,
	opts: Integration_Options,
}

@(private = "file")
scratch_make :: proc() -> Scratch {
	tmp, _ := os.temp_dir(context.allocator)
	id := test_unique_id()
	s: Scratch
	s.dir = fmt.aprintf("%s/tk_desktop_test_%s", tmp, id)
	s.exe = fmt.aprintf("%s/v1/sample dir/sample", s.dir)   // (a space: the Exec line must quote it)
	s.exe2 = fmt.aprintf("%s/v2/sample", s.dir)
	for p in ([]string{s.exe, s.exe2} ) {
		_ = os.make_directory_all(p[:strings.last_index_byte(p, '/')])
		_ = os.write_entire_file(p, "#!/bin/sh\n")
	}
	png := transmute([]byte)string("\x89PNG\r\n\x1a\n")
	icons := make([]Icon, 3, context.temp_allocator)
	for i, k in ([]int{16, 64, 256}) { icons[k] = Icon{size = i, png = png} }
	s.opts = Integration_Options{
		identity = test_identity(),
		exe = s.exe, register_browser = true, start_menu = true, file_types = split_list(".html,.svg", context.temp_allocator), icons = icons,
		applications_dir = fmt.aprintf("%s/share/applications", s.dir), icons_dir = fmt.aprintf("%s/share/icons/hicolor", s.dir),
		bin_dir = fmt.aprintf("%s/bin", s.dir), autostart_dir = fmt.aprintf("%s/config/autostart", s.dir), notify_system = false,
		config_dir = fmt.aprintf("%s/config", s.dir),
		desktop_dir = fmt.aprintf("%s/Desktop", s.dir),   // (never the user's: remove takes out a copy that is the program's)
	}
	delete(tmp)
	delete(id)
	return s
}

@(private = "file")
scratch_destroy :: proc(s: ^Scratch) {
	_ = os.remove_all(s.dir)
	delete(s.dir); delete(s.exe); delete(s.exe2); delete(s.opts.applications_dir); delete(s.opts.icons_dir); delete(s.opts.bin_dir); delete(s.opts.autostart_dir); delete(s.opts.desktop_dir)
	delete(s.opts.config_dir)
}

@(private = "file")
expect_ok :: proc(t: ^testing.T, r: Result, loc := #caller_location) {
	testing.expectf(t, r.error == .None, "%v: %s", r.error, r.detail, loc = loc)
}

// A program goes to ~/.local/opt/<vendor_key>/<name>, never beside its data in ~/.local/share; without a vendor, to
// ~/.local/opt/<name>.
@(test)
the_default_install_folder_is_its_vendors_in_opt :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity()}
	o.identity.vendor_key, o.identity.name = "FromentSoftware", "Papier"
	dir := linux_default_install_dir(&o, context.temp_allocator)
	testing.expectf(t, strings.has_suffix(dir, "/.local/opt/FromentSoftware/Papier"), "%s", dir)
	o.identity.vendor_key = ""
	testing.expect(t, strings.has_suffix(linux_default_install_dir(&o, context.temp_allocator), "/.local/opt/Papier"))
}

@(test)
linux_round_trip :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)

	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)

	expect_ok(t, install(o))
	st = status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, os.is_file(entry), "the desktop entry")
	for size in ([]int{16, 64, 256}) {
		testing.expect(t, os.is_file(fmt.tprintf("%s/%dx%d/apps/sample.png", o.icons_dir, size, size)), "an icon per size")
	}
	text, _ := os.read_entire_file(entry, context.temp_allocator)
	testing.expect_value(t, string(text), desktop_entry_text(o))
	exec, _ := entry_value(string(text), "Exec")
	testing.expect_value(t, exec_program(exec), s.exe)

	// the program moved
	moved := o^
	moved.exe = s.exe2
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Repair)
	testing.expect_value(t, st.stale_exe, s.exe)
	expect_ok(t, install(&moved))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)

	// an icon size is gone
	_ = os.remove(fmt.tprintf("%s/64x64/apps/sample.png", o.icons_dir))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Repair)
	testing.expect(t, st.incomplete, "incomplete")
	expect_ok(t, install(&moved))

	expect_ok(t, remove(&moved))
	st = status(&moved, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)
	testing.expect(t, !os.exists(entry), "the entry is gone")
	testing.expect(t, !os.exists(fmt.tprintf("%s/16x16/apps/sample.png", o.icons_dir)), "the icons are gone")
	expect_ok(t, remove(&moved))
}

@(test)
linux_removal_leaves_other_programs :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	_ = os.make_directory_all(o.applications_dir)
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)
	other := fmt.tprintf("%s/other.desktop", o.applications_dir)
	_ = os.write_entire_file(other, "[Desktop Entry]\nExec=/usr/bin/other\n")
	// a file of the same name that is not the program's (no mark, another Exec)
	_ = os.write_entire_file(entry, "[Desktop Entry]\nName=Sample\nExec=/usr/bin/something-else\n")

	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)
	expect_ok(t, remove(o))
	testing.expect(t, os.is_file(entry), "not marked: stays")
	testing.expect(t, os.is_file(other), "other entries stay")

	expect_ok(t, install(o))   // the user asked: it replaces the file
	expect_ok(t, remove(o))
	testing.expect(t, !os.exists(entry), "now marked: removed")
	testing.expect(t, os.is_file(other), "other entries stay")
}

// The PATH part: a link in the bin directory, replaced when it runs another program, taken out with the option, and
// never one that is not the program's.
@(test)
linux_path_link :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	link := fmt.tprintf("%s/sample", o.bin_dir)
	o.add_to_path = true
	expect_ok(t, install(o))
	target, err := os.read_link(link, context.temp_allocator)
	testing.expect(t, err == nil && target == s.exe, "the link runs the program")
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Path].present && !st.parts[.Path].stale, "the PATH part is there")

	moved := o^
	moved.exe = s.exe2
	st = status(&moved, context.temp_allocator)
	testing.expect(t, st.parts[.Path].stale, "it runs the old program")
	expect_ok(t, install(&moved))
	target, _ = os.read_link(link, context.temp_allocator)
	testing.expect_value(t, target, s.exe2)

	// the option off: the link goes
	moved.add_to_path = false
	expect_ok(t, install(&moved))
	testing.expect(t, !os.exists(link), "taken out with the option")

	// another program's link of that name stays, through install and removal
	_ = os.symlink("/usr/bin/true", link)
	moved.add_to_path = false
	expect_ok(t, install(&moved))
	expect_ok(t, remove(&moved))
	target, err = os.read_link(link, context.temp_allocator)
	testing.expect(t, err == nil && target == "/usr/bin/true", "not the program's: it stays")

	// uninstalling a folder takes out a link into it
	_ = os.remove(link)
	moved.add_to_path = true
	expect_ok(t, install(&moved))
	expect_ok(t, forget_path(&moved, fmt.tprintf("%s/v2", s.dir)))
	testing.expect(t, !os.exists(link), "the folder's link is gone")
}

// The Autostart part: an entry that starts the program with its arguments at the start of the session, repaired when
// the arguments change, taken out with the option and by remove; another program's entry of that name stays.
@(test)
linux_autostart :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	entry := fmt.tprintf("%s/sample.desktop", o.autostart_dir)
	o.autostart, o.autostart_arguments = true, "--hidden"
	expect_ok(t, install(o))
	text, err := os.read_entire_file(entry, context.temp_allocator)
	testing.expect(t, err == nil, "the autostart entry")
	testing.expect_value(t, string(text), autostart_entry_text(o))
	exec, _ := entry_value(string(text), "Exec")
	testing.expect(t, strings.has_suffix(exec, " --hidden"), "started with its arguments")
	testing.expect_value(t, exec_program(exec), s.exe)
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Autostart].present && !st.parts[.Autostart].partial, "the part is there")

	// other arguments: to repair, then repaired
	o.autostart_arguments = "--tray"
	st = status(o, context.temp_allocator)
	testing.expect(t, st.parts[.Autostart].partial, "other arguments")
	testing.expect_value(t, st.state, State.Repair)
	expect_ok(t, install(o))
	testing.expect_value(t, status(o, context.temp_allocator).state, State.Installed)

	// the option off: the entry goes
	o.autostart = false
	expect_ok(t, install(o))
	testing.expect(t, !os.exists(entry), "taken out with the option")

	// remove takes it out; another program's entry of that name stays
	o.autostart = true
	expect_ok(t, install(o))
	expect_ok(t, remove(o))
	testing.expect(t, !os.exists(entry), "removed")
	_ = os.write_entire_file(entry, "[Desktop Entry]\nName=Sample\nExec=/usr/bin/something-else\n")
	expect_ok(t, remove(o))
	testing.expect(t, os.is_file(entry), "not the program's: stays")
}

// The desktop's copy of the entry: written executable with the option, its part present; taken out with the option off and by
// remove; another program's file of that name stays, and Install says so.
@(test)
linux_desktop_shortcut :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	copy := fmt.tprintf("%s/sample.desktop", o.desktop_dir)
	o.desktop_shortcut = true
	expect_ok(t, install(o))
	text, err := os.read_entire_file(copy, context.temp_allocator)
	testing.expect(t, err == nil, "the copy on the desktop")
	testing.expect_value(t, string(text), desktop_entry_text(o))
	if info, serr := os.stat(copy, context.temp_allocator); serr == nil {
		testing.expect(t, .Execute_User in info.mode, "executable: a desktop starts only such an entry")
	}
	testing.expect(t, status(o, context.temp_allocator).parts[.Desktop_Shortcut].present, "the part is there")
	o.desktop_shortcut = false
	expect_ok(t, install(o))
	testing.expect(t, !os.exists(copy), "taken out with the option")
	o.desktop_shortcut = true
	expect_ok(t, install(o))
	expect_ok(t, remove(o))
	testing.expect(t, !os.exists(copy), "removed")
	_ = os.write_entire_file(copy, "[Desktop Entry]\nName=Sample\nExec=/usr/bin/something-else\n")
	testing.expect(t, install(o).error != .None, "another program's file: not replaced")
	expect_ok(t, remove(o))
	testing.expect(t, os.is_file(copy), "not the program's: stays")
}

// The File_Manager part: the entry made the default of folders in mimeapps.list, the person's former default kept after
// it and given back with the option off and by remove; another program's default is never touched.
@(test)
linux_file_manager :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	o.identity.url_schemes = nil   // (a program of no addresses: its entry takes folders as paths, %F)
	list := fmt.tprintf("%s/mimeapps.list", o.config_dir)
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)
	_ = os.make_directory_all(o.config_dir)
	person := "[Default Applications]\ntext/plain=gedit.desktop\ninode/directory=org.gnome.Nautilus.desktop;\n"
	_ = os.write_entire_file(list, person)

	o.default_file_manager = true
	expect_ok(t, install(o))
	text, _ := os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, mimeapps_default(string(text), DIRECTORY_MIME), "sample.desktop")
	testing.expect(t, strings.contains(string(text), "text/plain=gedit.desktop"), "the person's other lines stay")
	content, _ := os.read_entire_file(entry, context.temp_allocator)
	mime, _ := entry_value(string(content), "MimeType")
	exec, _ := entry_value(string(content), "Exec")
	testing.expect(t, strings.contains(mime, "inode/directory;"), "the entry takes folders")
	testing.expect(t, strings.has_suffix(exec, " %F"), "a folder is its argument")
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.File_Manager].present && !st.parts[.File_Manager].partial && !st.parts[.File_Manager].stale, "the part is there")

	// an entry that does not take folders: to repair
	o.default_file_manager = false
	_ = os.write_entire_file(entry, desktop_entry_text(o))
	o.default_file_manager = true
	testing.expect(t, status(o, context.temp_allocator).parts[.File_Manager].partial, "the entry does not take folders")
	expect_ok(t, install(o))
	testing.expect_value(t, status(o, context.temp_allocator).state, State.Installed)

	// the option off: the former default comes back
	o.default_file_manager = false
	expect_ok(t, install(o))
	text, _ = os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, mimeapps_default(string(text), DIRECTORY_MIME), "org.gnome.Nautilus.desktop")
	testing.expect(t, !strings.contains(string(text), "sample.desktop"), "nothing of ours is left")
	testing.expect(t, !status(o, context.temp_allocator).parts[.File_Manager].present, "taken out with the option")

	// remove takes it out too
	o.default_file_manager = true
	expect_ok(t, install(o))
	expect_ok(t, remove(o))
	text, _ = os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, mimeapps_default(string(text), DIRECTORY_MIME), "org.gnome.Nautilus.desktop")

	// another program's default: not the part, and it stays
	_ = os.write_entire_file(list, person)
	testing.expect(t, !status(o, context.temp_allocator).parts[.File_Manager].present, "another program's default")
	expect_ok(t, remove(o))
	text, _ = os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, string(text), person)
}

@(private = "file") PDF := [?]Document_Type{{".pdf", "application/pdf", "PDF Document"}}

// The Documents and Default_Documents parts: the entry lists the type and takes one file, and with the default the
// type's line of mimeapps.list names it first, the person's former default after it; without the launcher the entry
// stays, hidden; the option off and remove take each away, and give the former default back.
@(test)
linux_documents :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	o.identity.url_schemes = nil   // (a program of no addresses: one file as %f)
	o.document_types = PDF[:]
	list := fmt.tprintf("%s/mimeapps.list", o.config_dir)
	entry := fmt.tprintf("%s/sample.desktop", o.applications_dir)
	_ = os.make_directory_all(o.config_dir)
	person := "[Default Applications]\napplication/pdf=org.gnome.Evince.desktop;\ntext/plain=gedit.desktop\n"
	_ = os.write_entire_file(list, person)

	// in "Open with": the entry, no default
	o.open_documents = true
	expect_ok(t, install(o))
	content, _ := os.read_entire_file(entry, context.temp_allocator)
	mime, _ := entry_value(string(content), "MimeType")
	exec, _ := entry_value(string(content), "Exec")
	testing.expect_value(t, mime, "application/pdf;")
	testing.expect(t, strings.has_suffix(exec, " %f"), "one file is its argument")
	text, _ := os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, string(text), person)
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Documents].present && !st.parts[.Documents].partial, "the part is there")
	testing.expect(t, !st.parts[.Default_Documents].present, "not the default")

	// the default: first in the type's line, the former default after it
	o.default_documents = true
	testing.expect_value(t, status(o, context.temp_allocator).state, State.Repair)
	expect_ok(t, install(o))
	text, _ = os.read_entire_file(list, context.temp_allocator)
	ids := mimeapps_defaults(string(text), "application/pdf")
	testing.expectf(t, len(ids) == 2 && ids[0] == "sample.desktop" && ids[1] == "org.gnome.Evince.desktop", "the type's line: %v", ids)
	testing.expect(t, strings.contains(string(text), "text/plain=gedit.desktop"), "the person's other lines stay")
	st = status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Default_Documents].present && !st.parts[.Default_Documents].partial, "the default is there")

	// without the launcher: the entry stays for "Open with", hidden from the menu
	o.start_menu = false
	expect_ok(t, install(o))
	content, _ = os.read_entire_file(entry, context.temp_allocator)
	hidden, _ := entry_value(string(content), "NoDisplay")
	testing.expect_value(t, hidden, "true")
	st = status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, !st.parts[.Launcher].present && st.parts[.Documents].present, "no launcher, the documents")
	expect_ok(t, apply(o))   // (Installed, nothing unwanted: nothing written)

	// the default off: the former default comes back, the association stays
	o.start_menu, o.default_documents = true, false
	expect_ok(t, install(o))
	text, _ = os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, mimeapps_default(string(text), "application/pdf"), "org.gnome.Evince.desktop")
	testing.expect(t, !strings.contains(string(text), "sample.desktop"), "nothing of ours is left")
	testing.expect(t, status(o, context.temp_allocator).parts[.Documents].present, "still in Open with")

	// the association off: the entry no longer lists the type
	o.open_documents = false
	expect_ok(t, install(o))
	content, _ = os.read_entire_file(entry, context.temp_allocator)
	testing.expect(t, !strings.contains(string(content), "application/pdf"), "the type went with the option")
	testing.expect(t, !status(o, context.temp_allocator).parts[.Documents].present, "taken out with the option")

	// remove takes everything away, the file as the person had it
	o.open_documents, o.default_documents = true, true
	expect_ok(t, install(o))
	expect_ok(t, remove(o))
	testing.expect(t, !os.exists(entry), "the entry is gone")
	text, _ = os.read_entire_file(list, context.temp_allocator)
	testing.expect_value(t, string(text), person)
	st = status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Absent)
}

// What the settings ask (apply): the launcher, then the start with the session alone (the launcher goes), then nothing.
@(test)
linux_apply_follows_the_settings :: proc(t: ^testing.T) {
	s := scratch_make()
	defer scratch_destroy(&s)
	o := &s.opts
	o.register_browser = false
	expect_ok(t, apply(o))
	st := status(o, context.temp_allocator)
	testing.expect_value(t, st.state, State.Installed)
	testing.expect(t, st.parts[.Launcher].present && !st.parts[.Autostart].present, "the launcher alone")
	expect_ok(t, apply(o))   // (nothing differs: nothing written, nothing refused)

	o.start_menu, o.autostart = false, true
	expect_ok(t, apply(o))
	st = status(o, context.temp_allocator)
	testing.expect(t, !st.parts[.Launcher].present, "the launcher went with general.menu")
	testing.expect(t, st.parts[.Autostart].present, "the start with the session came")

	o.autostart = false
	expect_ok(t, apply(o))
	st = status(o, context.temp_allocator)
	testing.expect(t, !st.parts[.Launcher].present && !st.parts[.Autostart].present, "nothing asked: nothing there")
}
