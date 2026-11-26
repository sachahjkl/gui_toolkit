package tk_desktop

// The scope of an install (src/md/features/install-scope.md): the person's profile (User), or the computer for every
// account (System). A system install has two halves: the machine's (machine_parts, the files, the record), which an
// administrator allows through one elevated verb, and the person's (the rest), which each account writes for itself.

import "core:os"
import "core:strings"
import base "../base"
import i18n "../i18n"
import "../fsx"

Scope :: enum u8 {
	User,     // the person's profile: no administrator
	System,   // the computer, for every account: an administrator allows its machine half
}
Scopes :: bit_set[Scope]

// Why this computer cannot have an install for everyone from this program (None: it can).
System_Refusal :: enum u8 {
	None,
	Unsupported,    // this system has no such install here
	Nix,            // NixOS: the Nix package in the system's configuration is the install for every account
	No_Elevation,   // no administrator can be asked: Windows refuses this account's prompts; Linux has no pkexec
}

// The elevated verb: `<exe> --system install <choices>` or `--system uninstall` (setup.command_of reads it). Its
// arguments are a word and, for install, one 0 or 1 per box of the program's choices: no path, no root.
SYSTEM_FLAG :: "--system"

// The verbs of SYSTEM_FLAG.
System_Verb :: enum u8 { Install, Uninstall }

// The word of a verb on the command line.
system_verb_word :: proc(v: System_Verb) -> string {
	switch v {
	case .Install:   return "install"
	case .Uninstall: return "uninstall"
	}
	return ""
}

// The parts of a system install that every account shares, where the system has them (machine_parts): the menu entry
// and the icons, the PATH, the registrations of the documents and of the browser, the thumbnailer, Task Manager.
@(private) MACHINE_PARTS :: Parts{.Launcher, .Icons, .Path, .Registration, .Documents, .Thumbnails, .Task_Manager}
// The parts only an install for everyone has: the machine's, for every account.
@(private) SYSTEM_ONLY_PARTS :: Parts{.Task_Manager}

// The scopes this system has. Linux and Windows have both; any other, the person's alone.
supported_scopes :: proc() -> Scopes {
	when ODIN_OS == .Windows || ODIN_OS == .Linux { return {.User, .System} }
	return {.User}
}

// The parts of this system that a system install shares among its accounts: its machine half, written by the elevated
// verb. The others are each person's (the desktop shortcut, the start with the session, the defaults).
machine_parts :: proc() -> Parts { return supported_parts() & MACHINE_PARTS }

// The parts a scope has here: Task Manager is the machine's, and only an install for everyone gives it.
scope_parts :: proc(scope: Scope) -> Parts {
	p := supported_parts()
	if scope == .User { p -= SYSTEM_ONLY_PARTS }
	return p
}

// Why "For everyone" cannot be offered here for these options (None: it can). A test's machine root is no real machine:
// nothing refuses it. Reads the system: never on the interface's thread.
system_refusal :: proc(o: ^Integration_Options, loc := #caller_location) -> System_Refusal {
	base.blocking("desktop.system_refusal", loc)
	if .System not_in supported_scopes() { return .Unsupported }
	if machine_is_scratch(o) { return .None }
	if is_nixos() { return .Nix }
	return system_refusal_here()   // (scope_windows.odin, scope_linux.odin)
}

// What the dialog says under "For everyone" when it cannot be offered, in the language in use ("" for None).
system_refusal_words :: proc(r: System_Refusal) -> string {
	switch r {
	case .None:         return ""
	case .Unsupported:  return i18n.tr("This system has no install for everyone.")
	case .Nix:          return i18n.tr("On NixOS, the install for everyone is the Nix package in the system's configuration.")
	case .No_Elevation: return no_elevation_words()
	}
	return ""
}

// This call writes or removes part `p`: every part of a user install; of a system install, the parts of its half.
@(private)
touches :: proc(o: ^Integration_Options, p: Part) -> bool {
	if o.scope != .System { return true }
	return (p in machine_parts()) == o.machine_half
}

// This call is in the machine's places: the machine half of a system install.
@(private)
in_machine :: proc(o: ^Integration_Options) -> bool { return o.scope == .System && o.machine_half }

// A test's stand-in for the machine's folders ("" = the system's). Never in a restricted process: a root comes from
// the environment, which the user writes, and an elevated process must not write the machine's half elsewhere than in
// the system's own places.
@(private)
machine_root_of :: proc(o: ^Integration_Options) -> string { return base.restricted() ? "" : o.machine_root }

