package tk_desktop

// The XDG places the integration reads and writes that are not a program's standard folders (platform.user_dir) nor the
// person's (platform.known_folder_path: the desktop folder). `Integration_Options` overrides each of them for the tests.

import "core:os"
import "core:strings"

// Where a user's executables go so the launcher and the shell find them by name (~/.local/bin, on the default PATH of
// systemd and most distributions). The PATH part of Linux is a link to the program here (`Integration_Options.bin_dir` overrides it).
xdg_bin_dir :: proc(allocator := context.temp_allocator) -> string {
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.local/bin"}, allocator)
}
