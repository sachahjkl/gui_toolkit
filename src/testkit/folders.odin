package tk_testkit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"

// A folder for this test, in the system's temporary folder, gone at its end. `what` shows in its name.
temp_folder :: proc(t: ^testing.T, what := "dir", allocator := context.allocator) -> string {
	tmp, _ := os.temp_directory(context.temp_allocator)
	@(static) serial: int
	dir := strings.clone(fmt.tprintf("%s/gui_toolkit-%s-%d-%d-%d", tmp, what, os.get_pid(), time.tick_now()._nsec, sync.atomic_add(&serial, 1)), allocator)
	_ = os.make_directory_all(dir)
	testing.cleanup(t, proc(p: rawptr) {
		d := (^string)(p)
		_ = os.remove_all(d^)
		delete(d^)
		free(d)
	}, new_clone(dir))
	return dir
}
