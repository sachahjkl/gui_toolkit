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

// The user's cache directory ($XDG_CACHE_HOME, else ~/.cache): the shared thumbnails are under its thumbnails folder.
xdg_cache_home :: proc(allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env("XDG_CACHE_HOME", allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	return strings.concatenate({home, "/.cache"}, allocator)
}

// The user's desktop folder: $XDG_DESKTOP_DIR, else the one of user-dirs.dirs ($XDG_CONFIG_HOME/user-dirs.dirs, written by
// xdg-user-dirs: `XDG_DESKTOP_DIR="$HOME/Bureau"` on a French desktop), else ~/Desktop.
xdg_desktop_dir :: proc(allocator := context.temp_allocator) -> string {
	if v, ok := os.lookup_env("XDG_DESKTOP_DIR", allocator); ok && filepath.is_abs(v) { return v }
	home, err := os.user_home_dir(allocator)
	if err != nil || home == "" { return "" }
	if config := xdg_config_home(context.temp_allocator); config != "" {
		if data, rerr := os.read_entire_file(strings.concatenate({config, "/user-dirs.dirs"}, context.temp_allocator), context.temp_allocator); rerr == nil {
			if dir, found := user_dirs_desktop(string(data), home); found { return strings.clone(dir, allocator) }
		}
	}
	return strings.concatenate({home, "/Desktop"}, allocator)
}

// XDG_DESKTOP_DIR of a user-dirs.dirs text, $HOME made `home` (temp memory). Not found: a line it does not have, or a
// value that is neither "$HOME/..." nor absolute (the format allows only these two).
user_dirs_desktop :: proc(text, home: string) -> (dir: string, found: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if !strings.has_prefix(l, "XDG_DESKTOP_DIR=") { continue }
		v := strings.trim(l[len("XDG_DESKTOP_DIR="):], "\"")
		if strings.has_prefix(v, "$HOME") { return strings.concatenate({home, v[len("$HOME"):]}, context.temp_allocator), true }
		if strings.has_prefix(v, "/") { return v, true }
		return "", false
	}
	return "", false
}
