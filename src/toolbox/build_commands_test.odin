package tk_toolbox

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import testkit "../testkit"

@(private = "file")
sample_options :: proc() -> Build_Options {
	return {project = {name = "sample", program = "build/sample", version_file = "src/main.odin", version_line = "APP_VERSION :: "}}
}

// Every program's check has the other systems, the tests, a release build and, on Windows, its launcher: the drift the
// five copies had (no macOS, no launcher) cannot come back through options.
@(test)
check_steps_have_every_system :: proc(t: ^testing.T) {
	o := sample_options()
	always := Check_Steps{.Changelog, .Scopes, .Flake_Toolkit, .Odin_Check, .Tool, .Tests, .Release_Build}
	linux := check_steps(o, .Linux)
	testing.expect_value(t, linux, always + Check_Steps{.Check_Windows, .Check_Darwin})
	testing.expect_value(t, check_steps(o, .Darwin), always + Check_Steps{.Check_Windows})
	testing.expect_value(t, check_steps(o, .Windows), always + Check_Steps{.Launcher})
}

// Project.systems: another system is checked only when the program is built for it; empty is every system of before.
@(test)
check_steps_follow_the_systems :: proc(t: ^testing.T) {
	o := sample_options()
	testing.expect_value(t, project_systems(o.project), SYSTEMS_DEFAULT)
	o.systems = {.Windows, .Linux}
	testing.expect(t, .Check_Windows in check_steps(o, .Linux) && .Check_Darwin not_in check_steps(o, .Linux), "no macOS: no check of it")
	testing.expect(t, .Launcher in check_steps(o, .Windows) && .Check_Windows not_in check_steps(o, .Windows))
	o.systems = {.Linux}
	others := Check_Steps{.Check_Windows, .Check_Darwin}
	testing.expect(t, check_steps(o, .Linux) & others == Check_Steps{}, "Linux alone: no other system")
	o.systems = {.Linux, .Darwin}
	testing.expect(t, .Check_Darwin in check_steps(o, .Linux) && .Check_Windows not_in check_steps(o, .Linux))
	testing.expect(t, check_steps(o, .Darwin) & others == Check_Steps{}, "from macOS: itself is Odin_Check")
}

// The parts of the toolkit's native library for each system and each feature; none when the program's own library
// carries them, and build_native then builds only what is not Rust (the resource, the launcher, the Lucide subset).
@(test)
native_parts_per_option :: proc(t: ^testing.T) {
	p := sample_options().project
	testing.expect(t, slice.equal(native_parts(p, .Linux), []string{"text"}), "Linux: the text backend always")
	testing.expect(t, slice.equal(native_parts(p, .Darwin), []string{"text"}))
	testing.expect_value(t, len(native_parts(p, .Windows)), 0)

	p.features = {.Native_Text, .Accessibility, .Mermaid, .Webp, .Pdf, .Filesearch, .Lucide_Subset}
	testing.expect(t, slice.equal(native_parts(p, .Windows), []string{"text", "a11y", "mermaid", "webp", "pdf", "filesearch"}))
	testing.expect(t, slice.equal(native_parts(p, .Linux), []string{"text", "mermaid", "webp", "pdf", "filesearch"}), "no AccessKit off Windows")

	// (opencode native: ocn_native links text and Mermaid itself)
	p.features = {.Mermaid, .Devtools, .Lucide_Subset}
	p.native_carried = true
	for target in ([]runtime.Odin_OS_Type{.Windows, .Linux, .Darwin}) {
		testing.expectf(t, len(native_parts(p, target)) == 0, "%v: nothing of the toolkit's library", target)
	}
	// (the defines stay the program's: the features give theirs as before)
	testing.expect(t, slice.equal(feature_defines(p.features, .Linux, ""), []string{"-define:TOOLKIT_DEVTOOLS=true"}))
}

// The options add their steps, and only theirs.
@(test)
check_steps_follow_the_options :: proc(t: ^testing.T) {
	o := sample_options()
	o.notices = true
	o.catalogues = {folder = "i18n"}
	checks := make([]Build_Check, 1, context.temp_allocator)
	checks[0] = proc(p: Project) -> bool { return true }
	o.checks = checks
	steps := check_steps(o, .Linux)
	testing.expect(t, Check_Steps{.Notices, .Catalogues, .Checks} <= steps, "the notices, the catalogues and the program's checks")
	// (the order is the enum's: the cheap checks before odin, the release build before the launcher)
	testing.expect(t, Check_Step.Changelog < .Odin_Check && Check_Step.Tests < .Release_Build && Check_Step.Release_Build < .Launcher)
}

