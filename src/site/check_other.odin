#+build !windows
package tk_site

import "core:fmt"

// A process ended by its number.
@(private)
site_kill :: proc(pid: int) { run_quiet({"kill", "-9", fmt.tprintf("%d", pid)}) }
