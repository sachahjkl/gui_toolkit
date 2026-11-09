#+build linux
package tk_desktop

import "core:fmt"
import "core:os"
import "core:testing"

// $TERMINAL first; else the first terminal of the list found on the PATH; else none.
@(test)
the_terminal_chosen :: proc(t: ^testing.T) {
	testing.expect_value(t, terminal_program("/nowhere", "my-term"), "my-term")
	tmp, _ := os.temp_directory(context.temp_allocator)
	dir := fmt.tprintf("%s/tk_terminal_%d", tmp, os.get_pid())
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	testing.expect_value(t, terminal_program(dir, ""), "")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/xterm", dir), []u8{}) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/kitty", dir), []u8{}) == nil)
	testing.expect_value(t, terminal_program(fmt.tprintf("/nowhere:%s", dir), ""), "kitty")
}
