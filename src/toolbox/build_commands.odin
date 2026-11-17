package tk_toolbox

// A program's build, test and check commands, from its Project and a Build_Options: the same steps in every program, on a
// laptop and in the CI (src/md/infrastructure/build-commands.md). The program gives only its own part.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import cli "../cli"

// Where the tests' executables go, and the folder odin is given for the program's.
BUILD_DIR :: "build"

// What a program's build, test and check are made of beyond its Project. Its slices and procedures must live as long as
// the tool: package arrays (a slice literal in a procedure lives on its stack).
Build_Options :: struct {
	using project:     Project,
	// the project's `changelog` command (changelog.command(project)): check runs its `check`, the fragments and the
	// roadmap (gt:changelog imports this package, which cannot call it)
	changelog_command: Command,
	tests:             []Test_Package,              // the test packages (nil: the program's package alone)
	tool:              string,                      // the tool's package ("": tools/<name>tool): checked, and tested when in tests
	catalogues:        I18n_Catalogues,             // the texts' catalogues (folder "": none); each <folder>/<language>.txt checked
	notices:           bool,                        // NOTICES_FILE checked up to date: a program that ships it
	prepare:           proc(p: Project) -> bool,    // after build_native, before an odin build or test: what the program builds itself
	checks:            []Build_Check,               // the program's own checks
}

// A program's own check: true when it holds; else it said why.
Build_Check :: proc(p: Project) -> bool

// A package with tests.
Test_Package :: struct {
	path:       string,   // "src/history"
	// its tests one after the other, each said as it starts: those that take the toolkit's one test session (the CI's
	// log names the test that hangs)
	one_thread: bool,
}

// A step of a program's check, in the order check runs them (cheapest first).
Check_Step :: enum u8 {
	Changelog,       // the fragments and the roadmap (Build_Options.changelog_command)
	Scopes,          // check_scopes of the program's package
	Checks,          // the program's own (Build_Options.checks)
	Catalogues,      // every catalogue of Build_Options.catalogues
	Notices,         // NOTICES_FILE up to date
	Odin_Check,      // odin check of the program for this system
	Check_Windows,   // the same for Windows, from another system
	Check_Darwin,    // the same for macOS, from another system
	Tool,            // odin check of the tool (-vet)
	Tests,           // program_test
	Release_Build,   // program_build, release
	Launcher,        // Windows: check_launcher of the release build
}
Check_Steps :: bit_set[Check_Step; u16]

// The `build`, `test` and `check` commands of a program's tool, over `o` (copied).
build_commands :: proc(o: Build_Options) -> [3]Command {
	kept := new_clone(o)
	return {
		{name = "build", usage = fmt.aprintf("[release]: what the program needs built first, then %s (release: optimised, what ships)", o.program),
			run_with = build_run, user = kept, checked = true, positionals = -1},
		{name = "test", usage = "[names]: the tests of the program, its packages and its tool (names, pkg.test_a,pkg.test_b: those tests of the program alone, in that order)",
			run_with = test_run, user = kept, checked = true, positionals = -1},
		{name = "check", usage = ": the changelog and the roadmap, the scopes, the program's own checks, the catalogues, the notices, odin check for this system and the others and of this tool (-vet), the tests, a release build, on Windows its launcher",
			run_with = check_run, user = kept, checked = true},
	}
}

@(private = "file")
build_run :: proc(args: []string, user: rawptr) -> cli.Exit {
	if len(args) > 0 && args[0] != "release" { fmt.eprintfln("build: %q is not release", args[0]); return .Usage }
	return ended(program_build((^Build_Options)(user)^, release = len(args) > 0))
}

@(private = "file")
test_run :: proc(args: []string, user: rawptr) -> cli.Exit {
	return ended(program_test((^Build_Options)(user)^, len(args) > 0 ? args[0] : ""))
}

@(private = "file")
check_run :: proc(args: []string, user: rawptr) -> cli.Exit { return ended(program_check((^Build_Options)(user)^)) }

// The program built: a debug build while iterating (no optimisation, the fastest), else a release. Each step says why it
// fails.
program_build :: proc(o: Build_Options, release := false) -> bool {
	if !program_prepare(o) { return false }
	if !run(build_line(o, release), {echo = true}) { return false }
	fmt.printfln("built %s%s", o.program, release ? " (release)" : "")
	return true
}

// The tests of every test package; `names` given ("pkg.test_a,pkg.test_b"): those tests of the program's package alone,
// in that order.
program_test :: proc(o: Build_Options, names := "") -> bool {
	if !program_prepare(o) { return false }
	for line in test_lines(o, names) {
		if !run(line, {echo = true}) { return false }
	}
	return true
}

// Every step of check_steps for this system, in order; the first that fails ends it.
program_check :: proc(o: Build_Options) -> bool {
	for step in check_steps(o, ODIN_OS) {
		if !check_step(o, step) { return false }
	}
	return true
}

// The steps of a program's check on `system`.
check_steps :: proc(o: Build_Options, system: runtime.Odin_OS_Type) -> Check_Steps {
	steps := Check_Steps{.Changelog, .Scopes, .Odin_Check, .Tool, .Tests, .Release_Build}
	if len(o.checks) > 0 { steps += {.Checks} }
	if o.catalogues.folder != "" { steps += {.Catalogues} }
	if o.notices { steps += {.Notices} }
	// (another system's check runs on an Odin root of links, odin_check: Windows makes none without privileges)
	if system != .Windows {
		steps += {.Check_Windows}
		if system != .Darwin { steps += {.Check_Darwin} }
	}
	// (only a Windows build has a launcher and a resource to check)
	if system == .Windows { steps += {.Launcher} }
	return steps
}

