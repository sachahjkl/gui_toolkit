#+build !linux
#+build !windows
package tk_crash

// Other systems: no handler of crashes (install returns false). Sessions are not followed either: with no way to tell a process
// that runs from one that is gone, every start would find an unclean end.

@(private) UNCLEAN_REASON :: "the session ended without a report"

@(private)
install_handler :: proc() -> bool { return false }

@(private)
process_started :: proc(pid: u64) -> (start: u64, alive: bool) { return 0, true }

@(private)
read_build :: proc "contextless" (buf: []u8) -> int { return 0 }
