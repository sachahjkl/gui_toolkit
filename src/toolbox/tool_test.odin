package tk_toolbox

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:testing"

// A new empty folder of this test's, removed at its end.
@(private = "file")
scratch :: proc(t: ^testing.T, name: string) -> string {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, _ := filepath.join({base, fmt.tprintf("tk_toolbox_tool_%s_%d", name, os.get_pid())}, context.temp_allocator)
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil, "a scratch folder")
	return dir
}

@(private = "file") seen_args: int
@(private = "file") seen_user: rawptr

@(private = "file")
SAMPLE_COMMANDS := [?]Command{
	{name = "build", usage = "[release]: the program", run = proc(args: []string) -> int { seen_args = len(args); return 0 }},
	{name = "fail", usage = ": fails", run = proc(args: []string) -> int { return done("it broke") }},
	{name = "fetch", usage = "[-dest:dir] [-force] <what>", checked = true, flags = {"dest:", "force"}, positionals = 1, run = proc(args: []string) -> int { return 0 }},
	{name = "one", usage = "[x]", checked = true, positionals = -1, run = proc(args: []string) -> int { return 0 }},
	{name = "with", usage = ": its user", run_with = proc(args: []string, user: rawptr) -> int { seen_user = user; return 7 }, user = &seen_args},
}

// The exit codes of a tool: the command's own, 0 for the help, 2 for a command it does not know or a line the command
// does not take; a command made for a project gets its user.
@(test)
the_dispatcher_runs_the_command_and_says_its_code :: proc(t: ^testing.T) {
	cs := SAMPLE_COMMANDS[:]
	testing.expect_value(t, dispatch("sampletool", cs, {"build", "release", "x"}), 0)
	testing.expect_value(t, seen_args, 2)
	testing.expect_value(t, dispatch("sampletool", cs, {"fail"}), 1)
	testing.expect_value(t, dispatch("sampletool", cs, {}), 0)
	testing.expect_value(t, dispatch("sampletool", cs, {"help"}), 0)
	testing.expect_value(t, dispatch("sampletool", cs, {"--help"}), 0)
	testing.expect_value(t, dispatch("sampletool", cs, {"help", "fetch"}), 0)
	testing.expect_value(t, dispatch("sampletool", cs, {"deploy"}), 2)
	testing.expect_value(t, dispatch("sampletool", cs, {"with"}), 7)
	testing.expect(t, seen_user == rawptr(&seen_args), "run_with gets its user")
	testing.expect_value(t, dispatch("sampletool", cs, {"fetch", "-dest:x", "-force", "emoji"}), 0)
	refused := [][]string{
		{"fetch", "emoji", "-Force"},         // the flags are the lower case ones
		{"fetch", "emoji", "-force:yes"},     // a switch takes no value
		{"fetch", "emoji", "-dest"},          // ... and a value flag needs its colon
		{"fetch"},                            // its one plain argument
		{"fetch", "a", "b"},
		{"one", "a", "b"},                    // one at most
	}
	for r in refused { testing.expectf(t, dispatch("sampletool", cs, r) == 2, "%v is refused", r) }
	testing.expect_value(t, dispatch("sampletool", cs, {"one"}), 0)
	usage := tool_usage("sampletool", cs)
	testing.expect(t, strings.has_prefix(usage, "sampletool <command> [arguments]\n") && strings.contains(usage, "  fetch  [-dest:dir]"), usage)
}

