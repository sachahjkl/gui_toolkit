// Package setup: a program installs itself for the user, from the copy that was downloaded, in a dialog of its own (and
// repairs, upgrades or removes that install). It is the layer over the desktop package (docs/desktop.md): what the state
// of the install is (facts), what Install and Uninstall do, and the dialog that shows both (dialog.odin).
//
// The installed copy:
//   Windows  %LOCALAPPDATA%\Programs\<folder>\<exe>, the Start menu's shortcut, the Settings > Apps record (its uninstall
//            runs `<exe> <identity.uninstall_arguments>`), and what Setup_Options.prepare adds (the start with the session, the
//            PATH and its console launcher)
//   Linux    ~/.local/share/<folder>/<exe>, the applications menu's entry, the icons, and what Setup_Options.prepare adds
// and in the install folder the manifest: the version and the files placed, which Uninstall removes.
package tk_setup

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import desktop "../desktop"
import i18n "../i18n"
import process "../process"
import "../ui"
import base "../base"

// What a program gives the setup.
Setup_Options :: struct {
	identity:       desktop.Identity,
	version:        string,          // this copy's ("0.6.1")
	install_folder: string,          // the install folder's name beside the default ("": the desktop package's default)
	icons:          []desktop.Icon,  // Linux: the icons of the menu entry (Windows uses the executable's own)
	note:           string,          // a line under the version in the dialog ("": none)
	// The program's own options of an install, shown as boxes in the dialog (the PATH, a browser's registration...): their
	// first values. What the user ticks is given to `prepare`, in this order.
	choices:        []Choice,
	// The program's own parts of the options, set before anything is read or written, the install folder known: the start
	// with the session, the PATH and its console launcher, the places of a test (desktop.roots_from_env)... `choices`: the
	// boxes' values.
	prepare:        proc(o: ^desktop.Integration_Options, choices: []bool, user: rawptr),
	// whether a copy of the program runs and answers (its single instance: instance.acquire's owner), for --status; nil:
	// never said to run. Called from a process with no window, before any: it may wait a moment for the answer
	running:        proc() -> bool,
	folder:         bool,            // the dialog lets the user choose the install folder before the first install
	square:         bool,            // every corner of the dialog square (its panel, frames, fields, the toolkit's buttons)
	user:           rawptr,
	// The program's own look of the dialog (nil: the toolkit's): what is drawn behind it first (a blur of the window...),
	// its buttons, and the close control in its corner (its box built with ui.modal_corner: the toolkit places it).
	backdrop:       proc(user: rawptr),
	// A button: its words, a Lucide glyph and its intent (what it does: Danger uninstalls, Success installs or opens).
	button:         proc(id, label, glyph: string, intent: ui.Intent, em: f32, user: rawptr) -> bool,
	close:          proc(id: string, em: f32, user: rawptr) -> bool,
}

// An option of the program's install (Setup_Options.choices).
Choice :: struct {
	label: string,   // English, shown in the language in use (i18n.later)
	on:    bool,
}

State :: enum u8 {
	Not_Installed,
	This_Copy,           // the running program is the installed copy, everything in place
	Repair,              // a launcher, the system's record, the manifest or a file is missing
	Other_Copy,          // a copy is installed elsewhere: this one runs on its own (Install replaces that one)
	Removal_Scheduled,   // uninstalled while it ran: its file goes when this process ends (the dialog says it, the disk does not)
	Nix_Package,         // this copy runs from the Nix store, and no copy is installed: the Nix configuration installs it
}

Facts :: struct {
	state:      State,
	dir:        string,   // where the installed copy is (or would go)
	exe:        string,
	exe_there:  bool,     // ... and it is there
	running:    string,   // this program
	running_it: bool,     // this program is the installed copy
	start_lnk:  bool,     // the applications menu's launcher, running the installed copy
	desk_lnk:   bool,     // the Desktop's shortcut
	record:     bool,     // the system's record (Settings > Apps; the icons on Linux)
	autostart:  bool,     // the program starts with the user's session (Setup_Options.prepare asked it)
	on_path:    bool,     // the program is on the user's PATH (Windows: its folder and the console launcher <name>.com)
	manifest:   bool,     // the install folder has the manifest
	missing:    int,      // files the manifest names that are not there
	version:    string,   // of the installed copy, from its manifest
	nixos:      bool,     // the system is NixOS: a Nix package is the better install
	from_nix:   bool,     // this copy runs from the Nix store: never offered an install
}

// What the facts make of an install. No program but something of it left: to repair, or to remove. A copy of the Nix store
// is the Nix package's whatever an earlier install left: a repair would install it beside the package (leftover says).
state_of :: proc(f: Facts) -> State {
	switch {
	case !f.exe_there && f.from_nix: return .Nix_Package
	case !f.exe_there:  return leftover(f) ? .Repair : .Not_Installed
	case !f.manifest:   return .Repair
	case !f.running_it: return .Other_Copy
	case f.start_lnk && f.record && f.missing == 0: return .This_Copy
	}
	return .Repair
}