// A debug build is the fastest (no optimisation), a dev build keeps Odin's modules (-o:minimal), a release is
// optimised; all go to the program's path. Only a debug build keeps a console on Windows.
@(test)
build_line_by_mode :: proc(t: ^testing.T) {
	o := sample_options()
	debug, dev, release := build_line(o, .Debug), build_line(o, .Dev), build_line(o, .Release)
	testing.expect(t, slice.contains(debug, "-debug") && slice.contains(debug, "-o:none") && !slice.contains(debug, "-o:speed"))
	testing.expect(t, slice.contains(dev, "-o:minimal") && !slice.contains(dev, "-debug") && !slice.contains(dev, "-o:none"))
	testing.expect(t, slice.contains(release, "-o:speed") && !slice.contains(release, "-debug"))
	for line in ([][]string{debug, dev, release}) {
		testing.expect(t, slice.contains(line, "-out:build/sample") && line[1] == "build" && line[2] == "src")
	}
	when ODIN_OS == .Windows {
		testing.expect(t, slice.contains(release, "-subsystem:windows") && slice.contains(dev, "-subsystem:windows"))
		testing.expect(t, !slice.contains(debug, "-subsystem:windows"))
	}
}

// The build with no word is Build_Options.iterate: a program that asks for Dev gets -o:minimal, the others -debug as
// before.
@(test)
build_iterate_is_the_default :: proc(t: ^testing.T) {
	o := sample_options()
	testing.expect_value(t, o.iterate, Build_Mode.Debug)
	testing.expect_value(t, build_mode_name(.Dev), "dev")
	testing.expect_value(t, build_mode_name(.Release), "release")
}

// A fresh build goes beside the program, under its name and -new, with the system's suffix; the old one waits as -old.
@(test)
build_line_fresh :: proc(t: ^testing.T) {
	o := sample_options()
	o.fresh = true
	line := build_line(o, .Release)
	testing.expect(t, slice.contains(line, "-out:build/sample-new" + EXE_SUFFIX) && !slice.contains(line, "-out:build/sample"))
	fresh, old := fresh_paths(o.project)
	testing.expect_value(t, fresh, "build/sample-new" + EXE_SUFFIX)
	testing.expect_value(t, old, "build/sample-old" + EXE_SUFFIX)
}

// The project's defines reach every odin command of the program, on every system: build, test and check.
@(test)
defines_on_every_command :: proc(t: ^testing.T) {
	o := sample_options()
	defines := [?]string{"-define:IMAGE_WEBP_NATIVE_LINK=false"}
	o.defines = defines[:]
	testing.expect(t, slice.contains(build_line(o, .Dev), defines[0]))
	testing.expect(t, slice.contains(odin_command(o.project, "check"), defines[0]))
	for line in test_lines(o) { testing.expect(t, slice.contains(line, defines[0])) }
	testing.expect(t, slice.contains(test_lines(o, "sample.test_a")[0], defines[0]))
}

// One linker flag per command, from every source (Odin keeps only the last one given); none for check; the options
// change nothing unless set.
@(test)
linker_flag_per_system :: proc(t: ^testing.T) {
	p := sample_options().project
	testing.expect_value(t, linker_flag(p, .Linux, "build", true), LINUX_LINK_FLAG)
	testing.expect_value(t, linker_flag(p, .Linux, "test", false), LINUX_LINK_FLAG)
	testing.expect_value(t, linker_flag(p, .Linux, "check", false), "")
	testing.expect_value(t, linker_flag(p, .Windows, "build", true), "")
	testing.expect_value(t, linker_flag(p, .Darwin, "build", true), "")

	p.link = {static_vcruntime = true, strip = true}
	testing.expect_value(t, linker_flag(p, .Linux, "build", true), LINUX_LINK_FLAG + " -s")
	testing.expect_value(t, linker_flag(p, .Linux, "build", false), LINUX_LINK_FLAG)
	testing.expect_value(t, linker_flag(p, .Windows, "build", false), "-extra-linker-flags:" + WINDOWS_STATIC_VCRUNTIME)
	testing.expect_value(t, linker_flag(p, .Windows, "test", false), "-extra-linker-flags:" + WINDOWS_STATIC_VCRUNTIME)
	testing.expect_value(t, linker_flag(p, .Windows, "check", false), "")
	testing.expect_value(t, linker_flag(p, .Darwin, "build", true), "")

	// (on this system, the build's line has that one flag and no other)
	o := sample_options()
	o.link = p.link
	count := 0
	for arg in build_line(o, .Release) {
		if strings.has_prefix(arg, "-extra-linker-flags:") { count += 1; testing.expect_value(t, arg, linker_flag(p, ODIN_OS, "build", true)) }
	}
	testing.expect_value(t, count, ODIN_OS == .Linux || ODIN_OS == .Windows ? 1 : 0)
}

