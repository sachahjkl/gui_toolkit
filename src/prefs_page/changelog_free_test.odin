package tk_prefs_page

import "core:mem"
import "core:testing"

// A group whose text has no uppercase letter (CHANGELOG.md has several: "- gui_toolkit 0.83.0.") must be freed once.
@(test)
a_lowercase_group_is_freed_once :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	c: Changelog
	changelog_read(&c, "## [0.11.3] - 2026-11-05 11:07\n\n### Changed\n\n- gui_toolkit 0.83.0.\n")
	testing.expect_value(t, len(c.releases), 1)
	changelog_destroy(&c)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)
}
