package tk_testkit

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"
import crashsite "crashsite"
import fsx "../fsx"

// A folder for this test, in the system's temporary folder, gone at its end. `what` shows in its name.
temp_folder :: proc(t: ^testing.T, what := "dir", allocator := context.allocator) -> string {
	crashsite.arm()   // (most tests make a folder: a crash names its place, src/md/infrastructure/test-crash-site.md)
	// (in the system's form, as a program has a path from the system: a test compares what a program would)
	tmp := fsx.temp_dir(context.temp_allocator)
	@(static) serial: int
	dir := fsx.path_join(tmp, fmt.tprintf("gui_toolkit-%s-%d-%d-%d", what, os.get_pid(), time.tick_now()._nsec, sync.atomic_add(&serial, 1)), allocator = allocator)
	_ = os.make_directory_all(dir)
	testing.cleanup(t, proc(p: rawptr) {
		d := (^string)(p)
		_ = os.remove_all(d^)
		delete(d^)
		free(d)
	}, new_clone(dir))
	return dir
}