// The found Odin holds the pinned one, its line end aside; else the reason names both and the way out.
@(test)
odin_pin :: proc(t: ^testing.T) {
	testing.expect_value(t, odin_pin_says("dev-2026-11a\n", "odin version dev-2026-11a:abcdef\n"), "")
	testing.expect_value(t, odin_pin_says("dev-2026-11", "odin version dev-2026-11a:abcdef"), "")
	why := odin_pin_says("dev-2026-11a", "odin version dev-2026-10:abcdef")
	testing.expect(t, strings.contains(why, "dev-2026-11a") && strings.contains(why, "dev-2026-10") && strings.contains(why, ANY_ODIN_ENV), why)
	testing.expect(t, odin_pin_says("", "odin version dev-2026-11a") != "", "an empty pin holds nothing")
}

// The mode file says the mode it was written with; a missing or foreign text is not known.
@(test)
build_mode_file :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "mode")
	program := fmt.tprintf("%s/sample", dir)
	_, known := build_mode_of(program)
	testing.expect(t, !known, "no mode file: not known")
	mode_file := fmt.tprintf("%s%s", program, MODE_SUFFIX)
	testing.expect(t, write_if_changed(mode_file, build_mode_name(.Release)))
	mode, k := build_mode_of(program)
	testing.expect(t, k && mode == .Release)
	testing.expect(t, write_if_changed(mode_file, "fast\n"))
	_, known = build_mode_of(program)
	testing.expect(t, !known, "a word that is no mode: not known")
}

// The fresh file takes the program's place, with or without a program there before; no fresh file: nothing moves.
@(test)
swap_in_replaces :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "swap")
	fresh, program, old := fmt.tprintf("%s/sample-new", dir), fmt.tprintf("%s/sample", dir), fmt.tprintf("%s/sample-old", dir)
	testing.expect(t, !swap_in(fresh, program, old), "no fresh build")

	testing.expect(t, write_if_changed(fresh, "one"))
	testing.expect(t, swap_in(fresh, program, old), "no program yet")
	testing.expect(t, write_if_changed(fresh, "two"))
	testing.expect(t, swap_in(fresh, program, old), "over a program")
	data, _ := os.read_entire_file(program, context.temp_allocator)
	testing.expect_value(t, string(data), "two")
	testing.expect(t, !os.exists(fresh) && !os.exists(old), "nothing left beside it")
}

// One test line per package; one_thread gives its defines; the tool is tested as a tool; names test the program alone.
@(test)
test_lines_per_package :: proc(t: ^testing.T) {
	o := sample_options()
	only := test_lines(o)
	testing.expect_value(t, len(only), 1)
	testing.expect(t, only[0][2] == "src" && slice.contains(only[0], "-out:build/test_src" + EXE_SUFFIX))

	tests := [?]Test_Package{{path = "src", one_thread = true}, {path = "src/fs"}, {path = "tools/sampletool"}}
	o.tests = tests[:]
	lines := test_lines(o)
	testing.expect_value(t, len(lines), 3)
	testing.expect(t, slice.contains(lines[0], "-define:ODIN_TEST_THREADS=1"), "one_thread: one thread")
	testing.expect(t, !slice.contains(lines[1], "-define:ODIN_TEST_THREADS=1") && slice.contains(lines[1], "-out:build/test_src_fs" + EXE_SUFFIX))
	tool := strings.join(lines[2], " ", context.temp_allocator)
	testing.expect(t, strings.has_prefix(tool, "odin test tools/sampletool -collection:gt="), tool)
	testing.expect(t, !strings.contains(tool, LINUX_LINK_FLAG) && !strings.contains(tool, "TOOLKIT_BLOCKING_CHECK"), "the tool links nothing native")

	named := test_lines(o, "sample.test_a,sample.test_b")
	testing.expect_value(t, len(named), 1)
	testing.expect(t, named[0][2] == "src" && slice.contains(named[0], "-define:ODIN_TEST_NAMES=sample.test_a,sample.test_b"))
	testing.expect(t, slice.contains(named[0], "-define:ODIN_TEST_THREADS=1"))
}

