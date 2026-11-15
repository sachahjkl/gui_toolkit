package tk_site

import "core:fmt"

// A process ended by its number (os.process_open does not ask for the right to end what it opens).
@(private)
site_kill :: proc(pid: int) { run_quiet({"taskkill", "/F", "/PID", fmt.tprintf("%d", pid)}) }
