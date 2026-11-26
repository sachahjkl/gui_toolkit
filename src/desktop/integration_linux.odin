package tk_desktop

// Linux: the freedesktop.org way (XDG), all under the user's data directory. An install for everyone (scope System,
// scope_linux.odin) puts the parts of machine_parts() under /usr/local (share/applications, share/icons,
// share/thumbnailers, bin), from the elevated verb; the others stay the person's.
//
//   $XDG_DATA_HOME/applications/<slug>.desktop       the desktop entry (desktop_entry.odin): name, Exec, Icon, the
//                                                    identity's categories and, for a browser, MimeType= for http,
//                                                    https, its URL schemes and the configured file types, so that
//                                                    "open with" and the default browser setting list the program
//   $XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/<slug>.png   the icons, one per size the program embeds
//   ~/.local/bin/<slug>                              the PATH part: a link to the executable
//   $XDG_CONFIG_HOME/autostart/<slug>.desktop        the Autostart part: the program at the start of the session
//   <desktop folder>/<slug>.desktop                  the Desktop_Shortcut part: a copy of the entry, executable (a desktop
//                                                    starts only an executable entry); the folder is platform.known_folder_path(.Desktop)'s
//   $XDG_CONFIG_HOME/mimeapps.list                   the File_Manager part: [Default Applications]
//                                                    inode/directory=<slug>.desktop, the person's former default kept
//                                                    after it; the entry then takes inode/directory (MimeType) and %F
//   the entry's MimeType=                            the Documents part: the MIME type of each document type, and %f;
//                                                    without the Launcher the entry stays, NoDisplay=true
//   $XDG_CONFIG_HOME/mimeapps.list                   the Default_Documents part: <mime>=<slug>.desktop for each of them,
//                                                    as the File_Manager part does for folders
//   $XDG_DATA_HOME/thumbnailers/<slug>.thumbnailer   the Thumbnails part: the program draws its documents' thumbnails
//                                                    (thumbnail_provider_linux.odin)
//
// $XDG_DATA_HOME defaults to ~/.local/share (and must be an absolute path, as the specification says). After a change
// `update-desktop-database <applications>` rebuilds the MIME cache when that tool is installed.
//
// The mark of the program in a desktop entry is its `Identity.entry_marker` line (or an Exec that runs the executable).

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../fsx"
import "../platform"
import "../process"

@(private = "file")
LINUX_BACKEND := Backend{
	name = "linux",
	parts = {.Launcher, .Desktop_Shortcut, .Icons, .Path, .Autostart, .File_Manager, .Documents, .Default_Documents, .Thumbnails},
	status = linux_status,
	install = linux_install,
	remove = linux_remove,
	open_defaults = nil,   // each desktop has its own settings program; there is no portable address for it
	default_install_dir = linux_default_install_dir,
	path_remove = linux_path_remove,
}

@(private)
platform_backend :: proc() -> ^Backend { return &LINUX_BACKEND }

// A copy is installed under the data directory: $XDG_DATA_HOME/<slug> (~/.local/share/<slug>). Linux has no desktop
// shortcut or Apps-list part (those are Windows parts: docs/desktop.md). Nothing records the install: the manifest in the
// folder is the record.
@(private)
linux_default_install_dir :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> string {
	if o.scope == .System { return system_install_dir(o, allocator) }   // (/opt/<vendor_key>/<name>: scope_linux.odin)
	// (~/.local/opt/<vendor>/<name>: a program in a folder of its own, as /opt holds one for every user, apart from
	// its data in ~/.local/share/<vendor>/<name> that an uninstall leaves; XDG names no place for programs:
	// src/md/features/folders.md)
	home := platform.known_folder_path(.Home, context.temp_allocator)
	if home == "" { return "" }
	if o.identity.vendor_key == "" { return strings.concatenate({home, "/.local/opt/", o.identity.name}, allocator) }
	return strings.concatenate({home, "/.local/opt/", o.identity.vendor_key, "/", o.identity.name}, allocator)
}

// The window class and application id belong to the toolkit's window on this platform.
set_process_identity :: proc(id: Identity) {}

// Sizes the theme directories are named after: what is looked for, to remove icons of an older set.
@(private = "file")
ICON_SIZES := [?]int{16, 22, 24, 32, 48, 64, 96, 128, 256, 512}

@(private = "file")
Layout :: struct {
	applications: string,
	icons:        string,   // the hicolor directory
	entry:        string,   // the .desktop file
}

