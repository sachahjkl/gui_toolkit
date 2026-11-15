#+build !windows
package tk_toolbox

import "core:os"

// A program of the system (curl, unzip): the one on the PATH.
system_program :: proc(name: string) -> string { return name }

// What a stamp file ends with.
STAMP_NEWLINE :: "\n"
// What a program's -extra-linker-flags must hold for its reports to be named: the build id.
CRASH_LINKER_FLAGS :: "-Wl,--build-id"
// The target the crates are linked for: this system's.
NOTICES_TARGET :: "x86_64-unknown-linux-gnu"

// The exit code of a finished process; -1 when it did not exit.
exit_code :: proc(state: os.Process_State) -> int {
	if !state.exited { return -1 }
	return state.exit_code
}