// The flags of a line: -name and -name:value, the last one given winning; the plain arguments are the others.
@(test)
the_flags_of_a_line_are_read :: proc(t: ^testing.T) {
	args := []string{"a.ppm", "-tolerance:5", "-", "b.ppm", "-dest:x", "-dest:y", "-no-dxc", "-scale:1.5", "-size:big"}
	testing.expect(t, slice.equal(plain_args(args), []string{"a.ppm", "-", "b.ppm"}))
	testing.expect_value(t, flag_value(args, "dest", "?"), "y")
	testing.expect_value(t, flag_value(args, "odin", "odin"), "odin")
	testing.expect(t, has_flag(args, "no-dxc") && !has_flag(args, "no"))
	n, why := int_flag(args, "tolerance", 2)
	testing.expect(t, n == 5 && why == "")
	n, why = int_flag(args, "missing", 2)
	testing.expect(t, n == 2 && why == "")
	_, why = int_flag(args, "size", 32)
	testing.expect(t, why != "", "a size that is not a number is refused")
	x, xwhy := f64_flag(args, "scale", 1)
	testing.expect(t, x == 1.5 && xwhy == "")
}

// PowerShell 7 hands `-name:value` typed after `--` to a program as `-name:` and `value`: the tools join them again; what
// another shell passes whole stays as it is.
@(test)
a_flag_split_at_its_colon_is_joined :: proc(t: ^testing.T) {
	got := args_joined({"-backend:", "wgpu", "-group:", "ci1", "text", "-list", "-define:A=b"}, context.temp_allocator)
	testing.expect(t, slice.equal(got, []string{"-backend:wgpu", "-group:ci1", "text", "-list", "-define:A=b"}), fmt.tprint(got))
	last := args_joined({"text", "-group:"}, context.temp_allocator)   // (nothing after it: left as it is)
	testing.expect(t, slice.equal(last, []string{"text", "-group:"}), fmt.tprint(last))
}