@(private = "file")
layout_of :: proc(o: ^Integration_Options) -> (l: Layout, ok: bool) {
	if in_machine(o) {
		// (the machine half of a system install: /usr/local/share, in every account's XDG_DATA_DIRS)
		share := machine_share(o)
		l.applications = strings.concatenate({share, "/applications"}, context.temp_allocator)
		l.icons = strings.concatenate({share, "/icons/hicolor"}, context.temp_allocator)
		l.entry = strings.concatenate({l.applications, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
		return l, true
	}
	data_home := ""
	if o.applications_dir == "" || o.icons_dir == "" {
		data_home = platform.user_dir(.Data, "", context.temp_allocator)
		if data_home == "" { return {}, false }
	}
	l.applications = o.applications_dir != "" ? o.applications_dir : strings.concatenate({data_home, "/applications"}, context.temp_allocator)
	l.icons = o.icons_dir != "" ? o.icons_dir : strings.concatenate({data_home, "/icons/hicolor"}, context.temp_allocator)
	l.entry = strings.concatenate({l.applications, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
	return l, true
}

@(private = "file")
icon_path :: proc(l: Layout, slug: string, size: int) -> string {
	buf: [24]u8
	n := strconv.write_int(buf[:], i64(size), 10)
	return strings.concatenate({l.icons, "/", n, "x", n, "/apps/", slug, ".png"}, context.temp_allocator)
}

////////////////////////////////
// Status

@(private = "file")
linux_status :: proc(o: ^Integration_Options, allocator: runtime.Allocator) -> Status {
	s: Status
	l, ok := layout_of(o)
	if !ok { s.error = .System; return s }

	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil {
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		target := exec_program(exec)
		if mark == o.identity.slug || same_path(target, o.exe) {
			mime, _ := entry_value(content, "MimeType")
			// (a hidden entry is there for "Open with" alone: the menu does not list it)
			if hidden, _ := entry_value(content, "NoDisplay"); hidden != "true" {
				ps := &s.parts[.Launcher]
				ps.present = true
				ps.target = clone_or_empty(target, allocator)
				ps.stale = !same_path(target, o.exe)
				if o.register_browser {
					ps.partial = !strings.contains(mime, "x-scheme-handler/https")
					for name in o.identity.url_schemes {   // (an entry of a version without the schemes: Repair adds them)
						if !strings.contains(mime, strings.concatenate({SCHEME_MIME_PREFIX, name, ";"}, context.temp_allocator)) { ps.partial = true }
					}
				}
			}
			// Documents: the entry lists the types (partial: some of them; a %f, %F or %U takes the file)
			listed := 0
			mimes := document_mimes(o)
			for m in mimes { if mime_listed(mime, m) { listed += 1 } }
			if listed > 0 {
				ps := &s.parts[.Documents]
				ps.present = true
				ps.target = clone_or_empty(target, allocator)
				ps.stale = !same_path(target, o.exe)
				ps.partial = listed < len(mimes) || !exec_takes_file(exec)
			}
		}
	}

	have := 0
	for ic in o.icons { if os.is_file(icon_path(l, o.identity.slug, ic.size)) { have += 1 } }
	if have > 0 {
		s.parts[.Icons].present = true
		s.parts[.Icons].partial = have < len(o.icons)
	} else if len(o.icons) == 0 {
		for size in ICON_SIZES { if os.is_file(icon_path(l, o.identity.slug, size)) { s.parts[.Icons].present = true; break } }
	}

	// PATH: the symlink in ~/.local/bin. present when it is there; its target is the program it runs (stale when another).
	if link := bin_link_path(o); link != "" {
		if target, err := os.read_link(link, context.temp_allocator); err == nil {
			ps := &s.parts[.Path]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
		}
	}

	// Desktop_Shortcut: present when the copy on the desktop is the program's.
	if path := desktop_shortcut_path(o); path != "" {
		if ours, target, _ := entry_ours(o, path); ours {
			ps := &s.parts[.Desktop_Shortcut]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
		}
	}

	// Autostart: present when the entry is the program's; partial when it starts it with other arguments.
	if path := autostart_path(o); path != "" {
		if ours, target, text := entry_ours(o, path); ours {
			ps := &s.parts[.Autostart]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
			ps.partial = o.autostart && text != autostart_entry_text(o) && !ps.stale
		}
	}

	// File_Manager: present when mimeapps.list makes the entry the default of folders. The default counts only for an
	// entry that takes inode/directory: partial without one (when the options have the entry, Install writes it so).
	mimeapps := ""
	if path := mimeapps_path(o); path != "" {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil { mimeapps = string(data) }
	}
	if mimeapps != "" {
		if mimeapps_default(mimeapps, DIRECTORY_MIME) == entry_id(o) {
			ps := &s.parts[.File_Manager]
			ps.present = true
			ours, target, text := entry_ours(o, l.entry)
			if ours {
				ps.target = clone_or_empty(target, allocator)
				ps.stale = !same_path(target, o.exe)
			}
			mime, _ := entry_value(text, "MimeType")
			ps.partial = o.start_menu && !(ours && strings.contains(mime, DIRECTORY_MIME + ";"))
		}
		// Default_Documents: mimeapps.list makes the entry the default of the types (partial: of some of them, or an
		// entry that does not list one: its default does not count)
		{
			mimes := document_mimes(o)
			defaults := 0
			for m in mimes { if mimeapps_default(mimeapps, m) == entry_id(o) { defaults += 1 } }
			if defaults > 0 {
				ps := &s.parts[.Default_Documents]
				ps.present = true
				ours, target, text := entry_ours(o, l.entry)
				if ours {
					ps.target = clone_or_empty(target, allocator)
					ps.stale = !same_path(target, o.exe)
				}
				mime, _ := entry_value(text, "MimeType")
				ps.partial = defaults < len(mimes)
				for m in mimes { if !(ours && mime_listed(mime, m)) { ps.partial = true } }
			}
		}
	}
	s.parts[.Thumbnails] = thumbnailer_status(o, allocator)
	return s
}

// The MimeType value lists `mime` (a whole item: "application/pdf" is not in "application/pdfx;").
@(private = "file")
mime_listed :: proc(value, mime: string) -> bool {
	rest := value
	for item in strings.split_iterator(&rest, ";") { if strings.trim_space(item) == mime { return true } }
	return false
}

// The Exec value passes a file to the program (one of the file codes, an argument of its own).
@(private = "file")
exec_takes_file :: proc(exec_value: string) -> bool {
	for a in exec_arguments(exec_value) {
		if !a.quoted && (a.text == "%f" || a.text == "%F" || a.text == "%u" || a.text == "%U") { return true }
	}
	return false
}

// <config_dir>/mimeapps.list ($XDG_CONFIG_HOME/mimeapps.list): the person's own defaults, which the File_Manager part
// edits ("" when there is no home).
@(private = "file")
mimeapps_path :: proc(o: ^Integration_Options) -> string {
	dir := o.config_dir != "" ? o.config_dir : platform.user_dir(.Config, "", context.temp_allocator)
	if dir == "" { return "" }
	return strings.concatenate({dir, "/mimeapps.list"}, context.temp_allocator)
}

// The desktop file id of the entry (<slug>.desktop): what mimeapps.list names.
@(private = "file")
entry_id :: proc(o: ^Integration_Options) -> string {
	return strings.concatenate({o.identity.slug, ".desktop"}, context.temp_allocator)
}

// Makes the entry the default of each of `mimes` (`on`: folders for the File_Manager part, the document types for
// Default_Documents), or takes it out of their lines (the person's former default comes back). The file is written
// only when it changes, and in one rename: another program reads it at any time.
@(private = "file")
defaults_set :: proc(o: ^Integration_Options, mimes: []string, on: bool) -> Result {
	if len(mimes) == 0 { return {} }
	path := mimeapps_path(o)
	if path == "" {
		if on { return {.System, "neither $XDG_CONFIG_HOME nor the home directory is known"} }
		return {}
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil && os.exists(path) { return {.Io, strings.concatenate({"cannot read ", path}, context.temp_allocator)} }
	text := string(data)
	id := entry_id(o)
	changed := false
	for mime in mimes {
		ids := mimeapps_defaults(text, mime)
		if on {
			if len(ids) > 0 && ids[0] == id { continue }
		} else if !slice.contains(ids, id) {
			continue
		}
		text = mimeapps_with_default(text, mime, id, on)
		changed = true
	}
	if !changed { return {} }
	if on && !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
	if !fsx.write_atomic(path, transmute([]byte)text) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
	return {}
}

// <autostart_dir>/<slug>.desktop ($XDG_CONFIG_HOME/autostart): the entry that starts the program with the session.
@(private = "file")
autostart_path :: proc(o: ^Integration_Options) -> string {
	dir := o.autostart_dir
	if dir == "" {
		config := platform.user_dir(.Config, "", context.temp_allocator)
		if config == "" { return "" }
		dir = strings.concatenate({config, "/autostart"}, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
}

// The desktop entry at `path` (the autostart one, the desktop's copy) when it is the program's (its mark, or an Exec that runs it), and the program it runs.
@(private = "file")
entry_ours :: proc(o: ^Integration_Options, path: string) -> (ours: bool, target, text: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	text = string(data)
	mark, _ := entry_value(text, o.identity.entry_marker)
	exec, _ := entry_value(text, "Exec")
	target = exec_program(exec)
	return mark == o.identity.slug || same_path(target, o.exe), target, text
}

// <desktop folder>/<slug>.desktop: the copy of the entry on the desktop ("" when there is no home, or the person disabled
// their desktop folder).
@(private = "file")
desktop_shortcut_path :: proc(o: ^Integration_Options) -> string {
	dir := o.desktop_dir != "" ? o.desktop_dir : platform.known_folder_path(.Desktop, context.temp_allocator)
	if dir == "" { return "" }
	return strings.concatenate({dir, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
}

// <bin_dir>/<slug> (~/.local/bin/<slug>): the symlink that puts the program on the user's PATH (the "Add to PATH" of Linux).
@(private = "file")
bin_link_path :: proc(o: ^Integration_Options) -> string {
	bin := in_machine(o) ? machine_bin(o) : o.bin_dir != "" ? o.bin_dir : xdg_bin_dir()
	if bin == "" { return "" }
	return strings.concatenate({bin, "/", o.identity.slug}, context.temp_allocator)
}

////////////////////////////////
// Install

@(private = "file")
linux_install :: proc(o: ^Integration_Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	// (a system install's call writes the parts of its half only: touches)
	if touches(o, .Launcher) && !ensure_dir(l.applications) { return {.Io, strings.concatenate({"cannot create ", l.applications}, context.temp_allocator)} }

	for ic in o.icons {
		if !touches(o, .Icons) { break }
		path := icon_path(l, o.identity.slug, ic.size)
		if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
		if !fsx.write_atomic(path, ic.png) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
	}
	// (the Documents part lives in the entry: without the Launcher it stays, hidden from the menu)
	if !touches(o, .Launcher) {
	} else if o.start_menu || opens_documents(o) {
		if !fsx.write_atomic(l.entry, transmute([]byte)desktop_entry_text(o, no_display = !o.start_menu)) { return {.Io, strings.concatenate({"cannot write ", l.entry}, context.temp_allocator)} }
	} else if text, rerr := os.read_entire_file(l.entry, context.temp_allocator); rerr == nil {
		// the option is off: an entry of ours goes (another program's file of that name stays)
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		if mark == o.identity.slug || same_path(exec_program(exec), o.exe) { _ = os.remove(l.entry) }
	}

	// PATH: a symlink in the bin directory to the executable (replaced when it points elsewhere); removed when the option is off.
	if link := bin_link_path(o); link != "" && touches(o, .Path) {
		if o.add_to_path {
			if !ensure_dir(filepath.dir(link)) { return {.Io, strings.concatenate({"cannot create the directory of ", link}, context.temp_allocator)} }
			if target, err := os.read_link(link, context.temp_allocator); err != nil || !same_path(target, o.exe) {
				_ = os.remove(link)   // a stale or foreign link of our own name: replace it (a non-symlink file stays, symlink fails below)
				if serr := os.symlink(o.exe, link); serr != nil {
					return {.Io, strings.concatenate({"cannot create the symlink ", link}, context.temp_allocator)}
				}
			}
		} else if target, err := os.read_link(link, context.temp_allocator); err == nil && same_path(target, o.exe) {
			_ = os.remove(link)   // off: take out only a link that runs this program
		}
	}

	// Autostart: the entry written when the option is on; an entry of ours taken out when it is off.
	if path := autostart_path(o); path != "" && touches(o, .Autostart) {
		if o.autostart {
			if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
			if !fsx.write_atomic(path, transmute([]byte)autostart_entry_text(o)) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
		} else if ours, _, _ := entry_ours(o, path); ours {
			_ = os.remove(path)
		}
	}

	// Desktop_Shortcut: the entry's copy, executable, when the option is on; ours taken out when it is off (another
	// program's file of that name stays).
	if path := desktop_shortcut_path(o); path != "" && touches(o, .Desktop_Shortcut) {
		ours, _, _ := entry_ours(o, path)
		if o.desktop_shortcut {
			if os.exists(path) && !ours { return {.Io, strings.concatenate({path, " is another program's"}, context.temp_allocator)} }
			if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
			if !fsx.write_atomic(path, transmute([]byte)desktop_entry_text(o)) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
			_ = os.chmod(path, os.Permissions_Default_File | {.Execute_User})
		} else if ours {
			_ = os.remove(path)
		}
	}

	// File_Manager: the entry the default of folders with the option; taken out of that line without it
	if touches(o, .File_Manager) {
		if r := defaults_set(o, {DIRECTORY_MIME}, o.default_file_manager); r.error != .None { return r }
	}
	// Default_Documents: the same for each document type
	if touches(o, .Default_Documents) {
		if r := defaults_set(o, document_mimes(o), o.default_documents); r.error != .None { return r }
	}
	// Thumbnails: the .thumbnailer written with the option, ours taken out without it
	if touches(o, .Thumbnails) {
		if r := thumbnailer_apply(o); r.error != .None { return r }
	}

	// (the icon theme's cache is checked against the directories' times: there is nothing to run for the icons)
	if o.notify_system && touches(o, .Launcher) { run_tool("update-desktop-database", {l.applications}) }
	return {}
}

////////////////////////////////
// Remove

@(private = "file")
linux_remove :: proc(o: ^Integration_Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	res: Result
	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil && touches(o, .Launcher) {
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		if mark == o.identity.slug || same_path(exec_program(exec), o.exe) {
			if rerr := os.remove(l.entry); rerr != nil { res = {.Io, strings.concatenate({"cannot delete ", l.entry}, context.temp_allocator)} }
		}
	}
	// the icons are named after the identity's slug: this program's own namespace
	for size in ICON_SIZES {
		if !touches(o, .Icons) { break }
		path := icon_path(l, o.identity.slug, size)
		if os.is_file(path) {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	for ic in o.icons {
		if !touches(o, .Icons) { break }
		path := icon_path(l, o.identity.slug, ic.size)
		if os.is_file(path) { _ = os.remove(path) }
	}
	// PATH: the symlink goes only when it runs this program (a file of the same name that is not ours stays).
	if link := bin_link_path(o); link != "" && touches(o, .Path) {
		if target, err := os.read_link(link, context.temp_allocator); err == nil && same_path(target, o.exe) {
			if rerr := os.remove(link); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", link}, context.temp_allocator)} }
		}
	}
	// Desktop_Shortcut: the copy goes when it is the program's.
	if path := desktop_shortcut_path(o); path != "" && touches(o, .Desktop_Shortcut) {
		if ours, _, _ := entry_ours(o, path); ours {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	// Autostart: the entry goes when it is the program's.
	if path := autostart_path(o); path != "" && touches(o, .Autostart) {
		if ours, _, _ := entry_ours(o, path); ours {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	// File_Manager: the entry's id goes from the folders' line (the rest of the person's file stays).
	if touches(o, .File_Manager) {
		if r := defaults_set(o, {DIRECTORY_MIME}, false); r.error != .None && res.error == .None { res = r }
	}
	// Default_Documents: the entry's id goes from the lines of the document types
	if touches(o, .Default_Documents) {
		if r := defaults_set(o, document_mimes(o), false); r.error != .None && res.error == .None { res = r }
	}
	if touches(o, .Thumbnails) {
		if r := thumbnailer_remove(o); r.error != .None && res.error == .None { res = r }
	}
	if o.notify_system && touches(o, .Launcher) { run_tool("update-desktop-database", {l.applications}) }
	return res
}

// Takes one folder's symlink out of the bin directory (install.odin calls this when a copy is uninstalled). `dir` is the
// folder whose executable the link points into; the link is removed when it resolves to a program in that folder.
@(private = "file")
linux_path_remove :: proc(o: ^Integration_Options, dir: string) -> Result {
	link := bin_link_path(o)
	if link == "" { return {} }
	target, err := os.read_link(link, context.temp_allocator)
	if err != nil { return {} }
	if same_path(filepath.dir(target), dir) || same_path(target, o.exe) {
		if rerr := os.remove(link); rerr != nil { return {.Io, strings.concatenate({"cannot delete ", link}, context.temp_allocator)} }
	}
	return {}
}

////////////////////////////////
// Tools of the desktop

// Runs `tool` with `args` when it is on the PATH, silently, and waits for it. False when it is not there or failed.
@(private = "file")
run_tool :: proc(tool: string, args: []string) -> bool {
	path, found := find_on_path(tool)
	if !found { return false }
	command := make([dynamic]string, context.temp_allocator)
	append(&command, path)
	for a in args { append(&command, a) }
	p, err := process.start(os.Process_Desc{command = command[:]})
	if err != nil { return false }
	state, werr := os.process_wait(p)
	return werr == nil && state.success
}

@(private)
find_on_path :: proc(tool: string) -> (path: string, found: bool) {
	paths, ok := os.lookup_env("PATH", context.temp_allocator)
	if !ok { return }
	for dir in strings.split(paths, ":", context.temp_allocator) {
		if dir == "" { continue }
		candidate := strings.concatenate({dir, "/", tool}, context.temp_allocator)
		if os.is_file(candidate) { return candidate, true }
	}
	return
}
