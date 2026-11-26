package tk_setup

// The command line of the install, the same in every program:
//
//   <program> --install     installs this copy for the user (the program, the menu's entry, the system's record and the
//                           program's own parts: Setup_Options.prepare), as the Install button does; no window
//   <program> --uninstall   takes it all away (the user's settings and data stay); no window
//   <program> --status      says the install's state, whether the program runs and whether it can be asked to end;
//                           no window
//   <program> --quit        asks the copy that runs to end (Setup_Options.quit), then waits for it to end, for a
//                           bounded time; no window
//   <program> --setup       starts the program with its installation shown (Settings > Apps' Uninstall runs it:
//                           Identity.uninstall_arguments)
//   <program> --system install <choices> | uninstall
//                           the machine half of an install for everyone, which Install and Uninstall start as an
//                           administrator (runas, pkexec): one 0 or 1 per box of Setup_Options.choices, no path; no window
//
// A program lists COMMAND_OPTIONS in its table of options (gt:cli), takes the command out with command_of before it
// opens a window, and for Install, Uninstall, Status and Quit exits with command_run's code.

import "core:fmt"
import "core:strings"
import "core:time"
import base "../base"
import cli "../cli"
import desktop "../desktop"
import process "../process"

Command :: enum u8 { None, Install, Uninstall, Status, Quit, Setup, System_Install, System_Uninstall }

// How long --quit waits for the copy that runs to end (it may save its work first), and how often it looks.
QUIT_WAIT :: 10 * time.Second
QUIT_POLL :: 50 * time.Millisecond

// The options of the command line, for the program's table (cli.check, cli.usage).
@(rodata)
COMMAND_OPTIONS := [?]cli.Option{
	{name = "install", help = "install this copy for you: the program, the menu entry, and its uninstaller", group = "Installation"},
	{name = "uninstall", help = "remove the installed copy (your settings and data stay)", group = "Installation"},
	{name = "status", help = "say what is installed, and whether the program runs (exit code 0 installed, 1 not installed or to repair)", group = "Installation"},
	{name = "quit", help = "ask the program that runs to end, and wait for it (exit code 0 ended or not running, 1 still running)", group = "Installation"},
	{name = "setup", help = "open the window on the installation"},
	// (what Install and Uninstall start as an administrator: a person does not type it)
	{name = "system", value = "install|uninstall", separate = true, hidden = true, help = "install or remove the part of an install for everyone that every account shares (as an administrator)", group = "Installation"},
}

// Takes the install's options out of the arguments (the last one given wins); `rest`: the others, in their order.
command_of :: proc(args: []string, allocator := context.temp_allocator) -> (c: Command, rest: [dynamic]string) {
	rest = make([dynamic]string, 0, len(args), allocator)
	for i := 0; i < len(args); i += 1 {
		switch a := args[i]; a {
		case "--install":   c = .Install
		case "--uninstall": c = .Uninstall
		case "--status":    c = .Status
		case "--quit":      c = .Quit
		case "--setup":     c = .Setup
		case desktop.SYSTEM_FLAG:
			// (its verb is the next argument, then for install its choices; without a verb it is no command, and stays
			// for the program to refuse)
			verb, _, taken := system_command(args[i:])
			if taken == 0 {
				append(&rest, a)
			} else {
				c = verb == .Install ? .System_Install : .System_Uninstall
				i += taken - 1
			}
		case:               append(&rest, a)
		}
	}
	return
}

// The elevated verb at the head of `args` (SYSTEM_FLAG, its verb, for install its choices of 0 and 1): `taken`, the
// arguments it is made of (0: none).
system_command :: proc(args: []string) -> (verb: desktop.System_Verb, choices: string, taken: int) {
	if len(args) < 2 || args[0] != desktop.SYSTEM_FLAG { return }
	switch args[1] {
	case desktop.system_verb_word(.Uninstall): return .Uninstall, "", 2
	case desktop.system_verb_word(.Install):
		if len(args) > 2 && strings.trim(args[2], "01") == "" && args[2] != "" { return .Install, args[2], 3 }
		return .Install, "", 2
	}
	return
}

// Whether the command runs without a window: the program exits with command_run's code.
command_alone :: proc(c: Command) -> bool { return c != .None && c != .Setup }

