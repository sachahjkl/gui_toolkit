package fsx_test

import "core:fmt"
import "core:os"
import "core:testing"
import "gt:fsx"

// One holder at a time, also within one process (two opens of the file); the next one takes it once it is let go.
@(test)
a_file_lock_has_one_holder :: proc(t: ^testing.T) {
	when ODIN_OS != .Linux && ODIN_OS != .Windows { return }
	root := fresh_dir("gui_toolkit_fsx_lock")
	defer fsx.remove_tree(root)
	path := fmt.tprintf("%s/a.lock", root)
	a, ra := fsx.file_lock(path, 0)
	testing.expect_value(t, ra, fsx.Lock_Result.Locked)
	b, rb := fsx.file_lock(path, 0)
	testing.expect_value(t, rb, fsx.Lock_Result.Busy)
	fsx.file_unlock(&a)
	b, rb = fsx.file_lock(path, 0)
	testing.expect_value(t, rb, fsx.Lock_Result.Locked)
	fsx.file_unlock(&b)
	testing.expect(t, os.is_file(path), "the file stays")
	_, rc := fsx.file_lock(fmt.tprintf("%s/no/such/folder/a.lock", root), 0)
	testing.expect_value(t, rc, fsx.Lock_Result.Failed)
}
