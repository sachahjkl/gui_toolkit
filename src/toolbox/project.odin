package tk_toolbox

// What a program's project is to its tool: its name, where it keeps its version, the toolkit's checkout it builds with. The
// tool's commands build their odin commands from it, and the standard commands (changelog.command, release.commands,
// site.command, notices_command) read it.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "../platform"

// What a program of the toolkit links on Linux: the native text backend and wgpu-native both carry Rust's standard
// library, whose few unmangled symbols are the same code.
LINUX_LINK_FLAG :: "-extra-linker-flags:-Wl,--allow-multiple-definition"
// The toolkit's checkout in a program's, and the variable that names another one (its root, not its src).
TOOLKIT_DEFAULT :: "ext/gui_toolkit"
TOOLKIT_ENV     :: "GT"
// What a project's tool looks for to find the project's root (tool_main's root_mark).
ROOT_MARK_DEFAULT :: "odin.version"

Project :: struct {
	name:          string,        // the program ("classeur"): its archive's, its commit's, the launcher's answer
	repository:    string,        // https://github.com/<owner>/<repo>
	changelog:     string,        // "CHANGELOG.md" ("": that), its fragments in changelog.d/ beside it
	version_file:  string,        // the source that holds the version ("src/main.odin")
	version_line:  string,        // the start of its line ("APP_VERSION :: "), the version in quotes after it
	program:       string,        // the release build ("build/classeur", "build/classeur.exe")
	src:           string,        // the program's package ("": "src")
	toolkit:       string,        // the toolkit's checkout ("": $GT, else TOOLKIT_DEFAULT)
	collections:   [][2]string,   // more collections than gt: a name and its folder
	linux_defines: []string,      // what every odin command of the program gets on Linux ("-define:FONT_BACKEND=native")
	launcher:      Launcher,      // Windows: the rules of its console launcher, <name>.com beside the program
	licence:       string,        // the program's licence, for its notices ("": "MIT")
	features:      Features,      // what it takes of the toolkit beyond the core: its defines, native builds and crates

	// What Windows shows of the program: its resource (windows_resource.odin) and the group of its windows.
	title:         string,        // the program as people read it ("Papier"; "": name): the file's description, which
	                              // Task Manager shows, and the product's name
	description:   string,        // one line, what it does (the file's comments; "": none)
	publisher:     string,        // "Froment Software": the company's name ("": none)
	copyright:     string,        // "Copyright (c) 2026 Froment Software" ("": none)
	icon:          string,        // the .ico ("": "assets/<name>.ico"): the file's, the shortcuts' and every window's
	// (the AppUserModelID is not written: project_aumid derives it from the publisher and the title, as gt:desktop's
	// Identity does from its vendor and its name)
}

// What a program takes of the toolkit beyond its core, declared once in its Project: each gives the program's odin
// commands their defines (feature_defines), build_native its steps and the notices their crates (native_crates).
Feature :: enum u8 {
	Native_Text,        // the native text backend on Windows too (FONT_BACKEND=native); elsewhere it is the only one
	Accessibility,      // Windows: screen readers through AccessKit (A11Y_ACCESSKIT=true, native/a11y)
	Mermaid,            // Mermaid diagrams (gt:mermaid, native/mermaid)
	Devtools,           // the CDP endpoint in a release build too (TOOLKIT_DEVTOOLS=true); a -debug build has it anyway
	Lucide_Subset,      // only the Lucide icons the sources name are compiled in (lucide_subset, LUCIDE_SUBSET)
	No_Fallback_Fonts,  // no Roboto or Inconsolata compiled in (FONT_EMBED_FALLBACK=false): the system's fonts only
	Webp,               // Windows: WebP read and written (gt_webp.dll, native/webp, built and put beside the program; the
	                    // package and the setup take it with it). Elsewhere the system's libwebp
}
Features :: bit_set[Feature; u8]

// The rules of a program's console launcher (the toolkit's tools/console_launcher). Every program with a window has one
// on Windows: launcher_path(p), its mark launcher_mark(p).
Launcher :: struct {
	default_rule:  string,   // LAUNCHER_DEFAULT: "wait" or "detach" ("": "detach", a command line opens a window)
	others:        string,   // LAUNCHER_OTHERS: the comma-separated commands that do the other ("": LAUNCHER_OTHERS_DEFAULT)
	refuses_exit:  int,      // check_launcher: the exit code of an unknown command, given through (0: not tried, a program
	                         // whose unknown word opens a window)
}

// What waits for a program whose command line opens a window: gt:cli's help and version, which print.
LAUNCHER_OTHERS_DEFAULT :: "help,-h,--help,version,--version"