// The thumbnail provider: a DLL of the program's package beside the build, with the features' defines, optimised for a
// release; the program embeds it once it is there, and not without a thumbnailer.
@(test)
thumbnailer_build_and_define :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "thumbnailer")
	p := Project{name = "sample", program = fmt.tprintf("%s/sample%s", dir, EXE_SUFFIX), thumbnailer = "src/thumbnailer", features = {.Pdf}}
	testing.expect_value(t, thumbnailer_path(p), fmt.tprintf("%s/sample_thumbnails.dll", dir))
	debug, release := thumbnailer_command(p, false), thumbnailer_command(p, true)
	testing.expect(t, debug[1] == "build" && debug[2] == "src/thumbnailer", "its package, built")
	testing.expect(t, slice.contains(debug, "-build-mode:dll") && slice.contains(debug, fmt.tprintf("-out:%s/sample_thumbnails.dll", dir)))
	testing.expect(t, slice.contains(debug, "-define:GT_PDF=true"), "it renders as the program does")
	testing.expect(t, slice.contains(debug, "-o:none") && slice.contains(release, "-o:speed") && !slice.contains(release, "-debug"))
	testing.expect(t, !strings.contains(strings.join(debug, " ", context.temp_allocator), "GT_THUMBNAIL_DLL"), "the DLL embeds nothing")

	has_define :: proc(p: Project) -> bool {
		for f in windows_flags(p, false) { if strings.has_prefix(f, "-define:GT_THUMBNAIL_DLL=") { return true } }
		return false
	}
	testing.expect(t, !has_define(p), "not built yet: no define")
	testing.expect(t, os.write_entire_file(thumbnailer_path(p), "MZ") == nil)
	testing.expect(t, has_define(p), "built: embedded")
	p.thumbnailer = ""
	testing.expect(t, !has_define(p), "no thumbnailer: nothing embedded")
}

// The tool's package is tools/<name>tool unless named.
@(test)
tool_package_default :: proc(t: ^testing.T) {
	o := sample_options()
	testing.expect_value(t, tool_package(o), "tools/sampletool")
	o.tool = "tools/ocntools"
	testing.expect_value(t, tool_package(o), "tools/ocntools")
}

// A generated file is written with its folder, written again only when its text changes, and a stamp ends with this
// system's line end.
@(test)
write_if_changed_writes_once :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t, "write")
	path := fmt.tprintf("%s/deep/file.txt", dir)
	testing.expect(t, write_if_changed(path, "one"), "written, its folder made")
	testing.expect(t, write_if_changed(path, "one"), "the same text: nothing to write")
	testing.expect(t, write_if_changed(path, "two"))
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, string(data), "two")
	stamp := fmt.tprintf("%s/STAMP", dir)
	testing.expect(t, write_stamp(stamp, "abc") && stamp_holds(path, stamp, "abc"))
	data, _ = os.read_entire_file(stamp, context.temp_allocator)
	testing.expect_value(t, string(data), "abc" + STAMP_NEWLINE)
}

// The three commands, under their names, each with its options.
@(test)
build_commands_names :: proc(t: ^testing.T) {
	c := build_commands(sample_options())
	testing.expect(t, c[0].name == "build" && c[1].name == "test" && c[2].name == "check")
	for x in c { testing.expect(t, x.run_with != nil && x.user != nil && x.checked) }
	testing.expect_value(t, (^Build_Options)(c[2].user).name, "sample")
	free(c[0].user)
	delete(c[0].usage)
}
