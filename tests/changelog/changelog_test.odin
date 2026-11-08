// tools/changelog on a throwaway checkout (a CHANGELOG.md, the file that holds the version, fragments): well formed and malformed fragments, new_fragment, check
// (orphans, duplicates, a release), assemble with and without fragments, section.
//   odin test tests/changelog -vet
package changelog_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import changelog "../../tools/changelog"
import "../../src/testkit"

@(private = "file") BASE_VERSION :: "1.2.3"
@(private = "file") NEXT_VERSION :: "9.9.9"
@(private = "file") RELEASE_DATE :: "2026-10-27"
@(private = "file") OLD_ENTRY :: "**Old thing**: shipped."
@(private = "file") VERSION_SOURCE :: "package ui\n\nVERSION_MAJOR :: 1\nVERSION_MINOR :: 2\nVERSION_PATCH :: 3\nVERSION :: \"1.2.3\"\n"

@(private = "file")
fresh :: proc(t: ^testing.T) -> string {
	dir := testkit.temp_folder(t, "changelog")
	_ = os.make_directory_all(fmt.tprintf("%s/changelog.d", dir))
	_ = os.make_directory_all(fmt.tprintf("%s/src/ui", dir))
	write(fmt.tprintf("%s/%s", dir, changelog.VERSION_FILE), VERSION_SOURCE)
	write(fmt.tprintf("%s/CHANGELOG.md", dir), fmt.tprintf("# Changelog\r\n\r\nIntro.\r\n\r\n## [%s] - 2026-01-01\r\n\r\n### Added\r\n- %s\r\n", BASE_VERSION, OLD_ENTRY))
	write(fmt.tprintf("%s/README.md", dir), `<a><img src="https://img.shields.io/badge/version-1.2.3-1d57ba" alt="version 1.2.3"></a>`)
	return dir
}

@(private = "file") write :: proc(path, text: string) { _ = os.write_entire_file(path, transmute([]byte)text) }
@(private = "file") read :: proc(path: string) -> string { d, _ := os.read_entire_file(path, context.temp_allocator); return string(d) }
@(private = "file") frag :: proc(dir, name, text: string) { write(fmt.tprintf("%s/changelog.d/%s", dir, name), text) }
@(private = "file") unfrag :: proc(dir, name: string) { _ = os.remove(fmt.tprintf("%s/changelog.d/%s", dir, name)) }

@(private = "file")
says :: proc(errors: []string, what: string) -> bool {
	for e in errors { if strings.contains(e, what) { return true } }
	return false
}

@(test)
no_fragment_at_all :: proc(t: ^testing.T) {
	dir := fresh(t)
	errors, n := changelog.check(dir)
	testing.expectf(t, len(errors) == 0, "check passes: %v", errors)
	testing.expect_value(t, n, 0)
	text, perr := changelog.preview(dir)
	testing.expect_value(t, len(perr), 0)
	testing.expect_value(t, text, "")
	_, aerr := changelog.assemble(dir, NEXT_VERSION)
	testing.expect(t, says(aerr[:], "nothing to publish"), "assemble refuses")
}

@(test)
a_version_written_by_a_branch_fails_the_check :: proc(t: ^testing.T) {
	dir := fresh(t)
	s, _ := strings.replace_all(VERSION_SOURCE, `"1.2.3"`, `"99.0.0"`, context.temp_allocator)
	write(fmt.tprintf("%s/%s", dir, changelog.VERSION_FILE), s)
	errors, _ := changelog.check(dir)
	testing.expect(t, says(errors[:], "the version is written when a version is published"))
}

