#+build !windows
package tk_process

import "core:os"

// (a child inherits only what is put in its place 0, 1 and 2: os.pipe's ends close at exec)
@(private) ends_inherit :: proc(ends: [3]^os.File) -> (before: [3]bool) { return }
@(private) ends_restore :: proc(ends: [3]^os.File, before: [3]bool) {}
@(private) not_inherited :: proc(f: ^os.File) {}
