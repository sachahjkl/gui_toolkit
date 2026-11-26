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
		env_prefix = "SAMPLE_DESKTOP_",
		url_schemes = TEST_SCHEMES[:], url_flag = "--open-url", uninstall_arguments = "--uninstall",
		generic_name = "Sample Program", categories = "Utility;", keywords = "Sample;Test;",
		nix_runtime_name = "sample-runtime", nixos_libraries = TEST_LIBRARIES[:],
		watch_thread_name = "sample-watch", cleanup_name = "sample_cleanup",
		scratch_roots = TEST_SCRATCH_ROOTS[:],
	}
}

@(test)
identity_is_validated :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), exe = "x"}
	testing.expect_value(t, validate(&o, false).error, Error.None)
	Case :: struct { what: string, change: proc(id: ^Identity) }
	cases := [?]Case{
		{"a key with a space", proc(id: ^Identity) { id.key = "Sample Dev" }},
		{"a slug in capitals", proc(id: ^Identity) { id.slug = "Sample" }},
		{"a name with a slash", proc(id: ^Identity) { id.name = "a/b" }},
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
	o.identity.aumid = ""
	testing.expect_value(t, validate(&o, false).error, Error.None)   // (none given: the vendor's and the name's)
	testing.expect_value(t, identity_aumid(o.identity), "GuiToolkit.Sample")
	o.identity = test_identity()
	o.identity.launcher_mark = ""
	o.launcher = transmute([]byte)string("MZ")
	testing.expect_value(t, validate(&o, false).error, Error.Bad_Options)   // (a launcher without its mark: any .com would be ours)
	o.launcher = nil
	o.exe = "Z:\\no\\such\\file.exe"
	testing.expect_value(t, validate(&o, true).error, Error.No_Executable)
}

// The marks the programs wrote by hand, from their vendor, title and slug: an installed copy's marks stay its own.
@(test)
an_identity_derives_its_marks :: proc(t: ^testing.T) {
	papier := identity_of("Froment Software", "Papier", "papier", context.temp_allocator)
	testing.expect_value(t, papier.name, "Papier")
	testing.expect_value(t, papier.key, "Papier")
	testing.expect_value(t, papier.vendor, "Froment Software")
	testing.expect_value(t, papier.vendor_key, "FromentSoftware")
	testing.expect_value(t, papier.entry_marker, "X-Papier-Integration")
	testing.expect_value(t, papier.registry_mark, "PapierIntegration")
	testing.expect_value(t, papier.manifest_name, "papier_install.txt")
	testing.expect_value(t, papier.env_prefix, "PAPIER_DESKTOP_")
	testing.expect_value(t, identity_aumid(papier), "FromentSoftware.Papier")
	two := identity_of("Froment Software", "opencode native", "opencode-native", context.temp_allocator)
	testing.expect_value(t, two.key, "OpencodeNative")
	testing.expect_value(t, two.entry_marker, "X-OpencodeNative-Integration")
	testing.expect_value(t, two.registry_mark, "OpencodeNativeIntegration")
	testing.expect_value(t, two.env_prefix, "OPENCODE_NATIVE_DESKTOP_")
	o := Integration_Options{identity = papier, exe = "x"}
	testing.expect_value(t, validate(&o, false).error, Error.None)
}

@(test)
roots_come_from_the_environment :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), notify_system = true}
	roots_from_env(&o, proc(name: string) -> string {
		switch name {
		case "SAMPLE_DESKTOP_BIN_DIR":      return "/scratch/bin"
		case "SAMPLE_DESKTOP_REGISTRY_ROOT": return `Software\TkDesktopTest_1`
		case "SAMPLE_DESKTOP_CONFIG_DIR":   return "/scratch/config"
		case "SAMPLE_DESKTOP_MACHINE_REGISTRY_ROOT": return `Software\TkDesktopTest_1\Machine`
		case "SAMPLE_DESKTOP_MACHINE_ROOT": return "/scratch/machine"
		case "WREN_DESKTOP_MENU_DIR":       return "/not/this/program's"
		}
		return ""
	})
	testing.expect_value(t, o.bin_dir, "/scratch/bin")
	testing.expect_value(t, o.config_dir, "/scratch/config")
	testing.expect_value(t, o.registry_root, `Software\TkDesktopTest_1`)
	testing.expect_value(t, o.machine_registry_root, `Software\TkDesktopTest_1\Machine`)
	testing.expect_value(t, o.machine_root, "/scratch/machine")
	testing.expect_value(t, o.menu_dir, "")
	testing.expect(t, !o.notify_system, "a scratch root tells the system nothing")

	o2 := Integration_Options{identity = test_identity(), notify_system = true}
	roots_from_env(&o2, proc(name: string) -> string { return "" })
	testing.expect(t, o2.notify_system, "no root: the real desktop, told")
}

@(test)
options_clone_owns_its_roots :: proc(t: ^testing.T) {
	o := Integration_Options{identity = test_identity(), exe = "/a/sample", bin_dir = "/b", autostart_dir = "/c/autostart", config_dir = "/c", file_types = {".html"}}
	c := options_clone(o)
	defer options_destroy(&c)
	testing.expect_value(t, c.bin_dir, "/b")
	testing.expect(t, raw_data(c.bin_dir) != raw_data(o.bin_dir), "a copy")
	testing.expect_value(t, c.config_dir, "/c")
	testing.expect(t, raw_data(c.config_dir) != raw_data(o.config_dir), "a copy")
	testing.expect(t, raw_data(c.autostart_dir) != raw_data(o.autostart_dir), "a copy")
	testing.expect_value(t, c.file_types[0], ".html")
}
