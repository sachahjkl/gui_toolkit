#+build !windows
#+build !linux
package tk_desktop

@(private)
open_terminal_native :: proc(dir: string) -> bool { return false }