// No program installed, but something of an install is left: a launcher, a shortcut, the record, the manifest.
leftover :: proc(f: Facts) -> bool { return !f.exe_there && (f.start_lnk || f.desk_lnk || f.record || f.manifest) }

// The options of the program's integration, its install folder set: the one the system recorded (Windows), else
// Setup_Options.install_folder beside the default. `recorded`: the system has a record of it.
options :: proc(o: Setup_Options, choices: []bool = nil) -> (integration: desktop.Integration_Options, recorded: bool) {
	integration = desktop.options_make(o.identity)
	integration.icons = o.icons
	default := desktop.default_install_dir(&integration)
	// (the record alone: an install in the default folder is recorded too; install_target would give the default
	// for no record, and telling the two apart by the folder made such an install one "to repair")
	if found := desktop.install_recorded(&integration); found != "" {
		integration.install_dir, recorded = found, true
	} else if default != "" && o.install_folder != "" {
		integration.install_dir = join({process.parent_dir(default), o.install_folder})
	} else {
		integration.install_dir = default
	}
	// (last: the program sees the folder, and may put every place elsewhere: a test's)
	if o.prepare != nil { o.prepare(&integration, choices_or_first(o, choices), o.user) }
	return
}

// The state of the install, as the disk and the system say it (strings in temp memory).
facts :: proc(o: Setup_Options, choices: []bool = nil, loc := #caller_location) -> (f: Facts) {
	base.blocking("setup.facts", loc)
	integration, recorded := options(o, choices)
	f.running = process.executable_path()
	f.dir = integration.install_dir
	info := desktop.installed_info(&integration, f.dir, context.temp_allocator)
	f.exe = info.exe != "" ? info.exe : join({f.dir, desktop.exe_name_of(integration.identity)})
	f.exe_there = info.exe_present
	f.manifest = info.manifest
	f.missing = info.missing
	f.version = info.version
	f.running_it = desktop.same_path(f.exe, f.running)
	integration.exe = f.exe   // (the integration is measured against the installed copy)
	s := desktop.status(&integration, context.temp_allocator)
	launcher := s.parts[.Launcher]
	f.start_lnk = launcher.present && !launcher.stale && !launcher.partial
	shortcut := s.parts[.Desktop_Shortcut]
	f.desk_lnk = shortcut.present && !shortcut.stale
	f.autostart = s.parts[.Autostart].present && !s.parts[.Autostart].stale
	f.on_path = s.parts[.Path].present && !s.parts[.Path].stale
	when ODIN_OS == .Windows {
		f.record = recorded
	} else {
		icons := s.parts[.Icons]
		// (a program with no icons has nothing of a record to install: complete when it is there, no leftover when not)
		f.record = recorded || icons.present || (len(o.icons) == 0 && f.exe_there)
	}
	f.nixos = desktop.is_nixos()
	f.from_nix = desktop.in_nix_store(f.running)
	f.state = state_of(f)
	return
}

// Copies this program into the install folder (unless it runs from there), writes its launchers, the program's own parts
// and the system's record. The installed program (temp memory), or why not.
// `choices`: the program's options (nil: their first values); `folder`: another install folder than the default ("").
install :: proc(o: Setup_Options, desktop_shortcut: bool, choices: []bool = nil, folder := "") -> (ok: bool, exe_or_why: string) {
	integration, _ := options(o, choices)
	if folder != "" {
		if why := desktop.check_install_dir(folder, o.identity.name, probe = true); why != "" { return false, why }
		integration.install_dir = folder
	}
	if integration.install_dir == "" { return false, i18n.tr("the install folder is unknown") }
	exe_name := desktop.exe_name_of(integration.identity)
	plan := desktop.Install_Plan{
		identity = integration.identity, src_exe = process.executable_path(), dir = integration.install_dir, exe_name = exe_name,
		version = o.version, channel = "release", adapt = true,
	}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	integration.exe = join({integration.install_dir, exe_name})
	integration.desktop_shortcut = desktop_shortcut
	if r := desktop.install(&integration); r.error != .None { return false, failure(r) }
	if r := desktop.record_install(&integration, integration.install_dir, o.version); r.error != .None { return false, failure(r) }
	return true, integration.exe
}

