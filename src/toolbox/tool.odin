package tk_toolbox

// A project's tool: one program, a list of commands, the same on every system and shell. tool_main reads the line, finds the
// command and ends with its exit code; tools/tk and every program's tool use it, each with its own commands.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// Exit codes of a tool: the work is done, it failed, the line is not one the tool understands.
EXIT_DONE   :: 0
EXIT_FAILED :: 1
EXIT_USAGE  :: 2

// A command of a tool.
Command :: struct {
	name:        string,
	usage:       string,                                   // its arguments and what it does, one line, for help
	run:         proc(args: []string) -> int,              // the arguments after its name; the exit code
	run_with:    proc(args: []string, user: rawptr) -> int, // instead of run: a command made for a project (changelog.command...)
	user:        rawptr,                                   // what run_with gets
	checked:     bool,                                     // the line is checked against flags and positionals before run
	flags:       []string,                                 // checked: "name" a switch (-name), "name:" a flag with a value (-name:value)
	positionals: int,                                      // checked: how many plain arguments (-1: none or one)
}

// The command and the tool that run now, for done (one dispatch per process).
@(private = "file") running_program: string
@(private = "file") running_command: string

// The tool's main: the line read (args_joined), the project's root found by `root_mark` and made the working directory
// ("": the working directory stays), the command run; the process ends with its exit code. `help`, `-h`, `--help` or no
// command: the commands listed, 0. A command it does not know: refused, 2.
tool_main :: proc(program: string, commands: []Command, root_mark := "") {
	if root_mark != "" {
		cwd, _ := os.get_working_directory(context.temp_allocator)
		root, found := project_root(cwd, root_mark)
		if !found { fmt.eprintfln("%s: not in the project (no %s here or above)", program, root_mark); os.exit(EXIT_USAGE) }
		if os.set_working_directory(root) != nil { fmt.eprintfln("%s: cannot work in %s", program, root); os.exit(EXIT_USAGE) }
	}
	os.exit(dispatch(program, commands, args_joined(os.args[1:], context.temp_allocator)))
}

// Runs the command `args[0]` with the rest: its exit code. The help and the refusals of tool_main, without the process's end.
dispatch :: proc(program: string, commands: []Command, args: []string) -> int {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		if len(args) == 2 {
			if c, ok := command_find(commands, args[1]); ok { fmt.printfln("%s %s %s", program, c.name, c.usage); return EXIT_DONE }
		}
		fmt.print(tool_usage(program, commands))
		return EXIT_DONE
	}
	c, found := command_find(commands, args[0])
	if !found {
		fmt.eprintfln("%s: no command %s", program, args[0])
		fmt.eprint(tool_usage(program, commands))
		return EXIT_USAGE
	}
	rest := args[1:]
	if why := args_check(c, rest); why != "" {
		fmt.eprintfln("%s %s: %s", program, c.name, why)
		fmt.eprintfln("  %s %s %s", program, c.name, c.usage)
		return EXIT_USAGE
	}
	running_program, running_command = program, c.name
	defer running_program, running_command = "", ""
	if c.run_with != nil { return c.run_with(rest, c.user) }
	if c.run != nil { return c.run(rest) }
	return EXIT_FAILED
}

// The command of that name.
command_find :: proc(commands: []Command, name: string) -> (c: Command, ok: bool) {
	for x in commands { if x.name == name { return x, true } }
	return {}, false
}

// The help: the tool's line, then each command and its usage, the usages in one column.
tool_usage :: proc(program: string, commands: []Command, allocator := context.temp_allocator) -> string {
	width := 0
	for c in commands { width = max(width, len(c.name)) }
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "%s <command> [arguments]", program)
	for c in commands { fmt.sbprintfln(&b, "  %-*s  %s", width, c.name, c.usage) }
	return strings.to_string(b)
}

// The exit code of a command whose work says why it failed ("": done), the failure said as "<tool> <command>: why".
done :: proc(why: string) -> int {
	if why == "" { return EXIT_DONE }
	if running_command != "" { fmt.eprintfln("%s %s: %s", running_program, running_command, why) } else { fmt.eprintln(why) }
	return EXIT_FAILED
}

