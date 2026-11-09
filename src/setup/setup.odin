// Package setup: a program installs itself for the user, from the copy that was downloaded, in a dialog of its own (and
// repairs, upgrades or removes that install). It is the layer over the desktop package (docs/desktop.md): what the state
// of the install is (facts), what Install and Uninstall do, and the dialog that shows both (dialog.odin).
//
// The installed copy:
//   Windows  %LOCALAPPDATA%\Programs\<folder>\<exe>, the Start menu's shortcut, the Settings > Apps record (its uninstall
//            runs `<exe> <identity.uninstall_arguments>`), and what Config.prepare adds (the start with the session, the
//            PATH and its console launcher)
//   Linux    ~/.local/share/<folder>/<exe>, the applications menu's entry, the icons, and what Config.prepare adds
// and in the install folder the manifest: the version and the files placed, which Uninstall removes.
package tk_setup

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import desktop "../desktop"
import process "../process"

// What a program gives the setup.
Config :: struct {
	identity:       desktop.Identity,
	version:        string,          // this copy's ("0.6.1")
	install_folder: string,          // the install folder's name beside the default ("": the desktop package's default)
	icons:          []desktop.Icon,  // Linux: the icons of the menu entry (Windows uses the executable's own)
	note:           string,          // a line under the version in the dialog ("": none)
	// the program's own parts of an install, set on the options before they are written: the start with the session, the
	// PATH and its console launcher...
	prepare:        proc(o: ^desktop.Options, user: rawptr),
	user:           rawptr,
}

State :: enum u8 {
	Not_Installed,
	This_Copy,           // the running program is the installed copy, everything in place
	Repair,              // a launcher, the system's record, the manifest or a file is missing
	Other_Copy,          // a copy is installed elsewhere: this one runs on its own (Install replaces that one)
	Removal_Scheduled,   // uninstalled while it ran: its file goes when this process ends (the dialog says it, the disk does not)
	Nix_Package,         // this copy runs from the Nix store: the Nix configuration installs it
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
	manifest:   bool,     // the install folder has the manifest
	missing:    int,      // files the manifest names that are not there
	version:    string,   // of the installed copy, from its manifest
	nixos:      bool,     // the system is NixOS: a Nix package is the better install
	from_nix:   bool,     // this copy runs from the Nix store: never offered an install
}

// What the facts make of an install. No program but something of it left: to repair, or to remove.
state_of :: proc(f: Facts) -> State {
	switch {
	case !f.exe_there:  return f.start_lnk || f.desk_lnk || f.record || f.manifest ? .Repair : .Not_Installed
	case !f.manifest:   return .Repair
	case !f.running_it: return .Other_Copy
	case f.start_lnk && f.record && f.missing == 0: return .This_Copy
	}
	return .Repair
}

// The options of the program's integration, its install folder set: the one the system recorded (Windows), else
// Config.install_folder beside the default. `recorded`: the system has a record of it.
options :: proc(c: Config) -> (o: desktop.Options, recorded: bool) {
	o = desktop.options_make(c.identity)
	o.icons = c.icons
	default := desktop.default_install_dir(&o)
	if found := desktop.install_target(&o); found != "" && !desktop.same_path(found, default) { o.install_dir = found; return o, true }
	if default != "" && c.install_folder != "" { o.install_dir = join({process.parent_dir(default), c.install_folder}) } else { o.install_dir = default }
	return o, false
}

// The state of the install, as the disk and the system say it (strings in temp memory).
facts :: proc(c: Config) -> (f: Facts) {
	o, recorded := options(c)
	f.running = process.executable_path()
	f.dir = o.install_dir
	info := desktop.installed_info(&o, f.dir, context.temp_allocator)
	f.exe = info.exe != "" ? info.exe : join({f.dir, desktop.exe_name_of(o.identity)})
	f.exe_there = info.exe_present
	f.manifest = info.manifest
	f.missing = info.missing
	f.version = info.version
	f.running_it = desktop.same_path(f.exe, f.running)
	o.exe = f.exe   // (the integration is measured against the installed copy)
	s := desktop.status(&o, context.temp_allocator)
	launcher := s.parts[.Launcher]
	f.start_lnk = launcher.present && !launcher.stale && !launcher.partial
	shortcut := s.parts[.Desktop_Shortcut]
	f.desk_lnk = shortcut.present && !shortcut.stale
	when ODIN_OS == .Windows {
		f.record = recorded
	} else {
		icons := s.parts[.Icons]
		f.record = recorded || icons.present || len(c.icons) == 0
	}
	f.state = state_of(f)
	f.nixos = desktop.is_nixos()
	f.from_nix = desktop.in_nix_store(f.running)
	if f.from_nix && f.state == .Not_Installed { f.state = .Nix_Package }
	return
}

// Copies this program into the install folder (unless it runs from there), writes its launchers, the program's own parts
// and the system's record. The installed program (temp memory), or why not.
install :: proc(c: Config, desktop_shortcut: bool) -> (ok: bool, exe_or_why: string) {
	o, _ := options(c)
	if o.install_dir == "" { return false, "the install folder is unknown" }
	exe_name := desktop.exe_name_of(o.identity)
	plan := desktop.Install_Plan{
		identity = o.identity, src_exe = process.executable_path(), dir = o.install_dir, exe_name = exe_name,
		version = c.version, channel = "release", adapt = true,
	}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	o.exe = join({o.install_dir, exe_name})
	o.desktop_shortcut = desktop_shortcut
	if c.prepare != nil { c.prepare(&o, c.user) }
	if r := desktop.install(&o); r.error != .None { return false, failure(r) }
	if r := desktop.record_install(&o, o.install_dir, c.version); r.error != .None { return false, failure(r) }
	return true, o.exe
}

// Removes the launchers and parts (ours only), the system's record and the installed files. The files of the copy that
// runs (Windows: they cannot be deleted while it runs) are in `leftovers` (heap, the caller's): remove_later deletes them
// once this process has ended.
uninstall :: proc(c: Config) -> (ok: bool, leftovers: [dynamic]string, why: string) {
	o, _ := options(c)
	o.exe = join({o.install_dir, desktop.exe_name_of(o.identity)})
	if c.prepare != nil { c.prepare(&o, c.user) }   // (its parts are taken away too)
	ur := desktop.uninstall(&o, process.executable_path(), context.temp_allocator)
	if len(ur.leftovers) > 0 {
		leftovers = make([dynamic]string)
		for l in ur.leftovers { append(&leftovers, strings.clone(l)) }
		append(&leftovers, strings.clone(join({ur.folder, o.identity.manifest_name})))   // (it stays while they are there)
	}
	if ur.result.error != .None { return false, leftovers, failure(ur.result) }
	return true, leftovers, ""
}

// Deletes `files`, then the install folder when it is empty, once this process has ended (a helper of the system's;
// false when there is none).
remove_later :: proc(c: Config, files: []string) -> bool {
	o, _ := options(c)
	return desktop.cleanup_later(&o, files, o.install_dir, desktop.current_process_id())
}

// Starts the installed copy (after an install from a downloaded copy).
launch :: proc(exe: string, args: []string = nil) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, ..args)
	_, err := os.process_start({command = cmd[:], working_dir = filepath.dir(exe)})
	return err == nil
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
