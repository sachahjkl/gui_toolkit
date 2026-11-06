#+build linux
package fsx_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "../../fsx"

// `durable` is a promise: a directory that could not be synced is said to be so, though the name did change.
@(test)
a_durable_replace_says_it_could_not_sync :: proc(t: ^testing.T) {
	root := fresh_dir("gui_toolkit_fsx_durable")
	defer fsx.remove_tree(root)
	from := fmt.tprintf("%s/from", root)
	to := fmt.tprintf("%s/to", root)
	testing.expect(t, os.write_entire_file(from, transmute([]byte)string("data")) == nil)
	testing.expect(t, fsx.replace(from, to, true), "a directory that can be synced")
	testing.expect(t, os.write_entire_file(from, transmute([]byte)string("data")) == nil)
	// (written and searched, not read: it cannot be opened to sync; root ignores that)
	if posix.getuid() == 0 { return }
	dir := strings.clone_to_cstring(root, context.temp_allocator)
	testing.expect_value(t, posix.chmod(dir, {.IWUSR, .IXUSR}), posix.result.OK)
	defer posix.chmod(dir, {.IRUSR, .IWUSR, .IXUSR})
	testing.expect(t, !fsx.replace(from, to, true), "it is not on the disk")
}