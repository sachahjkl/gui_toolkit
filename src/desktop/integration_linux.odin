package tk_desktop

// Linux: the freedesktop.org way (XDG), all under the user's data directory.
//
//   $XDG_DATA_HOME/applications/<slug>.desktop       the desktop entry (desktop_entry.odin): name, Exec, Icon, the
//                                                    identity's categories and, for a browser, MimeType= for http,
//                                                    https, its URL schemes and the configured file types, so that
//                                                    "open with" and the default browser setting list the program
//   $XDG_DATA_HOME/icons/hicolor/<n>x<n>/apps/<slug>.png   the icons, one per size the program embeds
//   ~/.local/bin/<slug>                              the PATH part: a link to the executable
//   $XDG_CONFIG_HOME/autostart/<slug>.desktop        the Autostart part: the program at the start of the session
//   <desktop folder>/<slug>.desktop                  the Desktop_Shortcut part: a copy of the entry, executable (a desktop
//                                                    starts only an executable entry); the folder is xdg_desktop_dir's
//
// $XDG_DATA_HOME defaults to ~/.local/share (and must be an absolute path, as the specification says). After a change
// `update-desktop-database <applications>` rebuilds the MIME cache when that tool is installed.
//
// The mark of the program in a desktop entry is its `Identity.entry_marker` line (or an Exec that runs the executable).

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../fsx"

