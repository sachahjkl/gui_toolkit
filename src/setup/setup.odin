// Package setup: a program installs itself for the user, from the copy that was downloaded, in a dialog of its own (and
// repairs, upgrades or removes that install). It is the layer over the desktop package (docs/desktop.md): what the state
// of the install is (facts), what Install and Uninstall do, and the dialog that shows both (dialog.odin).
//
// The installed copy, for the person (scope User):
//   Windows  %LOCALAPPDATA%\Programs\<folder>\<exe>, the Start menu's shortcut, the Settings > Apps record (its uninstall
//            runs `<exe> <identity.uninstall_arguments>`), and what Setup_Options.prepare adds (the start with the session, the
//            PATH and its console launcher)
//   Linux    ~/.local/opt/<folder>/<exe>, the applications menu's entry, the icons, and what Setup_Options.prepare adds
// or for everyone (scope System: %ProgramFiles%\<vendor>\<name>, /opt/<vendor_key>/<name>), whose machine half an
// administrator allows through the elevated verb (src/md/features/install-scope.md); and in the install folder the
// manifest: the version and the files placed, which Uninstall removes.
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
	vendor_url:     string,          // the vendor's site: its name in the "By" line opens it ("": the name alone)
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
	// asks the copy that runs to end, as its own Quit does (its single instance: instance.MESSAGE_QUIT), for --quit; true
	// when it took the request. nil: the program cannot be asked, and --status says `quit: no`. Called as `running` is
	quit:           proc() -> bool,
	folder:         bool,            // the dialog lets the user choose the install folder before the first install (for the person only)
	// the scopes the program offers: for the person, for every account ({}: every scope this system has). A program that
	// must stay the person's gives {.User}
	scopes:         desktop.Scopes,
	square:         bool,            // every corner of the dialog square (its panel, frames, fields, the toolkit's buttons)
	// the program's folder in its vendor's, platform.user_dir's name ("FromentSoftware/Tower"): where the folders of an
	// earlier identity move (adopt_earlier)
	program_folder: string,
	// the program's earlier identities: their installs and folders are taken over once at the start (adopt_earlier,
	// src/md/features/identity-change.md)
	earlier:        []Earlier,
	user:           rawptr,
	// The program's own look of the dialog (nil: the toolkit's): what is drawn behind it first (a blur of the window...),
	// and its buttons. The header and its close cross are the toolkit's (the views' header). `v` says where it is: a
	// scrim belongs only to `v.presentation == .Dialog` (floating, docked or in a window of its own, it has none).
	backdrop:       proc(v: ^ui.View, user: rawptr),
	// A button: its words, a Lucide glyph and its intent (what it does: Danger uninstalls, Success installs or opens).
	button:         proc(id, label, glyph: string, intent: ui.Intent, em: f32, user: rawptr) -> bool,
}

