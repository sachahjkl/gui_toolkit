#+build !windows
package tk_update

import "core:os"

// `next` (the new program, checked) takes the place of `exe`, the running one: made executable and renamed over it; the
// running process keeps its open file.
@(private)
swap_in :: proc(exe, next: string) -> Error {
	_ = os.chmod(next, os.Permissions_Default_File | {.Execute_User, .Execute_Group, .Execute_Other})
	if os.rename(next, exe) != nil { _ = os.remove(next); return .Not_Placed }
	return .None
}
