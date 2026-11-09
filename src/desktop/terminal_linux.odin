package tk_desktop

import "core:os"
import "core:strings"
import "../platform"

// The terminals tried, most specific first: a desktop's own before the plain ones.
@(private = "file", rodata)
TERMINALS := [?]string{
	"xdg-terminal-exec", "foot", "kitty", "alacritty", "wezterm", "ghostty", "gnome-terminal", "kgx", "konsole",
	"xfce4-terminal", "tilix", "terminator", "lxterminal", "mate-terminal", "urxvt", "st", "xterm",
}

// The terminal to start: $TERMINAL when it is set, else the first of TERMINALS on the PATH. "" none.
@(private)
terminal_program :: proc(path_list: string, env_terminal: string) -> string {
	if env_terminal != "" { return env_terminal }
	for name in TERMINALS {
		for dir in strings.split(path_list, ":", context.temp_allocator) {
			if dir == "" { continue }
			if os.is_file(strings.concatenate({dir, "/", name}, context.temp_allocator)) { return name }
		}
	}
	return ""
}

@(private)
open_terminal_native :: proc(dir: string) -> bool {
	path_list, _ := os.lookup_env("PATH", context.temp_allocator)
	env_terminal, _ := os.lookup_env("TERMINAL", context.temp_allocator)
	term := terminal_program(path_list, env_terminal)
	if term == "" || !os.is_dir(dir) { return false }
	// (started in the folder: a terminal opens its shell where it starts)
	return platform.launch_detached({"sh", "-c", `cd "$0" || exit 1; exec "$@"`, dir, term})
}