// Two of one subject, LF and CRLF, sub-items: they count, and the preview lists them by type.
@(test)
well_formed_fragments :: proc(t: ^testing.T) {
	dir := fresh(t)
	frag(dir, "20261026-100000-tabs.md", "type: Added\n\n**Tabs in a sidebar**: one.\n")
	errors, n := changelog.check(dir)
	testing.expectf(t, len(errors) == 0 && n == 1, "one fragment: %v", errors)
	frag(dir, "20261026-100001-tabs.md", "type: Fixed\r\n**Tabs** no longer flicker.\r\n")
	frag(dir, "20261026-100002-workers.md", "type: changed\n- **Workers**:\n  - one;\n  - two.\n")
	errors, n = changelog.check(dir)
	testing.expectf(t, len(errors) == 0 && n == 3, "three, two of one subject: %v", errors)
	text, _ := changelog.preview(dir)
	testing.expect_value(t, text, "### Added\n- **Tabs in a sidebar**: one.\n\n### Changed\n- **Workers**:\n  - one;\n  - two.\n\n### Fixed\n- **Tabs** no longer flicker.\n")
}

@(test)
malformed_fragments_are_said_so :: proc(t: ^testing.T) {
	dir := fresh(t)
	Case :: struct { name, text, says: string }
	cases := []Case{
		{"20261026-100003-x.md", "type: Improved\n\nSomething.\n", "unknown type 'Improved'"},
		{"my change.md", "type: Added\n\nA thing.\n", "its name is not"},
		{"20261026-100004-two.md", "type: Added\n\n- One.\n- Two.\n", "several entries"},
		{"20261026-100005-notype.md", "Just text.\n", "first line is not"},
		{"20261026-100007-orphan.md", fmt.tprintf("type: Added\n\n%s\n", OLD_ENTRY), "already in a released section"},
		{"20261026-100008-blank.md", "type: Added\n\nOne.\n\nTwo.\n", "a blank line"},
		{"20261026-100009-head.md", "type: Added\n\n# Title\n", "a heading"},
		{"20261026-100010-none.md", "type: Added\n\n", "no text"},
		{"20261026-100011-empty.md", "", "it is empty"},
	}
	for c in cases {
		frag(dir, c.name, c.text)
		errors, _ := changelog.check(dir)
		testing.expectf(t, says(errors[:], c.says), "%s: %q, got %v", c.name, c.says, errors)
		unfrag(dir, c.name)
	}
	// and an assembled release stops at it
	frag(dir, "20261026-100003-x.md", "type: Improved\n\nSomething.\n")
	_, aerr := changelog.assemble(dir, NEXT_VERSION)
	testing.expect(t, says(aerr[:], "unknown type"), "assemble refuses too")
	testing.expect(t, !strings.contains(read(fmt.tprintf("%s/CHANGELOG.md", dir)), NEXT_VERSION), "and writes nothing")
}

@(test)
two_fragments_with_the_same_text_fail :: proc(t: ^testing.T) {
	dir := fresh(t)
	frag(dir, "20261026-100001-tabs.md", "type: Fixed\n**Tabs** no longer flicker.\n")
	frag(dir, "20261026-100006-dup.md", "type: Fixed\n\n**Tabs**   no longer flicker.\n")
	errors, _ := changelog.check(dir)
	testing.expect(t, says(errors[:], "the same text as"))
}

@(test)
new_writes_a_well_formed_fragment :: proc(t: ^testing.T) {
	dir := fresh(t)
	path, why := changelog.new_fragment(dir, "Removed", "Old Pref!", "The `x.y` preference.")
	testing.expect_value(t, why, "")
	testing.expect(t, strings.has_suffix(path, "-old-pref.md"), "its subject")
	testing.expect(t, strings.has_prefix(read(path), "type: Removed"), "its type")
	errors, n := changelog.check(dir)
	testing.expectf(t, len(errors) == 0 && n == 1, "it passes: %v", errors)
	again, _ := changelog.new_fragment(dir, "Added", "**Strong part**: and the rest", "**Strong part**: and the rest")
	testing.expect(t, strings.contains(again, "-strong-part"), "the strong part names it")
	_, refused := changelog.new_fragment(dir, "Nope", "", "x")
	testing.expect(t, refused != "", "an unknown type is refused")
	_, empty := changelog.new_fragment(dir, "Added", "", "   ")
	testing.expect(t, empty != "", "no text is refused")
	_, several := changelog.new_fragment(dir, "Added", "", "One.\n- Two.")
	testing.expect(t, strings.contains(several, "several entries"), "what would be no fragment is not left behind")
}

