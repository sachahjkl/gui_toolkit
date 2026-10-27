// Moved here with the file helpers it covers (was Wren's src/base/base_test.odin, remove_tree over temp_dir).
//   odin test tests/fsx -vet
package fsx_test

import "core:fmt"
import "core:os"
import "core:testing"
import "../../fsx"

@(test)
remove_tree_removes_a_directory_with_everything_in_it :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/gui_toolkit_fsx_remove_tree", fsx.temp_dir(context.temp_allocator))
	fsx.remove_tree(root)
	testing.expect(t, fsx.remove_tree(root), "an absent path: nothing to do")
	deep := fmt.tprintf("%s/a/b/c", root)
	testing.expect(t, os.make_directory_all(deep) == nil, "the tree is made")
	for name in ([]string{"x.txt", "a/y.txt", "a/b/z.txt", "a/b/c/w.txt"}) {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), transmute([]byte)string("data")) == nil, "a file is written")
	}
	testing.expect(t, fsx.remove_tree(root), "removed")
	testing.expect(t, !os.exists(root), "nothing is left")
	file := fmt.tprintf("%s.txt", root)
	testing.expect(t, os.write_entire_file(file, transmute([]byte)string("x")) == nil)
	testing.expect(t, fsx.remove_tree(file) && !os.exists(file), "a single file too")
}
