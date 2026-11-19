package tk_toolbox

import "core:fmt"
import "core:os"
import "core:strings"

// What an executable's file name ends with.
EXE_SUFFIX :: ".exe"

// What every program gets from its Project before a build, the same for all: its resource (write_windows_resource:
// icon, version, manifest) and its console launcher (build_launcher). odin_command gives them to the program
// (windows_flags).
build_windows :: proc(p: Project) -> bool {
	if why := write_windows_resource(p); why != "" { fmt.eprintfln("%s: %s", p.name, why); return false }
	return build_launcher(p)
}

// The program's console launcher, launcher_path(p), built from the toolkit's tools/console_launcher with the rules of
// Project.launcher, unless the stamp beside it (<launcher>.stamp) says it is made of these sources and rules; the
// program embeds it, so it comes before a check or a build.
build_launcher :: proc(p: Project) -> bool {
	l, out, gt := p.launcher, launcher_path(p), toolkit_dir(p)
	rule := l.default_rule != "" ? l.default_rule : "detach"
	others := l.others != "" ? l.others : LAUNCHER_OTHERS_DEFAULT
	cmd := []string{"odin", "build", fmt.tprintf("%s/tools/console_launcher", gt), "-vet", "-subsystem:console", "-o:size",
		fmt.tprintf("-out:%s", out), fmt.tprintf("-define:LAUNCHER_MARK=%s", launcher_mark(p)), fmt.tprintf("-define:LAUNCHER_DEFAULT=%s", rule),
		fmt.tprintf("-define:LAUNCHER_OTHERS=%s", others)}
	sources := make([dynamic]string, context.temp_allocator)
	for dir in ([]string{fmt.tprintf("%s/tools/console_launcher", gt), fmt.tprintf("%s/src/console_launcher", gt)}) {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries { if strings.has_suffix(e.name, ".odin") { append(&sources, e.fullpath) } }
	}
	// (in one order whatever the folder's: the same sources, the same stamp)
	for i in 1 ..< len(sources) {
		for j := i; j > 0 && sources[j] < sources[j - 1]; j -= 1 { sources[j], sources[j - 1] = sources[j - 1], sources[j] }
	}
	stamp, ok := c_lib_stamp(sources[:], cmd)
	stamp_file := fmt.tprintf("%s.stamp", out)
	if ok && stamp_holds(out, stamp_file, stamp) { return true }
	_ = os.make_directory_all(dir_of(out))
	if !run(cmd, {echo = true}) { return false }
	if ok { _ = write_stamp(stamp_file, stamp) }
	return true
}

// Beside a release build: the executable carries its icon (resource 1, exe_has_icon), and the launcher gives the
// program's output and exit code through: `<launcher> --version` says "<name> <version>", and an unknown command ends
// with Launcher.refuses_exit when it is set.
check_launcher :: proc(p: Project) -> bool {
	// (a full path with backslashes, as LoadLibraryEx asks)
	exe, _ := os.get_absolute_path(p.program, context.temp_allocator)
	exe, _ = strings.replace_all(exe, "/", "\\", context.temp_allocator)
	if !exe_has_icon(exe) { fmt.eprintfln("%s has no icon (resource 1 of %s)", p.program, windows_resource_path(p)); return false }
	l, launcher := p.launcher, launcher_path(p)
	// (--version, not `version`: gt:cli's form, the one every program answers; a bare word is a program's own command)
	out, code := capture({launcher, "--version"})
	want := fmt.tprintf("%s %s", p.name, project_version(p))
	if code != 0 || strings.trim_space(out) != want {
		fmt.eprintfln("%s --version gave %q (exit code %d), not %q", launcher, strings.trim_space(out), code, want)
		return false
	}
	if l.refuses_exit != 0 {
		_, bad := capture({launcher, "no-such-command"})
		if bad != l.refuses_exit { fmt.eprintfln("%s no-such-command ended with %d, not %d", launcher, bad, l.refuses_exit); return false }
	}
	fmt.printfln("%s: its icon; %s: the program's output and exit code", p.program, launcher)
	return true
}

// The options of `odin` that this system adds: the resource, the launcher, the AppUserModelID (windows_flags).
@(private)
system_odin_flags :: proc(p: Project, verb, pkg: string, cmd: ^[dynamic]string) {
	append(cmd, ..windows_flags(p, (verb == "build" || verb == "run") && pkg == ""))
}