// A tool finds its project's root from any folder below it by its mark; outside a project it finds none.
@(test)
the_root_is_found_by_its_mark :: proc(t: ^testing.T) {
	dir := scratch(t, "root")
	defer os.remove_all(dir)
	deep := fmt.tprintf("%s/src/a/b", dir)
	testing.expect(t, os.make_directory_all(deep) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/odin.version", dir), "dev\n") == nil)
	root, found := project_root(deep, "odin.version")
	want, _ := filepath.abs(dir, context.temp_allocator)
	testing.expect(t, found && root == want, root)
	_, found = project_root(deep, "no-such-mark-anywhere.txt")
	testing.expect(t, !found)
}

// The version of the sources: read after its line's start, written in place; a source without the line has none.
@(test)
the_version_is_read_and_written :: proc(t: ^testing.T) {
	LINE :: "APP_VERSION :: "
	src := "package x\n\nAPP_VERSION :: \"0.1.0\"\n\nmain :: proc() {}\n"
	testing.expect_value(t, version_of(src, LINE), "0.1.0")
	out, ok := version_set(src, LINE, "0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, version_of(out, LINE), "0.2.0")
	_, ok = version_set("package x\n", LINE, "1.0.0")
	testing.expect(t, !ok, "no version line")
}

// An odin command of a project: its package, the toolkit's collection and its others, -vet; on Linux its defines, and the
// link flag but for a check, which links nothing.
@(test)
an_odin_command_of_the_project :: proc(t: ^testing.T) {
	p := Project{toolkit = "gt", collections = {{"x", "ext/x"}}, linux_defines = {"-define:FONT_BACKEND=native"}}
	check := odin_command(p, "check")
	build := odin_command(p, "build", "src/fs", {"-o:speed"})
	testing.expect(t, slice.equal(check[:5], []string{"odin", "check", "src", "-collection:gt=gt/src", "-collection:x=ext/x"}), fmt.tprint(check))
	testing.expect(t, slice.contains(check, "-vet") && !slice.contains(check, LINUX_LINK_FLAG))
	testing.expect_value(t, build[2], "src/fs")
	testing.expect_value(t, build[len(build) - 1], "-o:speed")
	when ODIN_OS == .Linux {
		testing.expect(t, slice.contains(build, LINUX_LINK_FLAG) && slice.contains(check, "-define:FONT_BACKEND=native"))
	} else {
		testing.expect(t, !slice.contains(build, LINUX_LINK_FLAG))
	}
}

// A C library's stamp follows its sources and its flags: the same twice, another when a source or a flag changes; the
// library is up to date when it is there and its stamp says so (a stamp ending with a line end too).
@(test)
the_stamp_of_a_c_library :: proc(t: ^testing.T) {
	dir := scratch(t, "stamp")
	defer os.remove_all(dir)
	c, h := fmt.tprintf("%s/lib.c", dir), fmt.tprintf("%s/lib.h", dir)
	testing.expect(t, os.write_entire_file(c, "int x;\n") == nil && os.write_entire_file(h, "extern int x;\n") == nil)
	first, ok := c_lib_stamp({c, h}, {"-O2"})
	testing.expect(t, ok)
	again, _ := c_lib_stamp({c, h}, {"-O2"})
	testing.expect_value(t, again, first)
	flags, _ := c_lib_stamp({c, h}, {"-O2", "-DX"})
	testing.expect(t, flags != first, "a flag changed: built again")
	testing.expect(t, os.write_entire_file(h, "extern long x;\n") == nil)
	header, _ := c_lib_stamp({c, h}, {"-O2"})
	testing.expect(t, header != first, "a header changed: built again")
	_, ok = c_lib_stamp({fmt.tprintf("%s/none.c", dir)}, nil)
	testing.expect(t, !ok, "a source that is not there")
	lib, stamp := fmt.tprintf("%s/libx.a", dir), fmt.tprintf("%s/STAMP", dir)
	testing.expect(t, !stamp_holds(lib, stamp, header), "nothing built yet")
	testing.expect(t, os.write_entire_file(lib, "!<arch>\n") == nil && write_stamp(stamp, header))
	testing.expect(t, stamp_holds(lib, stamp, header), "built: the second build does nothing")
	testing.expect(t, os.write_entire_file(stamp, fmt.tprintf("%s\r\n", header)) == nil)
	testing.expect(t, stamp_holds(lib, stamp, header), "a stamp PowerShell wrote")
	testing.expect(t, !stamp_holds(lib, stamp, first))
}

// The scopes are read from the ui package's own sources; a scope opened under a negation is found, a plain one, another
// procedure of a longer name and a comment's are not.
@(test)
a_scope_opened_under_a_negation_is_found :: proc(t: ^testing.T) {
	ui := "@(deferred_none = pop_parent)\nrow :: proc(id := \"\") -> bool {\n\treturn true\n}\n\n// `@(deferred_none = x)` in a comment\n@(deferred_none = menu_end)\n// a comment between\nmenu :: proc() -> bool { return true }\nbutton :: proc() -> bool { return true }\n"
	scopes := ui_scopes({ui})
	testing.expect(t, slice.equal(scopes, []string{"row", "menu"}), fmt.tprint(scopes))
	text := "if ui.row() {\n}\nif !ui.row(id = \"x\") { return }\nif !ui.row_end() {}\nif !ui.button() {}\n\tif !ui.menu() { return }\n"
	found := scope_misuses(text, scopes)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {
		testing.expect(t, found[0] == Scope_Misuse{3, "row"} && found[1] == Scope_Misuse{6, "menu"}, fmt.tprint(found))
	}
	// (the toolkit's own scopes, read from src/ui)
	testing.expect(t, check_scopes(fmt.tprintf("%s/../ui", #directory)), "the toolkit's ui package opens no scope under a negation")
}

// The notices of the crates a library links, from cargo metadata: the normal dependencies from the root, crate after
// crate, never a build script's or a procedural macro; each with its licence files; a text the crates share said once.
@(test)
the_notices_of_the_linked_crates :: proc(t: ^testing.T) {
	dir := scratch(t, "notices")
	defer os.remove_all(dir)
	for c in ([]string{"lib", "dep", "deep", "build", "macro"}) {
		testing.expect(t, os.make_directory_all(fmt.tprintf("%s/%s", dir, c)) == nil)
	}
	MIT :: "MIT License\n\nPermission is hereby granted.\n"
	_ = os.write_entire_file(fmt.tprintf("%s/dep/LICENSE-MIT", dir), MIT)
	_ = os.write_entire_file(fmt.tprintf("%s/deep/COPYING", dir), MIT)
	_ = os.write_entire_file(fmt.tprintf("%s/deep/NOTICE", dir), "Deep's notice.\n")
	_ = os.write_entire_file(fmt.tprintf("%s/build/LICENSE", dir), "Build's.\n")
	_ = os.write_entire_file(fmt.tprintf("%s/macro/LICENSE", dir), "Macro's.\n")
	package_json :: proc(dir, name, kind: string) -> string {
		return fmt.tprintf(`{{"id":"%s 1.0.0","name":"%s","version":"1.0.0","license":"MIT","manifest_path":"%s/%s/Cargo.toml","targets":[{{"kind":["%s"]}}]}}`, name, name, dir, name, kind)
	}
	normal :: `"dep_kinds":[{"kind":null,"target":null}]`
	jdir, _ := strings.replace_all(dir, "\\", "/", context.temp_allocator)   // (a JSON string has no bare backslash)
	meta := fmt.tprintf(`{{"packages":[%s,%s,%s,%s,%s],"resolve":{{"root":"lib 1.0.0","nodes":[`+
		`{{"id":"lib 1.0.0","deps":[{{"pkg":"dep 1.0.0",%s}},{{"pkg":"build 1.0.0","dep_kinds":[{{"kind":"build","target":null}}]}},{{"pkg":"macro 1.0.0",%s}}]}},`+
		`{{"id":"dep 1.0.0","deps":[{{"pkg":"deep 1.0.0",%s}}]}},{{"id":"deep 1.0.0","deps":[]}}]}}}}`,
		package_json(jdir, "lib", "staticlib"), package_json(jdir, "dep", "lib"), package_json(jdir, "deep", "lib"), package_json(jdir, "build", "lib"), package_json(jdir, "macro", "proc-macro"),
		normal, normal, normal)
	crates, why := notices_crates(meta)
	testing.expect_value(t, why, "")
	testing.expect_value(t, len(crates), 2)
	if len(crates) != 2 { return }
	testing.expect(t, crates[0].name == "deep" && crates[1].name == "dep", "the linked crates, by name")
	testing.expect_value(t, len(crates[0].texts), 2)
	text := notices_text({name = "sample"}, {{"Odin's core library", "BSD-3-Clause", {"Odin's licence."}}}, crates, {"native/text"})
	testing.expect(t, strings.has_prefix(text, "Third-party notices\n\nsample is under the MIT licence"), text)
	testing.expect(t, strings.contains(text, "- Odin's core library: BSD-3-Clause\n- the Rust crates of gui_toolkit's native libraries (native/text):\n  - deep 1.0.0: MIT\n  - dep 1.0.0: MIT\n"), text)
	testing.expect(t, strings.contains(text, "deep 1.0.0, dep 1.0.0\n"), "a text two crates ship is said once, with both")
	testing.expect_value(t, strings.count(text, "Permission is hereby granted."), 1)
	testing.expect(t, !strings.contains(text, "Build's.") && !strings.contains(text, "Macro's."))

	_, why = notices_crates("not json")
	testing.expect(t, why != "")
	_ = os.remove(fmt.tprintf("%s/dep/LICENSE-MIT", dir))
	_, why = notices_crates(meta)
	testing.expect(t, strings.contains(why, "dep 1.0.0 ships no licence file"), why)
}

// A sway session's config: no XWayland, the headless output at its mode, the caller's lines after.
@(test)
the_config_of_a_sway_session :: proc(t: ^testing.T) {
	testing.expect_value(t, sway_config({}), "xwayland disable\noutput HEADLESS-1 resolution 1600x1000\n")
	testing.expect_value(t, sway_config({output = "1280x1024@60Hz", config = "default_border none\n"}), "xwayland disable\noutput HEADLESS-1 resolution 1280x1024@60Hz\ndefault_border none\n")
}
