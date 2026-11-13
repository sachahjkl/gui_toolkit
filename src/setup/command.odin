package tk_setup

// The command line of the install, the same in every program:
//
//   <program> --install     installs this copy for the user (the program, the menu's entry, the system's record and the
//                           program's own parts: Setup_Options.prepare), as the Install button does; no window
//   <program> --uninstall   takes it all away (the user's settings and data stay); no window
//   <program> --status      says the install's state and whether the program runs; no window
//   <program> --setup       starts the program with its installation shown (Settings > Apps' Uninstall runs it:
//                           Identity.uninstall_arguments)
//
// A program lists COMMAND_OPTIONS in its table of options (gt:cli), takes the command out with command_of before it
// opens a window, and for Install, Uninstall and Status exits with command_run's code.

import "core:fmt"
import cli "../cli"
import desktop "../desktop"

Command :: enum u8 { None, Install, Uninstall, Status, Setup }

// The options of the command line, for the program's table (cli.check, cli.usage).
@(rodata)
COMMAND_OPTIONS := [?]cli.Option{
	{name = "install", help = "install this copy for you: the program, the menu entry, and its uninstaller", group = "Installation"},
	{name = "uninstall", help = "remove the installed copy (your settings and data stay)", group = "Installation"},
	{name = "status", help = "say what is installed, and whether the program runs (exit code 0 installed, 2 to repair, 1 not installed)", group = "Installation"},
	{name = "setup", help = "open the window on the installation"},
}

// Takes the install's options out of the arguments (the last one given wins); `rest`: the others, in their order.
command_of :: proc(args: []string, allocator := context.temp_allocator) -> (c: Command, rest: [dynamic]string) {
	rest = make([dynamic]string, 0, len(args), allocator)
	for a in args {
		switch a {
		case "--install":   c = .Install
		case "--uninstall": c = .Uninstall
		case "--status":    c = .Status
		case "--setup":     c = .Setup
		case:               append(&rest, a)
		}
	}
	return
}

// Whether the command runs without a window: the program exits with command_run's code.
command_alone :: proc(c: Command) -> bool { return c == .Install || c == .Uninstall || c == .Status }

// Exit codes of command_run: done (Status: installed), failed (Status: not installed), to repair (Status). An uninstall
// of the copy that runs leaves its files for after the process (desktop.CLI_UNINSTALL_LATER): still done for a script,
// the files go once it ends.
COMMAND_DONE   :: 0
COMMAND_FAILED :: 1
COMMAND_REPAIR :: 2

// Runs Install, Uninstall or Status, says what happened with `out` (process.console_write: a program of the GUI
// subsystem has no console of its own) and returns the exit code. Reads and writes the disk: before the window, never
// from a frame. None and Setup do nothing (Setup is the window's).
command_run :: proc(c: Command, o: Setup_Options, out: proc(text: string)) -> int {
	name := o.identity.name
	#partial switch c {
	case .Install:
		ok, exe_or_why := install(o, false)
		if !ok {
			out(fmt.tprintf("%s: the install failed: %s\n", name, exe_or_why))
			return COMMAND_FAILED
		}
		out(fmt.tprintf("%s: installed: %s\n", name, exe_or_why))
		if desktop.is_nixos() { out(fmt.tprintf("%s: on NixOS a Nix package is the better install: Nix updates it\n", name)) }
		return COMMAND_DONE
	case .Uninstall:
		ok, leftovers, why := uninstall(o)
		defer {
			for l in leftovers { delete(l) }
			delete(leftovers)
		}
		if ok && len(leftovers) > 0 && !remove_later(o, leftovers[:]) { ok, why = false, "the removal of the program cannot be scheduled" }
		if !ok {
			out(fmt.tprintf("%s: the uninstall failed: %s\n", name, why))
			return COMMAND_FAILED
		}
		out(fmt.tprintf("%s: uninstalled (your settings and data stay)\n", name))
		return COMMAND_DONE
	case .Status:
		f := facts(o)
		running := o.running != nil && o.running()
		out(status_text(f, o, running))
		return status_code(f.state)
	}
	return COMMAND_DONE
}

// What --status says, a fact a line ("key: value"), the first the state in a word: what scripts and tests read.
status_text :: proc(f: Facts, o: Setup_Options, running: bool) -> string {
	yes_no :: proc(b: bool) -> string { return b ? "yes" : "no" }
	words := [State]string{
		.Not_Installed = "not installed", .This_Copy = "installed (this copy)", .Repair = "installed, to repair",
		.Other_Copy = "installed (another copy)", .Removal_Scheduled = "uninstalled", .Nix_Package = "installed by Nix",
	}
	return fmt.tprintf("%s: %s\n  program: %s\n  version: %s\n  this copy: %s %s\n  menu entry: %s\n  start with the session: %s\n  on the PATH: %s\n  running: %v\n",
		o.identity.name, words[f.state], f.exe_there ? f.exe : "-", f.version != "" ? f.version : "-", o.version, f.running,
		yes_no(f.start_lnk), yes_no(f.autostart), yes_no(f.on_path), running)
}

// The exit code of --status for a state: 0 installed (a Nix package too), 2 to repair, 1 not installed.
status_code :: proc(s: State) -> int {
	switch s {
	case .This_Copy, .Other_Copy, .Nix_Package: return COMMAND_DONE
	case .Repair:                               return COMMAND_REPAIR
	case .Not_Installed, .Removal_Scheduled:    return COMMAND_FAILED
	}
	return COMMAND_FAILED
}