// Whether `args` are a line the command takes ("": they are, else why not). A command not `checked` takes any.
args_check :: proc(c: Command, args: []string) -> (why: string) {
	if !c.checked { return "" }
	plain := 0
	for arg in args {
		if !is_flag(arg) { plain += 1; continue }
		name, _, has_value := flag_split(arg)
		spelled := has_value ? fmt.tprintf("%s:", name) : name
		known := false
		for f in c.flags { known ||= f == spelled }
		if !known { return fmt.tprintf("no flag -%s", spelled) }
	}
	if c.positionals >= 0 && plain != c.positionals { return fmt.tprintf("%d plain arguments, not %d", c.positionals, plain) }
	if c.positionals < 0 && plain > 1 { return fmt.tprintf("one plain argument at most, not %d", plain) }
	return ""
}

// The plain arguments: those that are not flags.
plain_args :: proc(args: []string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(args), allocator)
	for a in args { if !is_flag(a) { append(&out, a) } }
	return out[:]
}

// Whether the flag -name (or -name:value) is given.
has_flag :: proc(args: []string, name: string) -> bool {
	for a in args {
		if !is_flag(a) { continue }
		if n, _, _ := flag_split(a); n == name { return true }
	}
	return false
}

// The value of -name:value, or `default` when it is not given (the last one given wins).
flag_value :: proc(args: []string, name: string, default := "") -> string {
	v := default
	for a in args {
		if !is_flag(a) { continue }
		if n, value, _ := flag_split(a); n == name { v = value }
	}
	return v
}

// The whole number of -name:n, or `default` when it is not given; why: it is not a whole number.
int_flag :: proc(args: []string, name: string, default: int) -> (n: int, why: string) {
	if !has_flag(args, name) { return default, "" }
	v, ok := strconv.parse_int(flag_value(args, name))
	return v, ok ? "" : fmt.tprintf("-%s: not a whole number", name)
}

// The number of -name:x, or `default` when it is not given; why: it is not a number.
f64_flag :: proc(args: []string, name: string, default: f64) -> (x: f64, why: string) {
	if !has_flag(args, name) { return default, "" }
	v, ok := strconv.parse_f64(flag_value(args, name))
	return v, ok ? "" : fmt.tprintf("-%s: not a number", name)
}

// The line as it was typed. PowerShell 7 passes `-name:value` to a program as two arguments, `-name:` and `value`, once a
// `--` came before it on the line (`odin run tools/run_tests -- -backend:wgpu`; odin passes on what it gets): each `-name:`
// followed by a value is joined back into `-name:value` (allocated when joined).
args_joined :: proc(given: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(given), allocator)
	for i := 0; i < len(given); i += 1 {
		a := given[i]
		if len(a) > 2 && a[0] == '-' && a[len(a) - 1] == ':' && i + 1 < len(given) {
			a = strings.concatenate({a, given[i + 1]}, allocator)
			i += 1
		}
		append(&out, a)
	}
	return out[:]
}

// The folder of the project: `start` or the first folder above it that holds `mark` (a file or a folder).
project_root :: proc(start, mark: string, allocator := context.temp_allocator) -> (root: string, found: bool) {
	dir, _ := filepath.abs(start, context.temp_allocator)
	for {
		if os.exists(fmt.tprintf("%s/%s", dir, mark)) { return strings.clone(dir, allocator), true }
		parent := os.dir(dir)
		if parent == dir || parent == "" || parent == "." { return "", false }
		dir = parent
	}
}

// (a lone "-" is a plain argument: the standard input, by custom)
@(private = "file")
is_flag :: proc(a: string) -> bool { return len(a) >= 2 && a[0] == '-' }

@(private = "file")
flag_split :: proc(a: string) -> (name, value: string, has_value: bool) {
	name = a[1:]
	if colon := strings.index_byte(name, ':'); colon >= 0 { return name[:colon], name[colon + 1:], true }
	return name, "", false
}
