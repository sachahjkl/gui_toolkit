// The arguments of a program on Windows: from the system's own UTF-16, not through the C runtime's code page.
package keyboard_test

import "core:testing"
import win "core:sys/windows"
import "../../platform"

@(test)
arguments_keep_every_character :: proc(t: ^testing.T) {
	line := win.utf8_to_wstring(`prog.exe --search="Łódź Привет" --x=你好 مرحبا "a b"`, context.temp_allocator)
	args := platform.args_from_command_line(line, context.temp_allocator)
	want := []string{"prog.exe", "--search=Łódź Привет", "--x=你好", "مرحبا", "a b"}
	if !testing.expect_value(t, len(args), len(want)) { return }
	for a, i in args { testing.expect_value(t, a, want[i]) }
}
