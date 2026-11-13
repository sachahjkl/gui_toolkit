package tk_desktop

// The identity of the tests: a program of its own, which no installed program shares, and its checks.

import "core:testing"

@(private = "file") TEST_SCHEMES := [?]string{"sample-http", "sample-https"}
@(private = "file") TEST_LIBRARIES := [?]string{"glibc", "stdenv.cc.cc"}
@(private = "file") TEST_SCRATCH_ROOTS := [?]string{`Software\TkDesktopTest_`}
@(private = "file") BAD_ACTIONS := [?]Desktop_Action{{id = "new window", name = "New window"}}
@(private = "file") BAD_SCHEMES := [?]string{"Sample-http"}

@(private)
test_identity :: proc() -> Identity {
	return Identity{
		name = "Sample", key = "Sample", slug = "sample", aumid = "GuiToolkit.Sample.Test", description = "A test.",
		vendor = "Gui Toolkit", exe_name = EXE_SUFFIX == "" ? "sample" : "sample.exe",
		entry_marker = "X-Sample-Integration", registry_mark = "SampleIntegration", vendor_key = "GuiToolkitTest",
		manifest_name = "sample_install.txt", manifest_header = "# Written by the tk_desktop tests.",
		launcher_mark = "(Sample console launcher)",
		cli_flag = "--desktop-integration", env_prefix = "SAMPLE_DESKTOP_",
		url_schemes = TEST_SCHEMES[:], url_flag = "--open-url", uninstall_arguments = "--uninstall",
		generic_name = "Sample Program", categories = "Utility;", keywords = "Sample;Test;",
		nix_runtime_name = "sample-runtime", nixos_libraries = TEST_LIBRARIES[:],
		watch_thread_name = "sample-watch", cleanup_name = "sample_cleanup",
		scratch_roots = TEST_SCRATCH_ROOTS[:],
	}
}

@(private)
EXE_SUFFIX :: ".exe" when ODIN_OS == .Windows else ""

@(test)
identity_is_validated :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), exe = "x"}
	testing.expect_value(t, validate(&o, false).error, Error.None)
	Case :: struct { what: string, change: proc(id: ^Identity) }
	cases := [?]Case{
		{"a key with a space", proc(id: ^Identity) { id.key = "Sample Dev" }},
		{"a slug in capitals", proc(id: ^Identity) { id.slug = "Sample" }},
		{"a name with a slash", proc(id: ^Identity) { id.name = "a/b" }},
		{"no aumid", proc(id: ^Identity) { id.aumid = "" }},
		{"a marker without X-", proc(id: ^Identity) { id.entry_marker = "Sample-Integration" }},
		{"no registry mark", proc(id: ^Identity) { id.registry_mark = "" }},
		{"a vendor key with a backslash", proc(id: ^Identity) { id.vendor_key = `a\b` }},
		{"a manifest in another folder", proc(id: ^Identity) { id.manifest_name = "../x.txt" }},
		{"a scheme in capitals", proc(id: ^Identity) { id.url_schemes = BAD_SCHEMES[:] }},
		{"schemes without a flag", proc(id: ^Identity) { id.url_flag = "" }},
		{"an action with a space in its id", proc(id: ^Identity) { id.actions = BAD_ACTIONS[:] }},
	}
	for c in cases {
		o.identity = test_identity()
		c.change(&o.identity)
		testing.expectf(t, validate(&o, false).error == .Bad_Options, "%s is refused", c.what)
	}
	o.identity = test_identity()
	o.identity.launcher_mark = ""
	o.launcher = transmute([]byte)string("MZ")
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)   // (a launcher without its mark: any .com would be ours)
	o.launcher = nil
	o.exe = "Z:\\no\\such\\file.exe"
	testing.expect_value(t, validate(&o, true).error, Error.No_Executable)
}

@(test)
cli_flag_parsing :: proc(t: ^testing.T) {
	id := test_identity()
	m, rest, bad := parse_cli(id, {"--desktop-integration=install", "https://a.test/"})
	testing.expect_value(t, m, Cli_Mode.Install)
	testing.expect_value(t, len(rest), 1)
	testing.expect_value(t, bad, "")
	m, rest, bad = parse_cli(id, {"--profile", "x", "--desktop-integration", "status"})
	testing.expect_value(t, m, Cli_Mode.Status)
	testing.expect_value(t, len(rest), 2)
	m, _, bad = parse_cli(id, {"--desktop-integration=frobnicate"})
	testing.expect_value(t, m, Cli_Mode.None)
	testing.expect_value(t, bad, "frobnicate")
	m, rest, _ = parse_cli(id, {"page.html", "--desktop-integrationx=install"})
	testing.expect_value(t, m, Cli_Mode.None)
	testing.expect_value(t, len(rest), 2)
	m, rest, _ = parse_cli(id, {"--uninstall"})
	testing.expect_value(t, m, Cli_Mode.Uninstall)
	testing.expect_value(t, len(rest), 0)
	id.cli_flag = ""
	m, rest, _ = parse_cli(id, {"--uninstall", "--desktop-integration=install"})
	testing.expect_value(t, m, Cli_Mode.None)   // (a program without the flag keeps its arguments)
	testing.expect_value(t, len(rest), 2)
}

@(test)
roots_come_from_the_environment :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), notify_system = true}
	roots_from_env(&o, proc(name: string) -> string {
		switch name {
		case "SAMPLE_DESKTOP_BIN_DIR":      return "/scratch/bin"
		case "SAMPLE_DESKTOP_REGISTRY_ROOT": return `Software\TkDesktopTest_1`
		case "WREN_DESKTOP_MENU_DIR":       return "/not/this/program's"
		}
		return ""
	})
	testing.expect_value(t, o.bin_dir, "/scratch/bin")
	testing.expect_value(t, o.registry_root, `Software\TkDesktopTest_1`)
	testing.expect_value(t, o.menu_dir, "")
	testing.expect(t, !o.notify_system, "a scratch root tells the system nothing")

	o2 := Integration_Options{identity = test_identity(), notify_system = true}
	roots_from_env(&o2, proc(name: string) -> string { return "" })
	testing.expect(t, o2.notify_system, "no root: the real desktop, told")
}

@(test)
options_clone_owns_its_roots :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), exe = "/a/sample", bin_dir = "/b", file_types = {".html"}}
	c := options_clone(o)
	defer options_destroy(&c)
	testing.expect_value(t, c.bin_dir, "/b")
	testing.expect(t, raw_data(c.bin_dir) != raw_data(o.bin_dir), "a copy")
	testing.expect_value(t, c.file_types[0], ".html")
}
