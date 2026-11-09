// Package console_launcher: what a program's console launcher does with its command line, as plain functions (the
// Windows calls are in tools/console_launcher).
//
// A program with a window (the Windows subsystem) gives the prompt back at once when run from cmd or PowerShell and has
// no console of its own: a script gets neither its output nor its exit code. Its launcher, `<stem>.com` beside
// `<stem>.exe`, is a console program; cmd and PowerShell find it first when `<stem>` is typed. It starts `<stem>.exe`
// with the same arguments, and
//   * for a console command: waits for it, hands it its own standard input, output and error (so `> file`, `| more` and
//     `2>&1` work) and ends with its exit code;
//   * for the rest (what opens a window and stays): lets go of it and gives the prompt back.
// Which is which is the program's: its Rules. `--cli` anywhere makes the launcher wait, whatever the rest; the program
// never sees it. desktop.install writes the launcher beside the executable with the PATH entry (desktop/launcher.odin).
package tk_console_launcher

import "core:strings"
import "../ascii"

Mode :: enum u8 {
	Detach,   // start the program and return: its window
	Wait,     // start it, wait for it, return its exit code: a console command
}

// Which command lines wait: `default`, but those that `others` names take the other mode.
//   a word ("ctl")         the first argument is that word
//   a flag ("--version")   an argument anywhere is that flag, or that flag with a value ("--flag=value")
//   NONE                   there is no argument
Rules :: struct {
	default: Mode,
	others:  []string,
}

NONE :: "(none)"

// `--cli` anywhere: wait, whatever the rest. The launcher's own: the program does not get it.
CLI_FLAG :: "--cli"

Plan :: struct {
	mode: Mode,
	args: []string,   // what the program is given (the launcher's own `--cli` is not)
}

// Wait or detach, and the arguments for the program.
decide :: proc(args: []string, rules: Rules, allocator := context.temp_allocator) -> Plan {
	kept := make([dynamic]string, 0, len(args), allocator)
	forced := false
	for a in args {
		if a == CLI_FLAG { forced = true } else { append(&kept, a) }
	}
	if forced { return {.Wait, kept[:]} }
	mode := rules.default
	if named(kept[:], rules.others) { mode = mode == .Wait ? .Detach : .Wait }
	return {mode, kept[:]}
}

// Whether `others` names this command line.
@(private)
named :: proc(args: []string, others: []string) -> bool {
	for o in others {
		switch {
		case o == NONE:
			if len(args) == 0 { return true }
		case strings.has_prefix(o, "-"):
			for a in args { if a == o || (strings.has_prefix(a, o) && len(a) > len(o) && a[len(o)] == '=') { return true } }
		case:
			if len(args) > 0 && args[0] == o { return true }
		}
	}
	return false
}

// The rules as a program's build gives them (tools/console_launcher: -define:LAUNCHER_DEFAULT=wait|detach,
// -define:LAUNCHER_OTHERS=<comma-separated>). ok = false for a default that is neither.
rules_parse :: proc(default_mode, others: string, allocator := context.temp_allocator) -> (r: Rules, ok: bool) {
	switch default_mode {
	case "wait":   r.default = .Wait
	case "detach": r.default = .Detach
	case:          return {}, false
	}
	list := make([dynamic]string, allocator)
	for o in strings.split(others, ",", allocator) { if t := strings.trim_space(o); t != "" { append(&list, t) } }
	r.others = list[:]
	return r, true
}

// The program beside the launcher: `<dir>\<stem>.com` -> `<dir>\<stem>.exe`. ok = false when the launcher is not a
// `.com` (renamed `.exe`, it would start itself without end).
target_of :: proc(self: string, allocator := context.temp_allocator) -> (target: string, ok: bool) {
	dot := strings.last_index_byte(self, '.')
	slash := max(strings.last_index_byte(self, '\\'), strings.last_index_byte(self, '/'))
	if dot <= slash + 1 || !ascii.equal_fold(self[dot:], ".com") { return "", false }
	return strings.concatenate({self[:dot], ".exe"}, allocator), true
}

// One argument as CommandLineToArgvW (and the C runtime) read it back: quotes around what needs them, a backslash
// doubled only where a quote follows.
quote_arg :: proc(a: string, allocator := context.temp_allocator) -> string {
	if a != "" && !strings.contains_any(a, " \t\n\v\"") { return a }
	sb := strings.builder_make(allocator)
	strings.write_byte(&sb, '"')
	backslashes := 0
	for c in transmute([]byte)a {
		switch c {
		case '\\':
			backslashes += 1
		case '"':
			for _ in 0 ..< backslashes * 2 + 1 { strings.write_byte(&sb, '\\') }
			strings.write_byte(&sb, '"')
			backslashes = 0
		case:
			for _ in 0 ..< backslashes { strings.write_byte(&sb, '\\') }
			backslashes = 0
			strings.write_byte(&sb, c)
		}
	}
	for _ in 0 ..< backslashes * 2 { strings.write_byte(&sb, '\\') }   // (before the closing quote)
	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// The command line that starts `exe` with `args`.
command_line :: proc(exe: string, args: []string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, quote_arg(exe, allocator))
	for a in args {
		strings.write_byte(&sb, ' ')
		strings.write_string(&sb, quote_arg(a, allocator))
	}
	return strings.to_string(sb)
}