@(private = "file")
LINUX_BACKEND := Backend{
	name = "linux",
	targets = "application menu, PATH, session start",
	targets_browser = "application menu, default browser, PATH, session start",
	parts = {.Launcher, .Desktop_Shortcut, .Icons, .Path, .Autostart},
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
@(private = "file")
linux_default_install_dir :: proc(o: ^Options, allocator: runtime.Allocator) -> string {
	data_home := xdg_data_home()
	if data_home == "" { return "" }
	return strings.concatenate({data_home, "/", o.identity.slug}, allocator)
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
layout_of :: proc(o: ^Options) -> (l: Layout, ok: bool) {
	data_home := ""
	if o.applications_dir == "" || o.icons_dir == "" {
		data_home = xdg_data_home()
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
linux_status :: proc(o: ^Options, allocator: runtime.Allocator) -> Status {
	s: Status
	l, ok := layout_of(o)
	if !ok { s.error = .System; return s }

	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil {
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		target := exec_program(exec)
		if mark == o.identity.slug || same_path(target, o.exe) {
			ps := &s.parts[.Launcher]
			ps.present = true
			ps.target = clone_or_empty(target, allocator)
			ps.stale = !same_path(target, o.exe)
			if o.register_browser {
				mime, _ := entry_value(content, "MimeType")
				ps.partial = !strings.contains(mime, "x-scheme-handler/https")
				for name in o.identity.url_schemes {   // (an entry of a version without the schemes: Repair adds them)
					if !strings.contains(mime, strings.concatenate({SCHEME_MIME_PREFIX, name, ";"}, context.temp_allocator)) { ps.partial = true }
				}
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
	return s
}

// <autostart_dir>/<slug>.desktop ($XDG_CONFIG_HOME/autostart): the entry that starts the program with the session.
@(private = "file")
autostart_path :: proc(o: ^Options) -> string {
	dir := o.autostart_dir
	if dir == "" {
		config := xdg_config_home()
		if config == "" { return "" }
		dir = strings.concatenate({config, "/autostart"}, context.temp_allocator)
	}
	return strings.concatenate({dir, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
}

// The desktop entry at `path` (the autostart one, the desktop's copy) when it is the program's (its mark, or an Exec that runs it), and the program it runs.
@(private = "file")
entry_ours :: proc(o: ^Options, path: string) -> (ours: bool, target, text: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	text = string(data)
	mark, _ := entry_value(text, o.identity.entry_marker)
	exec, _ := entry_value(text, "Exec")
	target = exec_program(exec)
	return mark == o.identity.slug || same_path(target, o.exe), target, text
}

// <desktop folder>/<slug>.desktop: the copy of the entry on the desktop ("" when there is no home).
@(private = "file")
desktop_shortcut_path :: proc(o: ^Options) -> string {
	dir := o.desktop_dir != "" ? o.desktop_dir : xdg_desktop_dir()
	if dir == "" { return "" }
	return strings.concatenate({dir, "/", o.identity.slug, ".desktop"}, context.temp_allocator)
}

// <bin_dir>/<slug> (~/.local/bin/<slug>): the symlink that puts the program on the user's PATH (the "Add to PATH" of Linux).
@(private = "file")
bin_link_path :: proc(o: ^Options) -> string {
	bin := o.bin_dir != "" ? o.bin_dir : xdg_bin_dir()
	if bin == "" { return "" }
	return strings.concatenate({bin, "/", o.identity.slug}, context.temp_allocator)
}

////////////////////////////////
// Install

@(private = "file")
linux_install :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	if !ensure_dir(l.applications) { return {.Io, strings.concatenate({"cannot create ", l.applications}, context.temp_allocator)} }

	for ic in o.icons {
		path := icon_path(l, o.identity.slug, ic.size)
		if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
		if !fsx.write_atomic(path, ic.png) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
	}
	if o.start_menu {
		if !fsx.write_atomic(l.entry, transmute([]byte)desktop_entry_text(o)) { return {.Io, strings.concatenate({"cannot write ", l.entry}, context.temp_allocator)} }
	} else if text, rerr := os.read_entire_file(l.entry, context.temp_allocator); rerr == nil {
		// the option is off: an entry of ours goes (another program's file of that name stays)
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		if mark == o.identity.slug || same_path(exec_program(exec), o.exe) { _ = os.remove(l.entry) }
	}

	// PATH: a symlink in the bin directory to the executable (replaced when it points elsewhere); removed when the option is off.
	if link := bin_link_path(o); link != "" {
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
	if path := autostart_path(o); path != "" {
		if o.autostart {
			if !ensure_dir(filepath.dir(path)) { return {.Io, strings.concatenate({"cannot create the directory of ", path}, context.temp_allocator)} }
			if !fsx.write_atomic(path, transmute([]byte)autostart_entry_text(o)) { return {.Io, strings.concatenate({"cannot write ", path}, context.temp_allocator)} }
		} else if ours, _, _ := entry_ours(o, path); ours {
			_ = os.remove(path)
		}
	}

	// Desktop_Shortcut: the entry's copy, executable, when the option is on; ours taken out when it is off (another
	// program's file of that name stays).
	if path := desktop_shortcut_path(o); path != "" {
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

	// (the icon theme's cache is checked against the directories' times: there is nothing to run for the icons)
	if o.notify_system { run_tool("update-desktop-database", {l.applications}) }
	return {}
}

////////////////////////////////
// Remove

@(private = "file")
linux_remove :: proc(o: ^Options) -> Result {
	l, ok := layout_of(o)
	if !ok { return {.System, "neither $XDG_DATA_HOME nor the home directory is known"} }
	res: Result
	if text, err := os.read_entire_file(l.entry, context.temp_allocator); err == nil {
		content := string(text)
		mark, _ := entry_value(content, o.identity.entry_marker)
		exec, _ := entry_value(content, "Exec")
		if mark == o.identity.slug || same_path(exec_program(exec), o.exe) {
			if rerr := os.remove(l.entry); rerr != nil { res = {.Io, strings.concatenate({"cannot delete ", l.entry}, context.temp_allocator)} }
		}
	}
	// the icons are named after the identity's slug: this program's own namespace
	for size in ICON_SIZES {
		path := icon_path(l, o.identity.slug, size)
		if os.is_file(path) {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	for ic in o.icons {
		path := icon_path(l, o.identity.slug, ic.size)
		if os.is_file(path) { _ = os.remove(path) }
	}
	// PATH: the symlink goes only when it runs this program (a file of the same name that is not ours stays).
	if link := bin_link_path(o); link != "" {
		if target, err := os.read_link(link, context.temp_allocator); err == nil && same_path(target, o.exe) {
			if rerr := os.remove(link); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", link}, context.temp_allocator)} }
		}
	}
	// Desktop_Shortcut: the copy goes when it is the program's.
	if path := desktop_shortcut_path(o); path != "" {
		if ours, _, _ := entry_ours(o, path); ours {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	// Autostart: the entry goes when it is the program's.
	if path := autostart_path(o); path != "" {
		if ours, _, _ := entry_ours(o, path); ours {
			if rerr := os.remove(path); rerr != nil && res.error == .None { res = {.Io, strings.concatenate({"cannot delete ", path}, context.temp_allocator)} }
		}
	}
	if o.notify_system { run_tool("update-desktop-database", {l.applications}) }
	return res
}

// Takes one folder's symlink out of the bin directory (install.odin calls this when a copy is uninstalled). `dir` is the
// folder whose executable the link points into; the link is removed when it resolves to a program in that folder.
@(private = "file")
linux_path_remove :: proc(o: ^Options, dir: string) -> Result {
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
	p, err := os.process_start(os.Process_Desc{command = command[:]})
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
