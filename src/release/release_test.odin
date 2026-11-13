package tk_release

import "core:fmt"
import "core:os"
import "core:testing"
import "../testkit"
import toolbox "../toolbox"
import update "../update"

@(test)
versions_compare_as_numbers :: proc(t: ^testing.T) {
	testing.expect(t, semver_newer("0.9.0", "0.10.0"))
	testing.expect(t, semver_newer("0.1.9", "0.2.0"))
	testing.expect(t, !semver_newer("1.0.0", "1.0.0"))
	testing.expect(t, !semver_newer("1.2.0", "1.1.9"))
	_, ok := semver("1.02.0")
	testing.expect(t, !ok, "a leading zero")
	_, ok = semver("1.2")
	testing.expect(t, !ok, "two numbers")
}

// The notes of a release are its section of the changelog (gt:changelog reads it, beside Config.changelog); a version
// without one is refused.
@(test)
the_notes_are_the_section :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	path := fmt.tprintf("%s/CHANGELOG.md", dir)
	text := "# Changelog\n\n## [0.1.0] - 2026-11-01\n\n### Added\n- The first.\n\n[0.1.0]: https://github.com/someone/something/releases/tag/v0.1.0\n"
	testing.expect(t, os.write_entire_file(path, text) == nil)
	c := Config{project = {name = "sample", repository = "https://github.com/someone/something", changelog = path}}
	testing.expect_value(t, notes(c, {"v0.1.0"}), 0)
	testing.expect_value(t, notes(c, {"0.2.0"}), 1)
}

// A program that updates itself: package_ writes the program alone beside the archive and its manifest, signed with the
// key of $UPDATE_SIGNING_KEY, which the product's public key checks; a release (a version given) without the key is refused.
@(test)
a_package_carries_the_signed_update :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	seed: [32]byte
	for &b, i in seed { b = u8(i * 7 + 1) }
	public, _ := update.public_key_of(seed[:], context.temp_allocator)
	product := update.Product{name = "sample", sign_context = "sample-update-v1\n", public_key = public}
	version_file := fmt.tprintf("%s/version.odin", dir)
	testing.expect(t, os.write_entire_file(version_file, "APP_VERSION :: \"1.2.3\"\n") == nil)
	// (a real program of this system: this test's own, which strip and the checks of a program accept)
	when ODIN_OS == .Windows { program := fmt.tprintf("%s/sample.exe", dir) } else { program := fmt.tprintf("%s/sample", dir) }
	self, err := os.read_entire_file(os.args[0], context.temp_allocator)
	testing.expect(t, err == nil && os.write_entire_file(program, self) == nil, "the program")
	c := Config{project = {name = "sample", version_file = version_file, version_line = "APP_VERSION :: ", program = program}, dist = fmt.tprintf("%s/dist", dir), update = product}

	os.unset_env(toolbox.UPDATE_KEY_ENV)
	testing.expect_value(t, package_(c, {"v1.2.3"}), 1)   // (a release without the key)

	os.set_env(toolbox.UPDATE_KEY_ENV, update.seed_encode(seed[:], context.temp_allocator))
	defer os.unset_env(toolbox.UPDATE_KEY_ENV)
	testing.expect_value(t, package_(c, {"v1.2.3"}), 0)
	alone := fmt.tprintf("%s/%s", c.dist, update.expected_file_name(product, "1.2.3", update.PLATFORM, context.temp_allocator))
	testing.expect(t, os.is_file(alone), "the program alone")
	manifest_path := fmt.tprintf("%s/%s", c.dist, update.manifest_name(update.PLATFORM, "", context.temp_allocator))
	manifest, merr := os.read_entire_file(manifest_path, context.temp_allocator)
	sig, serr := os.read_entire_file(fmt.tprintf("%s.sig", manifest_path), context.temp_allocator)
	testing.expect(t, merr == nil && serr == nil, "the manifest and its signature")
	m, verr := update.verify(product, manifest, string(sig), update.PLATFORM, "", context.temp_allocator)
	testing.expect_value(t, verr, update.Error.None)
	testing.expect_value(t, m.version, "1.2.3")
}

// A project names its changelog by a bare file name ("CHANGELOG.md"): its folder is the current one.
@(test)
a_bare_changelog_name_is_in_the_current_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, changelog_options({project = {changelog = "CHANGELOG.md"}}).root, ".")
	testing.expect_value(t, changelog_options({project = {changelog = "docs/CHANGELOG.md"}}).root, "docs")
}

// The release's commands of a tool: package, notes and ship, each with what it does, over the project's Config.
@(test)
the_release_commands_run_over_the_config :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	path := fmt.tprintf("%s/CHANGELOG.md", dir)
	text := "# Changelog\n\n## [0.1.0] - 2026-11-01\n\n### Added\n- The first.\n\n[0.1.0]: https://github.com/o/r/releases/tag/v0.1.0\n"
	testing.expect(t, os.write_entire_file(path, text) == nil)
	cs := commands({project = {name = "sample", repository = "https://github.com/o/r", changelog = path}})
	defer free(cs[0].user)   // (one Config for the three)
	testing.expect_value(t, cs[0].name, "package")
	testing.expect_value(t, cs[1].name, "notes")
	testing.expect_value(t, cs[2].name, "ship")
	for c in cs { testing.expectf(t, c.usage != "" && c.run_with != nil, "%s says what it does", c.name) }
	testing.expect_value(t, toolbox.dispatch("sampletool", cs[:], {"notes", "0.1.0"}), 0)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs[:], {"notes"}), 2)
	testing.expect_value(t, toolbox.dispatch("sampletool", cs[:], {"ship"}), 2)
}