// Runs Install, Uninstall, Status or Quit, says what happened with `out` (process.console_write: a program of the GUI
// subsystem has no console of its own) and how it ended (the program ends with it: cli.exit). Status is .Done when an
// install is there whole, .Failed otherwise (its words say which: not installed, to repair). An uninstall of the copy
// that runs leaves its files for after the process: still .Done, the files go once it ends. Reads and writes the disk:
// before the window, never from a frame. None and Setup do nothing (Setup is the window's).
command_run :: proc(c: Command, o: Setup_Options, out: proc(text: string)) -> cli.Exit {
	base.dll_search_restrict()   // (before anything loads a library: --task-manager runs as an administrator)
	base.restrict_if_elevated()   // (--install from an administrator's console installs nothing: setup.restricted_words)
	name := o.identity.name
	#partial switch c {
	case .Install:
		// (the boxes as the system has them: an install from the command line keeps the parts a box stands for, and
		// does not take away what an earlier Install with the dialog put)
		f := facts(o)
		choices := make([]bool, len(o.choices), context.temp_allocator)
		for x, i in o.choices { choices[i] = x.on }
		choices_from_facts(f, o, choices)
		// (the scope of the install that is there: a command line never moves it)
		ok, exe_or_why := install(o, false, choices, scope = f.scope)
		if !ok {
			out(fmt.tprintf("%s: the install failed: %s\n", name, exe_or_why))
			return .Failed
		}
		out(fmt.tprintf("%s: installed: %s\n", name, exe_or_why))
		if desktop.is_nixos() { out(fmt.tprintf("%s: on NixOS a Nix package is the better install: Nix updates it\n", name)) }
		return .Done
	case .Uninstall:
		at_restart := system_removal_at_restart(o)
		ok, leftovers, why := uninstall(o)
		defer {
			for l in leftovers { delete(l) }
			delete(leftovers)
		}
		if ok && len(leftovers) > 0 && !remove_later(o, leftovers[:]) { ok, why = false, "the removal of the program cannot be scheduled" }
		if !ok {
			out(fmt.tprintf("%s: the uninstall failed: %s\n", name, why))
			return .Failed
		}
		out(fmt.tprintf("%s: uninstalled (your settings and data stay)%s\n", name, at_restart ? "; the program is deleted at the next restart" : ""))
		return .Done
	case .Status:
		f := facts(o)
		running := o.running != nil && o.running()
		out(status_text(f, o, running))
		return status_exit(f.state)
	case .Quit:
		return quit_run(o, out)
	case .System_Install, .System_Uninstall:
		// (the elevated verb: its arguments read again from the command line Windows or pkexec gave; restricted, it
		// writes only the system's places, from its own image)
		_, text, _ := system_command(system_args(process.command_line_args()))
		integration: desktop.Integration_Options
		r: desktop.Result
		if c == .System_Install {
			choices, ok := desktop.system_choices(text, len(o.choices))
			if !ok {
				out(fmt.tprintf("%s: the choices are not this program's\n", name))
				return .Failed
			}
			integration, _ = options(o, choices, .System)
			r = desktop.machine_install(&integration, o.version)
		} else {
			integration, _ = options(o, nil, .System)
			r = desktop.machine_remove(&integration)
		}
		if r.error != .None {
			out(fmt.tprintf("%s: the install for everyone was not changed: %s\n", name, failure(r)))
			return .Failed
		}
		out(fmt.tprintf("%s: %s for everyone\n", name, c == .System_Install ? "installed" : "uninstalled"))
		return .Done
	}
	return .Done
}

// The arguments from SYSTEM_FLAG on (none: empty).
@(private = "file")
system_args :: proc(args: []string) -> []string {
	for a, i in args { if a == desktop.SYSTEM_FLAG { return args[i:] } }
	return nil
}

// --quit: the copy that runs is asked to end (Setup_Options.quit), then the end is awaited, at most QUIT_WAIT: its
// single instance gone, and no process left of the installed copy's file (an installer replaces that file next; on
// Windows a process that is still ending holds it). Done when nothing runs; failed when it cannot be asked, or still runs.
@(private = "file")
quit_run :: proc(o: Setup_Options, out: proc(text: string)) -> cli.Exit {
	name := o.identity.name
	if o.running == nil || !o.running() {
		out(fmt.tprintf("%s: not running\n", name))
		return .Done
	}
	if o.quit == nil {
		out(fmt.tprintf("%s: it runs, and cannot be asked to end\n", name))
		return .Failed
	}
	if !o.quit() {
		out(fmt.tprintf("%s: the copy that runs did not take the request to end\n", name))
		return .Failed
	}
	f := facts(o)
	deadline := time.tick_add(time.tick_now(), QUIT_WAIT)
	for {
		left := f.exe_there ? len(process.processes_of(f.exe, context.temp_allocator)) : 0
		if left == 0 && !o.running() {
			out(fmt.tprintf("%s: ended\n", name))
			return .Done
		}
		if time.tick_diff(time.tick_now(), deadline) <= 0 {
			out(fmt.tprintf("%s: still running after %v\n", name, QUIT_WAIT))
			return .Failed
		}
		time.sleep(QUIT_POLL)
	}
}

// What --status says, a fact a line ("key: value"), the first the state in a word: what scripts and tests read.
// `quit: yes` says that --quit can end the copy that runs (Setup_Options.quit): an installer asks it before it replaces
// the program, and ends the process by other means when it says no (a program built before --quit says nothing).
status_text :: proc(f: Facts, o: Setup_Options, running: bool) -> string {
	yes_no :: proc(b: bool) -> string { return b ? "yes" : "no" }
	words := [State]string{
		.Not_Installed = "not installed", .This_Copy = "installed (this copy)", .Repair = "installed, to repair",
		.Other_Copy = "installed (another copy)", .Removal_Scheduled = "uninstalled", .Nix_Package = "installed by Nix",
	}
	return fmt.tprintf("%s: %s\n  program: %s\n  for: %s\n  version: %s\n  this copy: %s %s\n  menu entry: %s\n  start with the session: %s\n  on the PATH: %s\n  running: %v\n  quit: %s\n",
		o.identity.name, words[f.state], f.exe_there ? f.exe : "-", f.scope == .System ? "everyone" : "me", f.version != "" ? f.version : "-", o.version, f.running,
		yes_no(f.start_lnk), yes_no(f.autostart), yes_no(f.on_path), running, yes_no(o.quit != nil))
}

// How --status ends for a state: .Done installed whole (a Nix package too), .Failed not installed or to repair.
status_exit :: proc(s: State) -> cli.Exit {
	switch s {
	case .This_Copy, .Other_Copy, .Nix_Package:            return .Done
	case .Repair, .Not_Installed, .Removal_Scheduled:      return .Failed
	}
	return .Failed
}
