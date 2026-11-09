package tk_desktop

// A terminal opened in a folder ("Open a terminal here"). Linux: $TERMINAL, else xdg-terminal-exec, else the first of
// the common terminals found on the PATH, started in the folder (they open their shell where they start). Windows:
// Windows Terminal (wt -d), else the command prompt in the folder.

// Opens a terminal in `dir`. False when none can start.
open_terminal :: proc(dir: string) -> bool {
	return open_terminal_native(dir)
}
