// The file tree's trash and its undo, in a trash of the test's own ($XDG_DATA_HOME in its temporary folder: the
// person's trash is never touched).
package tree_test

import "core:os"
import "core:strings"
import "core:testing"
import "gt:testkit"
import "gt:testkit/session"
import "gt:ui"

@(test)
delete_moves_to_the_trash_and_its_undo_puts_back :: proc(t: ^testing.T) {
	data := testkit.temp_folder(t, "data")
	before, had := os.lookup_env("XDG_DATA_HOME", context.temp_allocator)
	os.set_env("XDG_DATA_HOME", data)
	defer if had { os.set_env("XDG_DATA_HOME", before) } else { os.unset_env("XDG_DATA_HOME") }
	dir := testkit.temp_folder(t, "tree")
	write(dir, "keep.txt", "x")
	write(dir, "gone.txt", "x")
	f: Files
	defer files_destroy(&f)
	ui.file_tree_set_root(&f.t, dir)
	s := session.start(t, {build = files_build, user = &f, size = {700, 500}})
	session.wait_until(s, Wait_Labels{&f, "gone.txt,keep.txt"}, labels_are, "the folder listed", 20e9)
	session.click(s, "lrow_0")
	session.key(s, .Delete)
	session.wait_until(s, Wait_Labels{&f, "keep.txt"}, labels_are, "the trash", 20e9)
	gone := strings.concatenate({dir, "/gone.txt"}, context.temp_allocator)
	testing.expect(t, !os.exists(gone))
	f.undo_next = true
	session.wait_until(s, Wait_Labels{&f, "gone.txt,keep.txt"}, labels_are, "the undo", 20e9)
	testing.expect(t, os.exists(gone))
}