@(private = "file")
check_step :: proc(o: Build_Options, step: Check_Step) -> bool {
	p := o.project
	switch step {
	case .Changelog:
		c := o.changelog_command
		if c.run_with != nil { return c.run_with({"check"}, c.user) == .Done }
		if c.run != nil { return c.run({"check"}) == .Done }
		fmt.eprintln("check: no changelog command (Build_Options.changelog_command: changelog.command(project))")
		return false
	case .Scopes:
		return check_scopes(project_src(p))
	case .Checks:
		for c in o.checks {
			if !c(p) { return false }
		}
		return true
	case .Catalogues:
		return catalogues_check(o.catalogues)
	case .Notices:
		if why := third_party_notices(p, NOTICES_FILE, check_only = true); why != "" { fmt.eprintfln("check: %s", why); return false }
		return true
	case .Odin_Check:
		return run(odin_command(p, "check"), {echo = true})
	case .Check_Windows:
		return check_windows(p)
	case .Check_Darwin:
		return check_darwin(p)
	case .Tool:
		return run(tool_command(o, "check"), {echo = true})
	case .Tests:
		return program_test(o)
	case .Release_Build:
		return program_build(o, release = true)
	case .Launcher:
		return check_launcher(p)
	}
	return false
}

// Every <folder>/<language>.txt checked against the code: a language added to the folder is checked from then on.
@(private = "file")
catalogues_check :: proc(c: I18n_Catalogues) -> bool {
	entries, err := os.read_all_directory_by_path(c.folder, context.temp_allocator)
	if err != nil { fmt.eprintfln("check: %s cannot be read", c.folder); return false }
	files := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type != .Directory && strings.has_suffix(e.name, ".txt") { append(&files, e.name) }
	}
	if len(files) == 0 { fmt.eprintfln("check: no catalogue in %s", c.folder); return false }
	// (in one order whatever the folder's: the same output on every system)
	slice.sort(files[:])
	for name in files {
		if why := i18n_catalogue(c.dirs, fmt.tprintf("%s/%s", c.folder, name), strings.trim_suffix(name, ".txt"), check = true); why != "" {
			fmt.eprintln(why)
			return false
		}
	}
	return true
}

// build_native, the program's own part, the build folder: what an odin build or test of the program needs first.
@(private = "file")
program_prepare :: proc(o: Build_Options) -> bool {
	if !build_native(o.project) { return false }
	if o.prepare != nil && !o.prepare(o.project) { return false }
	// (odin makes no folder for its output)
	_ = os.make_directory_all(BUILD_DIR)
	_ = os.make_directory_all(dir_of(o.program))
	return true
}

// The odin command of the program's build.
@(private)
build_line :: proc(o: Build_Options, release: bool) -> []string {
	extra := make([dynamic]string, context.temp_allocator)
	append(&extra, fmt.tprintf("-out:%s", o.program))
	if release { append(&extra, "-o:speed") } else { append(&extra, "-debug", "-o:none") }
	// (no console of its own: a command line's text goes through the console launcher, <name>.com)
	if release && ODIN_OS == .Windows { append(&extra, "-subsystem:windows") }
	return odin_command(o.project, "build", "", extra[:])
}

// The odin commands of the tests, one per test package (names given: one, of the program's package).
@(private)
test_lines :: proc(o: Build_Options, names := "") -> [][]string {
	lines := make([dynamic][]string, context.temp_allocator)
	if names != "" {
		extra := make([dynamic]string, context.temp_allocator)
		append(&extra, fmt.tprintf("-out:%s/test_some%s", BUILD_DIR, EXE_SUFFIX), fmt.tprintf("-define:ODIN_TEST_NAMES=%s", names))
		one_thread_defines(&extra)
		append(&lines, odin_command(o.project, "test", "", extra[:]))
		return lines[:]
	}
	packages := o.tests
	if len(packages) == 0 { packages = []Test_Package{{path = project_src(o.project)}} }
	for t in packages {
		name, _ := strings.replace_all(t.path, "/", "_", context.temp_allocator)
		extra := make([dynamic]string, context.temp_allocator)
		append(&extra, fmt.tprintf("-out:%s/test_%s%s", BUILD_DIR, name, EXE_SUFFIX))
		if t.one_thread { one_thread_defines(&extra) }
		append(&lines, t.path == tool_package(o) ? tool_command(o, "test", extra[:]) : odin_command(o.project, "test", t.path, extra[:]))
	}
	return lines[:]
}

@(private = "file")
one_thread_defines :: proc(extra: ^[dynamic]string) {
	append(extra, "-define:ODIN_TEST_THREADS=1", "-define:ODIN_TEST_LOG_STATE_CHANGES=true")
}

// The tool's package: Build_Options.tool, else tools/<name>tool.
@(private)
tool_package :: proc(o: Build_Options) -> string { return o.tool != "" ? o.tool : fmt.tprintf("tools/%stool", o.name) }

// An odin command of the tool: the collections and -vet alone (it links no native library, takes no define of the
// program's).
@(private)
tool_command :: proc(o: Build_Options, verb: string, extra: []string = nil) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, tool_package(o))
	collection_flags(o.project, &cmd)
	append(&cmd, ..extra)
	return cmd[:]
}