// After an update put a new program in place of the installed copy (update.Updater): its install manifest and the
// system's record (Settings > Apps) say `version`. Nothing to do for `exe` when it is not the installed copy. why: "" when
// done (temp memory).
updated :: proc(o: Setup_Options, version: string, exe := "") -> (ok: bool, why: string) {
	running := exe != "" ? exe : process.executable_path()
	integration, _ := options(o)
	info := desktop.installed_info(&integration, integration.install_dir, context.temp_allocator)
	if !info.manifest || info.exe == "" || !desktop.same_path(info.exe, running) { return true, "" }
	exe_name := desktop.exe_name_of(integration.identity)
	plan := desktop.Install_Plan{
		identity = integration.identity, src_exe = running, dir = integration.install_dir, exe_name = exe_name,
		version = version, channel = "release", adapt = true,
	}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	integration.exe = running
	if r := desktop.record_install(&integration, integration.install_dir, version); r.error != .None { return false, failure(r) }
	return true, ""
}

// Removes the launchers and parts (ours only), the system's record and the installed files. The files of the copy that
// runs (Windows: they cannot be deleted while it runs) are in `leftovers` (heap, the caller's): remove_later deletes them
// once this process has ended.
uninstall :: proc(o: Setup_Options, choices: []bool = nil) -> (ok: bool, leftovers: [dynamic]string, why: string) {
	integration, _ := options(o, choices)   // (the program's parts are taken away too)
	integration.exe = join({integration.install_dir, desktop.exe_name_of(integration.identity)})
	ur := desktop.uninstall(&integration, process.executable_path(), context.temp_allocator)
	if len(ur.leftovers) > 0 {
		leftovers = make([dynamic]string)
		for l in ur.leftovers { append(&leftovers, strings.clone(l)) }
		append(&leftovers, strings.clone(join({ur.folder, integration.identity.manifest_name})))   // (it stays while they are there)
	}
	if ur.result.error != .None { return false, leftovers, failure(ur.result) }
	return true, leftovers, ""
}

// Deletes `files`, then the install folder when it is empty, once this process has ended (a helper of the system's;
// false when there is none).
remove_later :: proc(o: Setup_Options, files: []string) -> bool {
	integration, _ := options(o)
	return desktop.cleanup_later(&integration, files, integration.install_dir, desktop.current_process_id())
}

// Starts the installed copy (after an install from a downloaded copy, after an update, on Restart). The new process may
// take the foreground: its first window comes in front of the others with the keyboard, as the one it replaces was.
launch :: proc(exe: string, args: []string = nil) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, ..args)
	p, err := os.process_start({command = cmd[:], working_dir = filepath.dir(exe)})
	if err != nil { return false }
	// (Windows: this process had the user's last input, the click on Restart, but its window is gone: without this grant
	// the new window would open behind the others, its taskbar button flashing)
	foreground_allow(p.pid)
	return true
}

// "0.5.6" before "0.6.0", number by number (a version that does not read as one is not older: nothing to offer).
version_older :: proc(a, b: string) -> bool {
	if a == "" || b == "" { return false }
	aa, bb := a, b
	for {
		x, x_ok := strings.split_iterator(&aa, ".")
		y, y_ok := strings.split_iterator(&bb, ".")
		if !x_ok && !y_ok { return false }
		xn, xp := strconv.parse_int(x_ok ? x : "0")
		yn, yp := strconv.parse_int(y_ok ? y : "0")
		if !xp || !yp { return false }
		if xn != yn { return xn < yn }
	}
}

// An older copy is installed and this one can replace it.
is_upgrade :: proc(f: Facts, version: string) -> bool {
	return f.state == .Other_Copy && version_older(f.version, version)
}

// A newer copy is installed: replacing it with this one goes back.
is_downgrade :: proc(f: Facts, version: string) -> bool {
	return f.state == .Other_Copy && version_older(version, f.version)
}

// The values of the program's options: those given, else their first ones (temp memory).
@(private)
choices_or_first :: proc(o: Setup_Options, choices: []bool) -> []bool {
	if len(choices) == len(o.choices) { return choices }
	out := make([]bool, len(o.choices), context.temp_allocator)
	for x, i in o.choices { out[i] = x.on }
	return out
}

// What the user answered the dialog, kept by the program between starts (Choice_Text; "" at first).
//   "installed"            installed
//   "standalone"           this copy runs on its own: not asked again
//   "dismissed:<version>"  closed without an answer: not asked again for that version
CHOICE_INSTALLED  :: "installed"
CHOICE_STANDALONE :: "standalone"

choice_dismissed :: proc(version: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("dismissed:%s", version, allocator = allocator)
}

// Whether a start opens the dialog: an older install to upgrade (unless closed for this version); no install, or one to
// repair, unless the user said "standalone" (or closed it for this version). Never a copy of the Nix store.
wanted :: proc(f: Facts, version, choice: string) -> bool {
	if f.from_nix || f.state == .Nix_Package { return false }
	if choice == choice_dismissed(version) { return false }
	if is_upgrade(f, version) { return true }
	return choice != CHOICE_STANDALONE && (f.state == .Not_Installed || f.state == .Repair)
}

@(private)
failure :: proc(r: desktop.Result) -> string {
	return r.detail != "" ? r.detail : desktop.error_text(r.error)
}

@(private)
join :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}