// The machine half and the record are a test's (its roots) and need no administrator: setup writes them in this process.
machine_is_scratch :: proc(o: ^Integration_Options) -> bool { return machine_root_of(o) != "" }

// The arguments of the elevated verb for `choices` (temp memory): "install 101", "uninstall".
system_arguments :: proc(verb: System_Verb, choices: []bool) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, SYSTEM_FLAG, system_verb_word(verb))
	if verb == .Install {
		sb := strings.builder_make(context.temp_allocator)
		for c in choices { strings.write_byte(&sb, c ? '1' : '0') }
		append(&out, strings.to_string(sb))
	}
	return out[:]
}

// The choices of the elevated verb's argument ("101"), checked against their number: ok = false for anything else.
system_choices :: proc(text: string, count: int, allocator := context.temp_allocator) -> (choices: []bool, ok: bool) {
	if len(text) != count { return nil, false }
	choices = make([]bool, count, allocator)
	for i in 0 ..< len(text) {
		switch text[i] {
		case '0':
		case '1': choices[i] = true
		case: return nil, false
		}
	}
	return choices, true
}

// The machine half of a system install, in this process: the program's files (the image of this very process, or a
// test's o.exe), the machine's parts, the system's record. The elevated verb's work, or a test's on its roots. It starts
// nothing, so a restricted process does it; the places are then the system's own (machine_root_of).
machine_install :: proc(o: ^Integration_Options, version: string) -> Result {
	b := platform_backend()
	if b == nil { return {.Unsupported, error_text(.Unsupported)} }
	o.scope, o.machine_half = .System, true
	if e := validate(o, need_exe = false); e.error != .None { return e }
	dir := system_install_dir(o)
	if dir == "" { return {.System, "the machine's program folder is unknown"} }
	exe_name := exe_name_of(o.identity)
	exe := fsx.path_join(dir, exe_name)
	if r := machine_prepare(o, dir); r.error != .None { return r }
	// (the program: this process's own image, not the file at a path, which a user may have changed since the consent)
	src := o.exe
	if !machine_is_scratch(o) {
		if r := self_image_place(exe); r.error != .None { return r }
		src = exe
	}
	plan := Install_Plan{identity = o.identity, src_exe = src, dir = dir, exe_name = exe_name, version = version, channel = "release"}
	if r := files_install(plan); r.error != .None { return r }
	o.exe = exe
	if r := b.install(o); r.error != .None { return r }
	if b.record != nil {
		if r := b.record(o, dir, version); r.error != .None { return r }
	}
	return {}
}

// Takes the machine half of a system install away: its parts, the record, the files. What runs and cannot be deleted
// now (Windows: the program that runs this) goes at the next restart.
machine_remove :: proc(o: ^Integration_Options) -> Result {
	b := platform_backend()
	if b == nil { return {.Unsupported, error_text(.Unsupported)} }
	o.scope, o.machine_half = .System, true
	if e := validate(o, need_exe = false); e.error != .None { return e }
	dir := system_install_dir(o)
	if dir == "" { return {.System, "the machine's program folder is unknown"} }
	o.exe = fsx.path_join(dir, exe_name_of(o.identity))
	// (the same folders as an install: root deletes what the manifest of the program's folder names)
	if r := machine_prepare(o, dir); r.error != .None { return r }
	res := b.remove(o)
	if res.error != .None { return res }
	if b.unrecord != nil {
		if r := b.unrecord(o); r.error != .None { res = r }
	}
	if b.path_remove != nil {
		if r := b.path_remove(o, dir); r.error != .None && res.error == .None { res = r }
	}
	rm := files_remove(o, dir)
	if rm.result.error != .None && res.error == .None { res = rm.result }
	if len(rm.leftovers) > 0 {
		// (the manifest goes now: the record is gone, and no install is read there any more; the files at the restart)
		_ = os.remove(fsx.path_join(dir, o.identity.manifest_name))
		for l in rm.leftovers { remove_at_restart(l) }
		remove_at_restart(dir)
	}
	return res
}

// Where a system install of these options is: the system's place for every account (system_install_dir_here), or the
// test's machine root. A folder that a person chose never counts: it may be one that a user can write.
system_install_dir :: proc(o: ^Integration_Options, allocator := context.temp_allocator) -> string {
	return system_install_dir_here(o, machine_root_of(o), allocator)
}

// A folder name from the vendor's or the program's name: "" when it is not one (a separator, "..", a reserved character).
@(private)
folder_name_ok :: proc(name: string) -> bool {
	return name != "" && !strings.contains_any(name, "\\/:*?\"<>|\x00") && !strings.contains(name, "..")
}