// A section above the last one, the version written, the fragments gone; a version is not assembled twice.
@(test)
a_release :: proc(t: ^testing.T) {
	dir := fresh(t)
	frag(dir, "20261026-100000-tabs.md", "type: Removed\n\n**Tabs**: gone.\n")
	errors, _ := changelog.check(dir, NEXT_VERSION)
	testing.expect(t, says(errors[:], "not assembled"), "not ready while fragments are left")
	n, aerr := changelog.assemble(dir, NEXT_VERSION, RELEASE_DATE)
	testing.expectf(t, len(aerr) == 0 && n == 1, "%v", aerr)
	cl := read(fmt.tprintf("%s/CHANGELOG.md", dir))
	testing.expect(t, strings.contains(cl, fmt.tprintf("## [%s] - %s\r\n", NEXT_VERSION, RELEASE_DATE)), "its heading")
	testing.expect(t, strings.index(cl, NEXT_VERSION) < strings.index(cl, "2026-01-01"), "above the last one")
	testing.expect(t, !strings.contains(strings.concatenate({strings.join(strings.split(cl, "\r\n", context.temp_allocator), "", context.temp_allocator)}, context.temp_allocator), "\n"), "the CHANGELOG keeps its CRLF")
	testing.expect(t, strings.contains(cl, fmt.tprintf("[%s]: https://", NEXT_VERSION)), "its link at the end of the file")
	entries, _ := os.read_directory_by_path(fmt.tprintf("%s/changelog.d", dir), 0, context.temp_allocator)
	testing.expect_value(t, len(entries), 0)
	source := read(fmt.tprintf("%s/%s", dir, changelog.VERSION_FILE))
	testing.expect(t, strings.contains(source, `VERSION :: "9.9.9"`) && strings.contains(source, "VERSION_MINOR :: 9"), "the version in the sources")
	readme := read(fmt.tprintf("%s/README.md", dir))
	testing.expect(t, strings.contains(readme, "badge/version-9.9.9-1d57ba") && strings.contains(readme, `alt="version 9.9.9"`), "and in the badge")
	ready, _ := changelog.check(dir, NEXT_VERSION)
	testing.expectf(t, len(ready) == 0, "ready after it: %v", ready)
	plain, _ := changelog.check(dir)
	testing.expectf(t, len(plain) == 0, "the check passes after it: %v", plain)
	body, ok := changelog.section(dir, NEXT_VERSION)
	testing.expect(t, ok && strings.contains(body, "### Removed") && !strings.contains(body, BASE_VERSION), "that section only")
	_, twice := changelog.assemble(dir, NEXT_VERSION)
	testing.expect(t, says(twice[:], "already has a section") || says(twice[:], "nothing to publish"), "a version is not assembled twice")
	_, none := changelog.section(dir, "0.0.1")
	testing.expect(t, !none, "no such section")
}

// A version that is none is refused.
@(test)
a_version_is_x_y_z :: proc(t: ^testing.T) {
	dir := fresh(t)
	frag(dir, "20261026-100000-tabs.md", "type: Added\n\nA thing.\n")
	_, errors := changelog.assemble(dir, "soon")
	testing.expect(t, says(errors[:], "is x.y.z"))
}

// The real repository's fragments and version, as the CI asks.
@(test)
this_repository_is_well_formed :: proc(t: ^testing.T) {
	errors, _ := changelog.check(".")
	testing.expectf(t, len(errors) == 0, "%v", errors)
}
