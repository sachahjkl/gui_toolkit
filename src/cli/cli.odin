// A program's command line, from one table of its options: `--help` says them, `--version` says the version, and an option
// the table does not have is refused (with the help), so a typo or a guess does not start the program as if nothing was said.
// What each option does stays the program's: this only says whether the line is one it understands.
//
//   OPTIONS :: []cli.Option{
//       {name = "session", value = "id", help = "open that session at start"},
//       {name = "settings", value = "n", optional = true, help = "open the settings at start (on page n)"},
//       {name = "pref", value = "name=value", separate = true, help = "set a preference for the run"},
//       {name = "seek-subagent", hidden = true},
//   }
//   if out, code, stop := cli.check({name = "opencode-native", summary = "...", version = "0.45.0"}, OPTIONS, os.args[1:]); stop {
//       print(out); os.exit(code)
//   }
package tk_cli

import "core:fmt"
import "core:strings"

Option :: struct {
	name:     string,   // without its dashes: "session" is --session
	value:    string,   // what it takes, in words ("id", "w>x<h"): written --name=<value>; "": a switch
	optional: bool,     // the value may be left out (--settings, --settings=2)
	separate: bool,     // the value may also be the next argument (--pref name=value)
	help:     string,
	hidden:   bool,     // accepted, not listed (what tools and tests pass)
}

Program :: struct {
	name:    string,   // as it is typed
	summary: string,   // one line: what it is
	version: string,   // --version says it ("": no --version)
	footer:  string,   // after the options (where its files are); "": none
}

// Exit codes: the help asked, a line not understood (as getopt's programs).
EXIT_OK    :: 0
EXIT_USAGE :: 2

// The help: the program, how it is called, its options (not the hidden ones) with what each takes.
usage :: proc(p: Program, options: []Option, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s", p.name)
	if p.summary != "" { fmt.sbprintf(&b, ": %s", p.summary) }
	fmt.sbprintf(&b, "\n\nUsage: %s [options]\n\nOptions:\n", p.name)
	forms := make([]string, len(options) + 2, context.temp_allocator)
	width := 0
	for o, i in options {
		if o.hidden { continue }
		forms[i] = form(o)
		width = max(width, len(forms[i]))
	}
	builtin := [2]Option{{name = "help", help = "this help"}, {name = "version", help = "the version"}}
	for o, i in builtin { forms[len(options) + i] = form(o); width = max(width, len(forms[len(options) + i])) }
	line :: proc(b: ^strings.Builder, f, help: string, width: int) {
		fmt.sbprintf(b, "  %s", f)
		if help != "" { fmt.sbprintf(b, "%*s  %s", width - len(f), "", help) }
		strings.write_byte(b, '\n')
	}
	for o, i in options { if !o.hidden { line(&b, forms[i], o.help, width) } }
	line(&b, forms[len(options)], builtin[0].help, width)
	if p.version != "" { line(&b, forms[len(options) + 1], builtin[1].help, width) }
	if p.footer != "" { fmt.sbprintf(&b, "\n%s\n", p.footer) }
	return strings.to_string(b)
}

@(private = "file")
form :: proc(o: Option) -> string {
	switch {
	case o.value == "": return fmt.tprintf("--%s", o.name)
	case o.optional:    return fmt.tprintf("--%s[=<%s>]", o.name, o.value)
	case o.separate:    return fmt.tprintf("--%s <%s>", o.name, o.value)
	}
	return fmt.tprintf("--%s=<%s>", o.name, o.value)
}

// Whether the line `args` (without the program) is one of `options`. `stop`: print `out` and end with `code` (--help, --version,
// or a line not understood); else the program goes on and reads its options as it does.
check :: proc(p: Program, options: []Option, args: []string) -> (out: string, code: int, stop: bool) {
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--help", "-h", "-?", "/?": return usage(p, options), EXIT_OK, true
		case "--version":
			if p.version != "" { return fmt.tprintf("%s %s\n", p.name, p.version), EXIT_OK, true }
		}
		if !strings.has_prefix(a, "--") { return refused(p, options, fmt.tprintf("%s: what is %q? (no argument without an option)", p.name, a)), EXIT_USAGE, true }
		name, _, value := strings.partition(a[2:], "=")
		has_value := strings.contains_rune(a, '=')
		o, known := find(options, name)
		if !known { return refused(p, options, fmt.tprintf("%s: unknown option --%s", p.name, name)), EXIT_USAGE, true }
		switch {
		case o.value == "" && has_value:
			return refused(p, options, fmt.tprintf("%s: --%s takes no value", p.name, name)), EXIT_USAGE, true
		case o.value != "" && !has_value && o.separate:
			if i + 1 >= len(args) { return refused(p, options, fmt.tprintf("%s: --%s needs <%s> after it", p.name, name, o.value)), EXIT_USAGE, true }
			i += 1
		case o.value != "" && !has_value && !o.optional:
			return refused(p, options, fmt.tprintf("%s: --%s needs a value: --%s=<%s>", p.name, name, name, o.value)), EXIT_USAGE, true
		case has_value && value == "" && !o.optional:
			return refused(p, options, fmt.tprintf("%s: --%s needs a value: --%s=<%s>", p.name, name, name, o.value)), EXIT_USAGE, true
		}
	}
	return "", EXIT_OK, false
}

@(private = "file")
find :: proc(options: []Option, name: string) -> (Option, bool) {
	for o in options { if o.name == name { return o, true } }
	return {}, false
}

@(private = "file")
refused :: proc(p: Program, options: []Option, why: string) -> string {
	return fmt.tprintf("%s\n\n%s", why, usage(p, options))
}
