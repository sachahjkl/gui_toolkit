package tk_changelog

import "core:fmt"
import "core:os"
import "core:testing"
import "../testkit"
import toolbox "../toolbox"

// A fragment written with no root goes to the current folder's changelog.d, not the disk's.
@(test)
fragments_of_no_root_are_in_the_current_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, fragments_dir(""), "./changelog.d")
	testing.expect_value(t, fragments_dir("/x/y"), "/x/y/changelog.d")
}

// The changelog command of a project's tool: a fragment written beside the project's CHANGELOG.md, check passes while
// the sources say the last released version and fails when a branch wrote another, a line it does not take is refused.
@(test)
the_command_works_on_the_project :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	changes := fmt.tprintf("%s/CHANGELOG.md", dir)
	version_file := fmt.tprintf("%s/main.odin", dir)
	testing.expect(t, os.write_entire_file(changes, "# Changelog\n\n## [0.1.0] - 2026-11-01\n\n### Added\n- **One**: the first.\n\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n") == nil)
	testing.expect(t, os.write_entire_file(version_file, "APP_VERSION :: \"0.1.0\"\n") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/ROADMAP.md", dir), ROADMAP_GOOD) == nil)
	c := command({name = "sample", repository = "https://github.com/o/r", changelog = changes, version_file = version_file, version_line = "APP_VERSION :: "})
	defer free(c.user)
	cs := []toolbox.Command{c}
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "new", "Added", "**Two**: the second.", "-subject:two"}), 0)
	entries, err := os.read_all_directory_by_path(fmt.tprintf("%s/changelog.d", dir), context.temp_allocator)
	testing.expect(t, err == nil && len(entries) == 1, "one fragment")
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "check"}), 0)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "preview"}), 0)
	testing.expect(t, os.write_entire_file(version_file, "APP_VERSION :: \"0.2.0\"\n") == nil)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "check"}), 1)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "new", "Added"}), 2)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "publish"}), 2)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs, {"changelog", "new", "Odd", "text"}), 1)
}
