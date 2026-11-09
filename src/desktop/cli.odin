package tk_desktop

// The command line of the integration, for an uninstall script and for tests (`Identity.cli_flag`, here --desktop-integration):
//
//     app --desktop-integration=install|remove|status|uninstall    (also: --desktop-integration install)
//
// The program does its job and exits without opening a window. Exit codes:
//     install, remove     0 done, 1 failed (the message says what)
//     status              0 installed, 1 absent, 2 to repair (incomplete, or it runs another executable), 3 unreadable
//     uninstall           0 done, 1 failed, 5 done but some files are in use and were scheduled for later (the caller
//                         keeps going)
// The word on the first output line is the state (installed, absent, "to repair: ..."), one line per part follows.
//
// `remove` takes away only the integration (shortcuts, the PATH entry, the browser registration); `uninstall` is the
// whole installed copy: the integration, the PATH entry, the entry in the system's list of installed programs (Windows:
// Settings > Apps) and the files files_install placed. It never touches the user's data.
//
// A program built for the Windows GUI subsystem has no console of its own: the caller passes process.console_write,
// which writes to the standard output when it is redirected or piped, else to the console of the parent.

import "core:fmt"
import "core:strings"
import "../process"

Cli_Mode :: enum u8 { None, Install, Remove, Status, Uninstall }

// Exit code of an uninstall that is done but left files in use, deleted when this process ends.
CLI_UNINSTALL_LATER :: 5

// Takes the identity's flag out of the arguments (its own form `<flag>=mode` or the two-word form, and the shorthands
// `--uninstall` / `--install` for the two actions a user runs by hand). `bad` is the value when it names no mode (the
// caller says so and exits). An identity without a flag takes nothing out.
parse_cli :: proc(id: Identity, args: []string, allocator := context.temp_allocator) -> (mode: Cli_Mode, rest: [dynamic]string, bad: string) {
	rest = make([dynamic]string, allocator)
	flag := id.cli_flag
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		value := ""
		switch {
		case flag == "": append(&rest, a); continue
		case a == "--uninstall": mode = .Uninstall; continue
		case a == "--install":   mode = .Install; continue
		case a == flag && i + 1 < len(args): value = args[i + 1]; i += 1
		case len(a) > len(flag) && strings.has_prefix(a, flag) && a[len(flag)] == '=': value = a[len(flag) + 1:]
		case: append(&rest, a); continue
		}
		switch value {
		case "install":   mode = .Install
		case "remove":    mode = .Remove
		case "status":    mode = .Status
		case "uninstall": mode = .Uninstall
		case:             bad = value
		}
	}
	return
}

// The names of the roots roots_from_env reads, after the identity's prefix.
ROOT_NAMES :: [?]string{"MENU_DIR", "DESKTOP_DIR", "ENVIRONMENT_ROOT", "INSTALL_DIR", "REGISTRY_ROOT", "APPLICATIONS_DIR", "ICONS_DIR", "BIN_DIR", "AUTOSTART_DIR"}

// The roots a test (or a script that wants a dry run in a scratch place) sets in the environment, each named
// `Identity.env_prefix` + one of ROOT_NAMES. Any of them given also turns the system notification off: nothing outside
// the scratch roots is told anything.
//     <prefix>MENU_DIR          <prefix>REGISTRY_ROOT     (Windows)
//     <prefix>DESKTOP_DIR       <prefix>ENVIRONMENT_ROOT  (Windows: the Desktop folder; the key that stands for HKCU\Environment)
//     <prefix>APPLICATIONS_DIR  <prefix>ICONS_DIR         (Linux)
//     <prefix>BIN_DIR                                     (Linux: where the PATH part puts its link)
//     <prefix>AUTOSTART_DIR                               (Linux: where the autostart entry goes)
//     <prefix>INSTALL_DIR                                 (where the installed copy is)
// An identity without a prefix reads nothing.
roots_from_env :: proc(o: ^Options, lookup: proc(name: string) -> string) {
	prefix := o.identity.env_prefix
	if prefix == "" { return }
	dsts := [len(ROOT_NAMES)]^string{&o.menu_dir, &o.desktop_dir, &o.environment_root, &o.install_dir, &o.registry_root, &o.applications_dir, &o.icons_dir, &o.bin_dir, &o.autostart_dir}
	names := ROOT_NAMES
	scratch := false
	for name, i in names {
		if v := lookup(strings.concatenate({prefix, name}, context.temp_allocator)); v != "" { dsts[i]^ = v; scratch = true }
	}
	if scratch { o.notify_system = false }
}

// Runs `mode`, writing its report with `out`. Returns the exit code.
cli_run :: proc(mode: Cli_Mode, o: ^Options, out: proc(text: string)) -> int {
	switch mode {
	case .None: return 0
	case .Install:
		if r := install(o); r.error != .None {
			out(fmt.tprintf("install failed: %s (%s)\n", error_text(r.error), r.detail))
			return 1
		}
		out("installed\n")
		return 0
	case .Remove:
		if r := remove(o); r.error != .None {
			out(fmt.tprintf("remove failed: %s (%s)\n", error_text(r.error), r.detail))
			return 1
		}
		out("removed\n")
		return 0
	case .Uninstall:
		ur := uninstall(o, process.executable_path(), context.temp_allocator)
		defer uninstall_result_destroy(&ur)
		if ur.result.error != .None {
			out(fmt.tprintf("uninstall failed: %s (%s)\n", error_text(ur.result.error), ur.result.detail))
			return 1
		}
		if len(ur.leftovers) > 0 {
			// the copy being uninstalled is the one running: its own files cannot be deleted now. Schedule their deletion
			// (and the folder's) for after this process ends, and tell the caller with its exit code (done, finishing later).
			files := make([dynamic]string, context.temp_allocator)
			for l in ur.leftovers { append(&files, l) }
			if ur.folder != "" { append(&files, join_path(ur.folder, o.identity.manifest_name)) }
			cleanup_later(o, files[:], ur.folder, current_process_id())
			out("uninstalled (some files are in use and will be removed when this copy closes)\n")
			return CLI_UNINSTALL_LATER
		}
		out("uninstalled\n")
		return 0
	case .Status:
		s := status(o, context.temp_allocator)
		if s.error != .None { out(fmt.tprintf("unreadable: %s\n", error_text(s.error))); return 3 }
		out(fmt.tprintf("%s\n", describe(&s)))
		for p in Part {
			if p not_in s.wanted && !s.parts[p].present { continue }
			ps := s.parts[p]
			out(fmt.tprintf("  %v: %s%s%s\n", p, ps.present ? "present" : "missing", ps.partial ? " (incomplete)" : "", ps.target != "" ? fmt.tprintf(" -> %s", ps.target) : ""))
		}
		switch s.state {
		case .Installed: return 0
		case .Absent:    return 1
		case .Repair:    return 2
		}
	}
	return 0
}
