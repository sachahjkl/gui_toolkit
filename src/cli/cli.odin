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
import "core:unicode/utf8"

Option :: struct {
	name:     string,   // without its dashes: "session" is --session
	value:    string,   // what it takes, in words ("id", "w>x<h"): written --name=<value>; "": a switch
	optional: bool,     // the value may be left out (--settings, --settings=2)
	separate: bool,     // the value may also be the next argument (--pref name=value)
	help:     string,
	hidden:   bool,     // accepted, not listed (what tools and tests pass)
	group:    string,   // the heading it is listed under (the first option of a group names it; "": "Options")
}

// A line of the help's examples: what is typed, what it does.
Example :: struct { line, what: string }

// A variable of the environment the program reads, and what it does.
Variable :: struct { name, what: string }

Program :: struct {
	name:    string,   // as it is typed
	summary: string,   // one line: what it is
	version: string,   // --version says it ("": no --version)
	examples:    []Example,
	environment: []Variable,
	footer:      string,   // last (where its files are); "": none
}

// Exit codes: the help asked, a line not understood (as getopt's programs).
EXIT_OK    :: 0
EXIT_USAGE :: 2

// The help: the program, how it is called, its options by group (not the hidden ones) with what each takes, examples, the
// environment it reads, and the footer.
usage :: proc(p: Program, options: []Option, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "%s", p.name)
	if p.summary != "" { fmt.sbprintf(&b, ": %s", p.summary) }
	fmt.sbprintf(&b, "\n\nUsage: %s [options]\n", p.name)
	builtin := [2]Option{{name = "help", help = "this help", group = "Help"}, {name = "version", help = "the version", group = "Help"}}
	all := make([dynamic]Option, context.temp_allocator)
	for o in options { if !o.hidden { append(&all, o) } }
	append(&all, builtin[0])
	if p.version != "" { append(&all, builtin[1]) }
	// (a column per section, its widest name and a gap; widths in characters, not bytes)
	cols :: proc(names: []string) -> (w: int) {
		for n in names { w = max(w, utf8.rune_count_in_string(n)) }
		return
	}
	line :: proc(b: ^strings.Builder, f, help: string, width: int) {
		fmt.sbprintf(b, "  %s", f)
		if help != "" { fmt.sbprintf(b, "%*s  %s", width - utf8.rune_count_in_string(f), "", help) }
		strings.write_byte(b, '\n')
	}
	forms := make([]string, len(all), context.temp_allocator)
	for o, i in all { forms[i] = form(o) }
	width := cols(forms)   // (the options: one column, whatever their group, they read as one table)
	group := ""
	for o, i in all {
		g := o.group != "" ? o.group : (i == 0 ? "Options" : group)
		if i == 0 || g != group { fmt.sbprintf(&b, "\n%s:\n", g); group = g }
		line(&b, forms[i], o.help, width)
	}
	if len(p.examples) > 0 {
		fmt.sbprintf(&b, "\nExamples:\n")
		lines := make([]string, len(p.examples), context.temp_allocator)
		for e, i in p.examples { lines[i] = e.line }
		w := cols(lines)
		for e in p.examples { line(&b, e.line, e.what, w) }
	}
	if len(p.environment) > 0 {
		fmt.sbprintf(&b, "\nEnvironment:\n")
		names := make([]string, len(p.environment), context.temp_allocator)
		for v, i in p.environment { names[i] = v.name }
		w := cols(names)
		for v in p.environment { line(&b, v.name, v.what, w) }
	}
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

// One option of a line, as given: `value` is "" for a switch, or for an optional value left out (`has_value` says which).
// The strings are slices of the line's arguments.
Given :: struct {
	name:      string,
	value:     string,
	has_value: bool,
}

// The options of the line `args`, in their order, read by the table: a `separate` value joined to its option. Call it after
// `check` accepted the line: what the table does not have is skipped. The program then reads its options from the result
// once (value, values, has), instead of looking through the line again where each is used.
parse :: proc(options: []Option, args: []string, allocator := context.allocator) -> []Given {
	out := make([dynamic]Given, 0, len(args), allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if !strings.has_prefix(a, "--") { continue }
		name, _, value := strings.partition(a[2:], "=")
		has_value := strings.contains_rune(a, '=')
		o, known := find(options, name)
		if !known { continue }
		if o.value != "" && !has_value && o.separate && i + 1 < len(args) {
			i += 1
			value, has_value = args[i], true
		}
		append(&out, Given{name, value, has_value})
	}
	return out[:]
}

// The value of the option `name`, the last one when it was given twice (as a later option overrides an earlier one). `ok`:
// it was given with a value.
value :: proc(given: []Given, name: string) -> (value: string, ok: bool) {
	#reverse for g in given { if g.name == name && g.has_value { return g.value, true } }
	return "", false
}

// Every value of an option that may be given more than once (--pref a=1 --pref b=2), in order.
values :: proc(given: []Given, name: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for g in given { if g.name == name && g.has_value { append(&out, g.value) } }
	return out[:]
}

// Whether the option `name` was given, with a value or without.
has :: proc(given: []Given, name: string) -> bool {
	for g in given { if g.name == name { return true } }
	return false
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
