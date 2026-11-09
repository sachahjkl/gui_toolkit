#+build windows
package tk_console_launcher

import win "core:sys/windows"
import "core:testing"

foreign import shell32 "system:Shell32.lib"

@(default_calling_convention = "system", private = "file")
foreign shell32 {
	CommandLineToArgvW :: proc(command_line: win.LPCWSTR, argc: ^win.c_int) -> [^]win.LPWSTR ---
}

// The command line is read back by CommandLineToArgvW, as the program reads its own.
@(test)
command_line_round_trips :: proc(t: ^testing.T) {
	cases := [?][]string{
		{},
		{"list", "20"},
		{"plain", "with space", "", "quo\"te", `back\slash`, `trailing\`, `trailing space\ `, `q\"uote`, `\\"x`, "tab\tx", `C:\Program Files\App\`, "é 日本"},
	}
	exe := `C:\Program Files\App\app.exe`
	for args in cases {
		line := command_line(exe, args)
		argc: win.c_int
		argv := CommandLineToArgvW(win.utf8_to_wstring(line, context.temp_allocator), &argc)
		testing.expect(t, argv != nil)
		if argv == nil { continue }
		defer win.LocalFree(rawptr(argv))
		testing.expect_value(t, int(argc), len(args) + 1)
		if int(argc) != len(args) + 1 { continue }
		for i in 0 ..< int(argc) {
			s, _ := win.wstring_to_utf8(win.wstring(argv[i]), -1, context.temp_allocator)
			want := i == 0 ? exe : args[i - 1]
			testing.expectf(t, s == want, "argument %d: %q, want %q (line %s)", i, s, want, line)
		}
	}
}
