package tk_toolbox

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
	always := Check_Steps{.Changelog, .Scopes, .Odin_Check, .Tool, .Tests, .Release_Build}
	linux := check_steps(o, .Linux)
	testing.expect_value(t, linux, always + Check_Steps{.Check_Windows, .Check_Darwin})
	testing.expect_value(t, check_steps(o, .Darwin), always + Check_Steps{.Check_Windows})
	testing.expect_value(t, check_steps(o, .Windows), always + Check_Steps{.Launcher})
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

// A debug build is the fastest (no optimisation), a release is optimised; both go to the program's path.
@(test)
build_line_by_mode :: proc(t: ^testing.T) {
	o := sample_options()
	debug, release := build_line(o, false), build_line(o, true)
	testing.expect(t, slice.contains(debug, "-debug") && slice.contains(debug, "-o:none") && !slice.contains(debug, "-o:speed"))
	testing.expect(t, slice.contains(release, "-o:speed") && !slice.contains(release, "-debug"))
	testing.expect(t, slice.contains(release, "-out:build/sample") && release[1] == "build" && release[2] == "src")
	when ODIN_OS == .Windows {
		testing.expect(t, slice.contains(release, "-subsystem:windows") && !slice.contains(debug, "-subsystem:windows"))
	}
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