// The AppUserModelID of the program's windows: its publisher and its title (else its name) in PascalCase ("Froment
// Software", "opencode native": "FromentSoftware.OpencodeNative"; platform.app_user_model_id). gt:desktop's Identity
// derives the same from its vendor and its name, so the taskbar groups the windows with the shortcuts with no string
// written twice. "" without a publisher: an example or a tool, which the taskbar groups by its executable.
project_aumid :: proc(p: Project) -> string {
	if p.publisher == "" { return "" }
	return platform.app_user_model_id(p.publisher, p.title != "" ? p.title : p.name)
}

// The console launcher of the program: <name>.com beside its build ("build/classeur.com").
launcher_path :: proc(p: Project) -> string { return fmt.tprintf("%s/%s.com", dir_of(p.program), p.name) }

// What the launcher carries, by which desktop.install tells it from another file: "(<name> console launcher)". Installed
// launchers carry it: a program keeps its name.
launcher_mark :: proc(p: Project) -> string { return fmt.tprintf("(%s console launcher)", p.name) }

// The version of the sources: the value in quotes after `line` ("" when the line is not there).
version_of :: proc(source, line: string) -> string {
	rest := source
	for l in strings.split_lines_iterator(&rest) {
		if !strings.has_prefix(l, line) { continue }
		v := strings.trim_space(l[len(line):])
		if len(v) >= 2 && v[0] == '"' {
			if end := strings.index_byte(v[1:], '"'); end >= 0 { return v[1:end + 1] }
		}
	}
	return ""
}

// The sources with the version set to `version`; ok = false when the line is not there.
version_set :: proc(source, line, version: string, allocator := context.temp_allocator) -> (out: string, ok: bool) {
	old := version_of(source, line)
	if old == "" { return "", false }
	from := fmt.tprintf("%s\"%s\"", line, old)
	to := fmt.tprintf("%s\"%s\"", line, version)
	out, _ = strings.replace(source, from, to, 1, allocator)
	return out, out != source || old == version
}

// The version the project's sources say ("" when it cannot be read).
project_version :: proc(p: Project) -> string {
	source, err := os.read_entire_file(p.version_file, context.temp_allocator)
	return err == nil ? version_of(string(source), p.version_line) : ""
}

// The toolkit's checkout: Project.toolkit, else $GT, else TOOLKIT_DEFAULT.
toolkit_dir :: proc(p: Project) -> string {
	if p.toolkit != "" { return p.toolkit }
	if v := os.get_env(TOOLKIT_ENV, context.temp_allocator); v != "" { return v }
	return TOOLKIT_DEFAULT
}

// The flags every odin command of the project gets: the collections and -vet.
@(private = "file")
collection_flags :: proc(p: Project, out: ^[dynamic]string) {
	append(out, fmt.tprintf("-collection:gt=%s/src", toolkit_dir(p)))
	for c in p.collections { append(out, fmt.tprintf("-collection:%s=%s", c[0], c[1])) }
	append(out, "-vet")
}

// `odin <verb> <package> <collections> -vet`, the defines of the project's features (feature_defines), on Windows the
// program's own (windows_flags), on Linux the project's defines and (but for check, which links nothing)
// LINUX_LINK_FLAG, then `extra`. `pkg` "": the program's.
odin_command :: proc(p: Project, verb: string, pkg := "", extra: []string = nil) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "odin", verb, pkg != "" ? pkg : project_src(p))
	collection_flags(p, &cmd)
	append(&cmd, ..feature_defines(p.features, ODIN_OS, verb != "check" ? lucide_subset_path() : ""))
	system_odin_flags(p, verb, pkg, &cmd)   // (project_windows.odin, project_linux.odin, project_other.odin)
	// (the tests say a call that waits on the system in a frame: a session's test fails for it, testkit/session)
	if verb == "test" { append(&cmd, "-define:TOOLKIT_BLOCKING_CHECK=true") }
	append(&cmd, ..extra)
	return cmd[:]
}

// What an odin command of the program gets on Windows from what build_windows made: the console launcher it embeds
// (-define:GT_CONSOLE_LAUNCHER=<file>, GT_CONSOLE_LAUNCHER_MARK: desktop.install writes it beside the program with the
// PATH entry), the AppUserModelID of its windows (GT_AUMID) and, for the program's executable (`linked`), its resource.
// A file not made yet is not given: a check from Linux has none, and builds without them. For a tool that builds the
// program with its own odin command (opencode native's).
windows_flags :: proc(p: Project, linked: bool) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if launcher := absolute_slashed(launcher_path(p)); launcher != "" {
		append(&out, fmt.tprintf("-define:GT_CONSOLE_LAUNCHER=%s", launcher), fmt.tprintf("-define:GT_CONSOLE_LAUNCHER_MARK=%s", launcher_mark(p)))
	}
	if aumid := project_aumid(p); aumid != "" { append(&out, fmt.tprintf("-define:GT_AUMID=%s", aumid)) }
	if linked && os.exists(windows_resource_path(p)) { append(&out, fmt.tprintf("-resource:%s", windows_resource_path(p))) }
	return out[:]
}

