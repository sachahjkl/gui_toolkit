package tk_changelog

import "core:testing"

// A fragment written with no root goes to the current folder's changelog.d, not the disk's.
@(test)
fragments_of_no_root_are_in_the_current_folder :: proc(t: ^testing.T) {
	testing.expect_value(t, fragments_dir(""), "./changelog.d")
	testing.expect_value(t, fragments_dir("/x/y"), "/x/y/changelog.d")
}
