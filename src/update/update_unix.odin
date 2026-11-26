#+build !windows
package tk_update

import "core:os"
import "core:strings"
import "core:sys/posix"

// `next` (the new program, checked) takes the place of `exe`, the running one: made executable and renamed over it; the
// running process keeps its open file.
@(private)
swap_in :: proc(exe, next: string) -> Error {
	_ = os.chmod(next, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other})
	if os.rename(next, exe) != nil { _ = os.remove(next); return .Not_Placed }
	return .None
}

// This process may create a file in `dir` (the program's folder): asked of the system, nothing is written. False for an
// install for everyone (/opt), which only root writes.
@(private)
folder_takes_files :: proc(dir: string) -> bool {
	if dir == "" { return false }
	return posix.access(strings.clone_to_cstring(dir, context.temp_allocator), {.W_OK, .X_OK}) == .OK
}
