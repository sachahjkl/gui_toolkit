package tk_changelog

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../testkit"

ROADMAP_GOOD :: "# Roadmap\n\n## Now\n\n- **One.** What it gives,\n  on two lines.\n\n## Next\n\n## Later\n\n- **Two.** More.\n"

// (true when one error names the line and says the words)
@(private = "file")
says :: proc(errors: [dynamic]string, line, words: string) -> bool {
	for e in errors { if strings.has_prefix(e, line) && strings.contains(e, words) { return true } }
	return false
}

@(test)
a_good_roadmap_has_no_error :: proc(t: ^testing.T) {
	testing.expect_value(t, len(roadmap_errors(ROADMAP_GOOD)), 0)
	// (no newline at the end)
	good := ROADMAP_GOOD
	testing.expect_value(t, len(roadmap_errors(good[:len(good) - 1])), 0)
	testing.expect_value(t, len(roadmap_errors("# Roadmap\r\n## Now\r\n## Next\r\n## Later\r\n")), 0)
}

@(test)
a_missing_section_is_named :: proc(t: ^testing.T) {
	errors := roadmap_errors("# Roadmap\n\n## Now\n\n## Later\n")
	testing.expect(t, says(errors, "line 5:", "## Later before ## Next"), "the section after the gap")
	errors = roadmap_errors("# Roadmap\n\n## Now\n\n## Next\n")
	testing.expect(t, says(errors, "line 5:", "no ## Later"), "the last section")
}

@(test)
sections_out_of_order_are_named :: proc(t: ^testing.T) {
	errors := roadmap_errors("# Roadmap\n## Next\n## Now\n## Later\n")
	testing.expect(t, says(errors, "line 2:", "## Next before ## Now"), "the first out of place")
	testing.expect(t, says(errors, "line 3:", "## Now after ## Next"), "the one that comes back")
}

@(test)
a_date_is_refused :: proc(t: ^testing.T) {
	errors := roadmap_errors("# Roadmap\n## Now\n- **One.** Asked on 2026-11-14.\n## Next\n## Later\n")
	testing.expect(t, says(errors, "line 3:", "a date"), "the date")
	testing.expect_value(t, len(roadmap_errors("# Roadmap\n## Now\n- **One.** See v2026-11-14x.\n## Next\n## Later\n")), 0)
}

@(test)
an_entry_without_a_bold_summary_is_refused :: proc(t: ^testing.T) {
	errors := roadmap_errors("# Roadmap\n## Now\n- One, plain.\n## Next\n## Later\n")
	testing.expect(t, says(errors, "line 3:", "bold summary"), "the plain entry")
	errors = roadmap_errors("---\ntitle: x\n---\n# Roadmap\n## Now\n## Next\n## Later\n")
	testing.expect(t, says(errors, "line 1:", "front matter"), "the front matter")
	errors = roadmap_errors("# Roadmap\n## Now\n### Detail\nprose\n## Next\n## Later\n")
	testing.expect(t, says(errors, "line 3:", "the only headings"), "another heading")
	testing.expect(t, says(errors, "line 4:", "neither an entry"), "prose in a section")
}

// The changelog's check sees the roadmap beside it: a project without one, or with a bad one, does not pass.
@(test)
the_check_sees_the_roadmap :: proc(t: ^testing.T) {
	dir := testkit.temp_folder(t)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/CHANGELOG.md", dir), "# Changelog\n") == nil)
	errors, _ := check({root = dir})
	found := false
	for e in errors { if strings.contains(e, "no ROADMAP.md") { found = true } }
	testing.expect(t, found, "no roadmap: said")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/ROADMAP.md", dir), "# Roadmap\n## Now\n") == nil)
	errors, _ = check({root = dir})
	found = false
	for e in errors { if strings.has_prefix(e, "ROADMAP.md: line 2:") && strings.contains(e, "no ## Next") { found = true } }
	testing.expect(t, found, "a bad roadmap: its line")
}
