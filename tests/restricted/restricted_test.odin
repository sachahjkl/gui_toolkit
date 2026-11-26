// A restricted process (gt:base's restrict: here an elevated program's restriction, which this test process takes for
// itself, whatever its token) starts, opens, installs, updates and loads nothing that a user can write, at each place of the toolkit that
// would (src/md/features/elevated-process.md). The restriction is for the whole process and is never lifted: this
// package holds only tests that want it, and run_tests runs it alone.
//   odin test tests/restricted -collection:gt=src -vet
package restricted_test

import "core:io"
import "core:os"
import "core:testing"
import base "gt:base"
import desktop "gt:desktop"
import devtools "gt:devtools"
import platform "gt:platform"
import process "gt:process"
import setup "gt:setup"
import update "gt:update"

@(private = "file")
identity :: proc() -> desktop.Identity {
	return desktop.Identity{
		name = "Sample", key = "Sample", slug = "sample", aumid = "GuiToolkit.Sample.Restricted", vendor = "Gui Toolkit",
		entry_marker = "X-Sample-Integration", registry_mark = "SampleIntegration", vendor_key = "GuiToolkitTest",
		manifest_name = "sample_install.txt", manifest_header = "# a test",
	}
}

@(test)
a_restricted_process_starts_and_installs_nothing_of_the_user :: proc(t: ^testing.T) {
	base.restrict(.Elevated)
	testing.expect_value(t, base.restriction(), base.Restriction.Elevated)
	base.restrict(.None)   // (nothing lifts it)
	testing.expect(t, base.restricted(), "still restricted")
	testing.expect(t, base.restricted_reason() != "", "the reason is said")

	// a program the user can write: refused, and nothing runs
	tmp, _ := os.temp_dir(context.temp_allocator)
	_, err := process.start({command = {tmp, "--never"}})
	testing.expect_value(t, err, os.Error(io.Error.Permission_Denied))
	_, err = process.start({command = {"true"}})   // (a bare name: the PATH is the user's)
	testing.expect_value(t, err, os.Error(io.Error.Permission_Denied))
	when ODIN_OS == .Linux {
		// a program of the system's folders: started
		for candidate in ([]string{"/run/current-system/sw/bin/true", "/usr/bin/true", "/bin/true"}) {
			if !os.is_file(candidate) { continue }
			p, start_err := process.start({command = {candidate}})
			testing.expectf(t, start_err == nil, "%s starts: %v", candidate, start_err)
			if start_err == nil { _, _ = os.process_wait(p) }
			break
		}
		// a detached start: a name only from the system's folders (the PATH may be the user's), a path only a trusted one
		testing.expect(t, !platform.launch_detached({tmp}), "a folder of the user's: refused")
		testing.expect(t, !platform.launch_detached({"no-such-program-of-the-system"}), "a name the system's folders do not have")
		testing.expect(t, platform.launch_detached({"true"}), "true, from the system's folders")
	}

	// the shell's handlers, the terminal, "Open with": the user's to change
	testing.expect(t, !platform.open_url("https://example.com/"), "no URL opened")
	testing.expect(t, !platform.open_path(tmp), "no folder opened")
	testing.expect(t, !platform.reveal_in_folder(tmp), "no file manager")
	testing.expect(t, !desktop.open_terminal(tmp), "no terminal")
	testing.expect(t, !desktop.open_with(tmp, "anything"), "no handler")

	// no install, no removal, no apply, no offer
	o := desktop.Integration_Options{identity = identity(), exe = tmp, start_menu = true}
	testing.expect_value(t, desktop.install(&o).error, desktop.Error.Restricted)
	testing.expect_value(t, desktop.remove(&o).error, desktop.Error.Restricted)
	testing.expect_value(t, desktop.apply(&o).error, desktop.Error.None)
	so := setup.Setup_Options{identity = identity(), version = "1.0.0"}
	ok, why := setup.install(so, false)
	testing.expect(t, !ok && why == setup.restricted_words(), "the install says why it does nothing")
	ok, _, why = setup.uninstall(so)
	testing.expect(t, !ok && why == setup.restricted_words(), "so does the uninstall")
	testing.expect(t, !setup.wanted({state = .Not_Installed}, "1.0.0", ""), "never offered")
	testing.expect(t, !setup.launch(tmp), "the installed copy is never started")

	// no update placed, no updater at work
	testing.expect_value(t, update.place(tmp, nil, {}), update.Error.Refused)
	u := update.updater_start({current = "1.0.0", exe = tmp})
	defer update.updater_stop(u)
	st := update.status(u, context.temp_allocator)
	testing.expect_value(t, st.phase, update.Phase.Refused)

	// no devtools server (its port takes any program's commands)
	testing.expect(t, devtools.start_from_env(nil) == nil, "no server")
}
