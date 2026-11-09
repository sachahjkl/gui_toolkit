package tk_desktop

// The XDG Base Directory places the integration reads and writes (freedesktop.org "basedir-spec"). An XDG_* variable is
// used only when it is an absolute path (the specification says a relative value is ignored and the default used); the
// defaults are under the user's home. `Options` overrides each of them for the tests.

import "core:os"
import "core:path/filepath"
import "core:strings"

// $XDG_DATA_HOME, default ~/.local/share: the launcher entry, the icons, the installed copy.
xdg_data_home :: proc(allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env("XDG_DATA_HOME", allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.local/share"}, allocator)
}

// Where a user's executables go so the launcher and the shell find them by name (~/.local/bin, on the default PATH of
// systemd and most distributions). The PATH part of Linux is a link to the program here (`Options.bin_dir` overrides it).
xdg_bin_dir :: proc(allocator := context.temp_allocator) -> string {
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.local/bin"}, allocator)
}

// The user's configuration directory ($XDG_CONFIG_HOME, else ~/.config): its autostart folder starts programs with the
// session (the XDG Autostart specification).
xdg_config_home :: proc(allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env("XDG_CONFIG_HOME", allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.config"}, allocator)
}