// An option of the program's install (Setup_Options.choices).
Choice :: struct {
	label: string,          // English, shown in the language in use (i18n.later)
	on:    bool,            // its value before an install
	// the parts of the integration the box stands for ({}: none). With an install there, the box starts from the
	// system's truth: on when they are all there and run the installed copy (Facts.parts), whatever `on` says
	parts: desktop.Parts,
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
	parts:      desktop.Parts,   // the parts of the integration that are there and run the installed copy
	manifest:   bool,     // the install folder has the manifest
	missing:    int,      // files the manifest names that are not there
	version:    string,   // of the installed copy, from its manifest
	nixos:      bool,     // the system is NixOS: a Nix package is the better install
	from_nix:   bool,     // this copy runs from the Nix store: never offered an install
	scope:      desktop.Scope,            // the scope of the install that is there (none: the one asked)
	other_scope: bool,                    // an install of the other scope is there too (a move that was not finished)
	system_refusal: desktop.System_Refusal,   // why "For everyone" is not offered here (None: it is)
	// Removal_Scheduled: the program's file goes at the next restart (Windows, an install for everyone: the elevated verb
	// ran from it), not when this process ends. The dialog says it, the disk does not
	at_restart: bool,
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

// The options of the program's integration in `scope` (nil: the scope of the install that is there, else the
// person's), its install folder set: the one the system recorded (Windows), else Setup_Options.install_folder beside
// the default; for everyone, always the system's place. `recorded`: the system has a record of it.
options :: proc(o: Setup_Options, choices: []bool = nil, scope: Maybe(desktop.Scope) = nil) -> (integration: desktop.Integration_Options, recorded: bool) {
	integration = desktop.options_make(o.identity)
	integration.icons = o.icons
	integration.scope = scope.? or_else installed_scope(o)
	default := desktop.default_install_dir(&integration)
	// (the record alone: an install in the default folder is recorded too; install_target would give the default
	// for no record, and telling the two apart by the folder made such an install one "to repair")
	if found := desktop.install_recorded(&integration); found != "" {
		integration.install_dir, recorded = found, true
	} else if default != "" && o.install_folder != "" && integration.scope == .User {
		integration.install_dir = join({process.parent_dir(default), o.install_folder})
	} else {
		integration.install_dir = default
	}
	// (last: the program sees the folder, and may put every place elsewhere: a test's)
	if o.prepare != nil { o.prepare(&integration, choices_or_first(o, choices), o.user) }
	// (an install for everyone is in the system's place, or a test's machine root: never a folder a person chose)
	if integration.scope == .System { integration.install_dir = desktop.system_install_dir(&integration) }
	return
}

// The scopes the program offers on this system.
offered_scopes :: proc(o: Setup_Options) -> desktop.Scopes {
	s := o.scopes != {} ? o.scopes : desktop.supported_scopes()
	return s & desktop.supported_scopes()
}

// An install of the program is there in `scope`: its record, its manifest or its program.
install_there :: proc(o: Setup_Options, scope: desktop.Scope) -> bool {
	if scope not_in offered_scopes(o) { return false }
	integration, recorded := options(o, nil, scope)
	if recorded { return true }
	if integration.install_dir == "" { return false }
	info := desktop.installed_info(&integration, integration.install_dir, context.temp_allocator)
	return info.manifest
}

// The scope of the install that is there: the person's first (an account with its own copy uses it), then every
// account's; none: the person's.
installed_scope :: proc(o: Setup_Options) -> desktop.Scope {
	if install_there(o, .User) { return .User }
	if install_there(o, .System) { return .System }
	return .User
}

// The state of the install, as the disk and the system say it (strings in temp memory). `scope`: the scope asked when
// no install is there (where it would go); an install that is there says its own. `exe`: the running program ("": this
// process's).
facts :: proc(o: Setup_Options, choices: []bool = nil, scope := desktop.Scope.User, exe := "", loc := #caller_location) -> (f: Facts) {
	base.blocking("setup.facts", loc)
	user, everyone := install_there(o, .User), install_there(o, .System)
	switch {
	case user:     f.scope = .User
	case everyone: f.scope = .System
	case:          f.scope = scope in offered_scopes(o) ? scope : .User
	}
	f.other_scope = user && everyone
	f.system_refusal = .Unsupported
	if .System in offered_scopes(o) {
		machine, _ := options(o, choices, .System)
		f.system_refusal = desktop.system_refusal(&machine)
	}
	integration, recorded := options(o, choices, f.scope)
	f.running = exe != "" ? exe : process.executable_path()
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
	for p in desktop.Part {
		if s.parts[p].present && !s.parts[p].stale { f.parts += {p} }
	}
	when SYSTEM_RECORD {
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
// `choices`: the program's options (nil: their first values); `folder`: another install folder than the default (""; the
// person's scope only); `scope`: for the person, or for every account (an administrator allows its machine half). An
// install of the other scope goes once this one is in place: one install at a time.
install :: proc(o: Setup_Options, desktop_shortcut: bool, choices: []bool = nil, folder := "", scope := desktop.Scope.User) -> (ok: bool, exe_or_why: string) {
	if base.restricted() { return false, restricted_words() }
	if scope not_in offered_scopes(o) { return false, desktop.system_refusal_words(.Unsupported) }
	other := scope == .User ? desktop.Scope.System : desktop.Scope.User
	moving := install_there(o, other)
	if scope == .System {
		ok, exe_or_why = install_system(o, desktop_shortcut, choices)
	} else {
		ok, exe_or_why = install_user(o, desktop_shortcut, choices, folder, process.executable_path())
	}
	if !ok || !moving { return }
	// (the move: the install of the other scope goes, now that this one is in place)
	gone, leftovers, why := uninstall_scope(o, choices, other)
	defer {
		for l in leftovers { delete(l) }
		delete(leftovers)
	}
	if !gone { return false, fmt.tprintf(i18n.tr("Installed, but the other copy is still there: %s"), why) }
	// (Windows: the person's copy that runs this; its files go once this process ends, its folder with them. The
	// manifest is the last leftover: uninstall_scope says so)
	if len(leftovers) > 0 {
		u, _ := options(o, nil, .User)
		_ = desktop.cleanup_later(&u, leftovers[:], process.parent_dir(leftovers[len(leftovers) - 1]), desktop.current_process_id())
	}
	// The person's own places (the desktop shortcut, the start with the session, the defaults) have the same names in
	// both scopes: the removal of the old scope took the ones this install had just written. They are written again,
	// against the new program.
	if r := person_half_write(o, desktop_shortcut, choices, scope); r.error != .None { return false, failure(r) }
	return
}

// The person's half of an install of `scope` (all of it for the person's scope), against the installed program.
@(private)
person_half_write :: proc(o: Setup_Options, desktop_shortcut: bool, choices: []bool, scope: desktop.Scope) -> desktop.Result {
	integration, _ := options(o, choices, scope)
	integration.exe = join({integration.install_dir, desktop.exe_name_of(integration.identity)})
	integration.machine_half, integration.desktop_shortcut = false, desktop_shortcut
	return desktop.install(&integration)
}

// For every account: the machine half through the elevated verb (one prompt; a test's machine root: here), then the
// person's half against the installed program.
@(private = "file")
install_system :: proc(o: Setup_Options, desktop_shortcut: bool, choices: []bool) -> (ok: bool, exe_or_why: string) {
	integration, _ := options(o, choices, .System)
	if r := desktop.system_refusal(&integration); r != .None { return false, desktop.system_refusal_words(r) }
	r := machine_run(&integration, o, .Install, choices_or_first(o, choices), process.executable_path())
	if r.error == .Not_Allowed { return false, fmt.tprintf(i18n.tr("Nothing was installed: %s"), failure(r)) }
	if r.error != .None { return false, failure(r) }
	if rr := person_half_write(o, desktop_shortcut, choices, .System); rr.error != .None { return false, failure(rr) }
	return true, join({integration.install_dir, desktop.exe_name_of(integration.identity)})
}

// The machine half of a system install: in this process on a test's machine root, else the elevated verb started
// from `exe` (the download for Install, the installed program for Uninstall), awaited.
@(private)
machine_run :: proc(integration: ^desktop.Integration_Options, o: Setup_Options, verb: desktop.System_Verb, choices: []bool, exe: string) -> desktop.Result {
	if desktop.machine_is_scratch(integration) {
		m := integration^
		m.exe = exe
		if verb == .Install { return desktop.machine_install(&m, o.version) }
		return desktop.machine_remove(&m)
	}
	return desktop.machine_elevate(integration, exe, desktop.system_arguments(verb, choices))
}

// For the person: `exe` (the program that runs) copied into their profile, its parts, the record.
@(private)
install_user :: proc(o: Setup_Options, desktop_shortcut: bool, choices: []bool, folder, exe: string) -> (ok: bool, exe_or_why: string) {
	integration, _ := options(o, choices, .User)
	if folder != "" {
		if why := desktop.check_install_dir(folder, o.identity.name, probe = true); why != "" { return false, why }
		integration.install_dir = folder
	}
	if integration.install_dir == "" { return false, i18n.tr("the install folder is unknown") }
	exe_name := desktop.exe_name_of(integration.identity)
	plan := desktop.Install_Plan{
		identity = integration.identity, src_exe = exe, dir = integration.install_dir, exe_name = exe_name,
		version = o.version, channel = "release", adapt = true,
	}
	if r := desktop.files_install(plan); r.error != .None { return false, failure(r) }
	integration.exe = join({integration.install_dir, exe_name})
	integration.desktop_shortcut = desktop_shortcut
	if r := desktop.install(&integration); r.error != .None { return false, failure(r) }
	if rr := desktop.record_install(&integration, integration.install_dir, o.version); rr.error != .None { return false, failure(rr) }
	return true, integration.exe
}

// After an update put a new program in place of the installed copy (update.Updater): its install manifest and the
// system's record (Settings > Apps) say `version`. Nothing to do for `exe` when it is not the installed copy. why: "" when
// done (temp memory).
updated :: proc(o: Setup_Options, version: string, exe := "") -> (ok: bool, why: string) {
	if base.restricted() { return false, restricted_words() }
	running := exe != "" ? exe : process.executable_path()
	integration, _ := options(o)
	info := desktop.installed_info(&integration, integration.install_dir, context.temp_allocator)
	if !info.manifest || info.exe == "" || !desktop.same_path(info.exe, running) { return true, "" }
	// (an install for everyone is updated by the elevated step, which records it: src/md/features/install-scope.md)
	if integration.scope == .System { return false, i18n.tr("An install for everyone is updated by an administrator.") }
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
// Every install of the program that is there goes (both, when a move left two: the person asked for none).
uninstall :: proc(o: Setup_Options, choices: []bool = nil) -> (ok: bool, leftovers: [dynamic]string, why: string) {
	if base.restricted() { return false, nil, restricted_words() }
	user, everyone := install_there(o, .User), install_there(o, .System)
	if !user && !everyone { return uninstall_scope(o, choices, .User) }   // (what an install left: a launcher, the record)
	if user {
		ok, leftovers, why = uninstall_scope(o, choices, .User)
		if !ok { return }
	}
	if everyone {
		more: [dynamic]string
		ok, more, why = uninstall_scope(o, choices, .System)
		for l in more { append(&leftovers, l) }
		delete(more)
	}
	return
}

// An uninstall now leaves the program of the install for everyone until the next restart (Windows). The elevated verb
// runs from that file, which cannot be deleted while it runs: the verb puts it aside, and Windows deletes it at the
// restart, not when this process ends. Linux deletes a file that runs at once. Reads the disk: before the uninstall.
system_removal_at_restart :: proc(o: Setup_Options) -> bool {
	when ODIN_OS != .Windows { return false }
	if !install_there(o, .System) { return false }
	integration, _ := options(o, nil, .System)
	exe := join({integration.install_dir, desktop.exe_name_of(integration.identity)})
	// (a test's machine: no verb, the work is this process's own)
	if desktop.machine_is_scratch(&integration) { return desktop.same_path(exe, process.executable_path()) }
	return os.is_file(exe)
}

// The install of one scope goes. For everyone: the machine half first, through the elevated verb started from the
// installed program (its prompt names a file of Program Files or /opt); declined, nothing changed. Then this person's half.
// `exe`: the running program ("": this process's).
@(private)
uninstall_scope :: proc(o: Setup_Options, choices: []bool, scope: desktop.Scope, exe := "") -> (ok: bool, leftovers: [dynamic]string, why: string) {
	integration, _ := options(o, choices, scope)   // (the program's parts are taken away too)
	integration.exe = join({integration.install_dir, desktop.exe_name_of(integration.identity)})
	running := exe != "" ? exe : process.executable_path()
	if scope == .System {
		from := os.is_file(integration.exe) ? integration.exe : running
		r := machine_run(&integration, o, .Uninstall, choices_or_first(o, choices), from)
		if r.error == .Not_Allowed { return false, nil, fmt.tprintf(i18n.tr("Nothing was uninstalled: %s"), failure(r)) }
		if r.error != .None { return false, nil, failure(r) }
		integration.machine_half = false
		if rr := desktop.remove(&integration); rr.error != .None { return false, nil, failure(rr) }
		// (no leftovers: the person's helper cannot delete a file of Program Files. The elevated verb put the program
		// that runs aside, and Windows deletes it at the next restart: system_removal_at_restart, Facts.at_restart)
		return true, nil, ""
	}
	ur := desktop.uninstall(&integration, running, context.temp_allocator)
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
	p, err := process.start({command = cmd[:], working_dir = filepath.dir(exe)})
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

// The boxes of the program's options as the install is (`choices`, one per Setup_Options.choices): a choice tied to
// parts is on when they are all there (Facts.parts). Without an install the boxes keep their values: there is nothing
// to read them from, and a box ticked before the first install stays ticked.
choices_from_facts :: proc(f: Facts, o: Setup_Options, choices: []bool) {
	if !f.exe_there { return }
	for x, i in o.choices {
		if i < len(choices) && x.parts != {} { choices[i] = x.parts <= f.parts }
	}
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
	if base.restricted() { return false }   // (an administrator's process installs nothing: never offered)
	if f.from_nix || f.state == .Nix_Package { return false }
	if choice == choice_dismissed(version) { return false }
	if is_upgrade(f, version) { return true }
	return choice != CHOICE_STANDALONE && (f.state == .Not_Installed || f.state == .Repair)
}

// Why a restricted process (base.restricted: elevated) neither installs nor updates, in this system's words and the
// language in use: what the page, the dialog and the command line say.
restricted_words :: proc() -> string { return base.restricted_words(.Installs) }

@(private)
failure :: proc(r: desktop.Result) -> string {
	return r.detail != "" ? r.detail : desktop.error_text(r.error)
}

@(private)
join :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}