// The defines `features` give a program built for `target`. lucide: the subset's absolute path ("": none given, the
// whole font: a check reads no font, and builds before build_native made it).
feature_defines :: proc(features: Features, target: runtime.Odin_OS_Type, lucide: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if .Native_Text in features && target == .Windows { append(&out, "-define:FONT_BACKEND=native") }
	if .Accessibility in features && target == .Windows { append(&out, "-define:A11Y_ACCESSKIT=true") }
	if .Devtools in features { append(&out, "-define:TOOLKIT_DEVTOOLS=true") }
	if .Lucide_Subset in features && lucide != "" { append(&out, fmt.tprintf("-define:LUCIDE_SUBSET=%s", lucide)) }
	if .No_Fallback_Fonts in features { append(&out, "-define:FONT_EMBED_FALLBACK=false") }
	return out[:]
}

// The absolute path of LUCIDE_SUBSET_FILE, with forward slashes ("": it is not there yet).
@(private)
lucide_subset_path :: proc() -> string { return absolute_slashed(LUCIDE_SUBSET_FILE) }

// The absolute path of a file, with forward slashes, for a #load in a define ("": it is not there yet).
@(private)
absolute_slashed :: proc(path: string) -> string {
	if !os.exists(path) { return "" }
	abs, err := os.get_absolute_path(path, context.temp_allocator)
	if err != nil { return "" }
	slashed, _ := strings.replace_all(abs, "\\", "/", context.temp_allocator)
	return slashed
}

// The toolkit's crates a program of `features` links, for its notices: the native text backend's always (it is the text
// on Linux), and those of its features.
native_crates :: proc(features: Features) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "native/text")
	if .Accessibility in features { append(&out, "native/a11y") }
	if .Mermaid in features { append(&out, "native/mermaid") }
	if .Webp in features { append(&out, "native/webp") }
	return out[:]
}

@(private)
project_src :: proc(p: Project) -> string { return p.src != "" ? p.src : "src" }

// What the program needs built before an odin command of it: on Windows its resource and console launcher
// (build_windows); the toolkit's native libraries this system links (the text backend on Linux, or with Native_Text;
// AccessKit on Windows; Mermaid), each by the toolkit's own tool in the project's checkout of it (nothing when it is up
// to date), and the Lucide subset (lucide_subset).
build_native :: proc(p: Project) -> bool {
	if !build_windows(p) { return false }
	gt := toolkit_dir(p)
	steps := make([dynamic]string, context.temp_allocator)
	system_native_steps(p, &steps)   // (project_windows.odin, project_other.odin)
	if .Mermaid in p.features { append(&steps, "build_mermaid") }
	if len(steps) > 0 {
		_ = os.make_directory_all(fmt.tprintf("%s/build", gt))   // (a fresh checkout has none: the linker writes tk there)
		root, err := os.get_absolute_path(gt, context.temp_allocator)
		if err != nil { fmt.eprintfln("%s: no such folder", gt); return false }
		tk := fmt.tprintf("%s/build/tk%s", root, EXE_SUFFIX)
		if !run({"odin", "build", "tools/tk", fmt.tprintf("-out:%s", tk)}, {dir = gt, echo = true}) { return false }
		for s in steps { if !run({tk, s}, {dir = gt, echo = true}) { return false } }
		if !system_after_native(p, root) { return false }
	}
	if .Lucide_Subset in p.features {
		if _, why := lucide_subset(p); why != "" { fmt.eprintln(why); return false }
	}
	return true
}

// `odin check` of the program for Windows, from any system (odin_check: from Linux, on an Odin root whose wgpu needs
// no Windows library).
check_windows :: proc(p: Project) -> bool { return check_other(p, "windows_amd64") }

// `odin check` of the program for macOS (arm64), from any system.
check_darwin :: proc(p: Project) -> bool { return check_other(p, "darwin_arm64") }

@(private = "file")
check_other :: proc(p: Project, target: string) -> bool {
	extra := make([dynamic]string, context.temp_allocator)
	collection_flags(p, &extra)
	ordered_remove(&extra, len(extra) - 1)   // (odin_check passes -vet itself)
	return odin_check(project_src(p), target, extra[:], o = {echo = true})
}

@(private)
dir_of :: proc(path: string) -> string {
	i := strings.last_index_any(path, "/\\")
	return i > 0 ? path[:i] : "."
}
