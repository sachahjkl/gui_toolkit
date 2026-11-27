#+build !linux
#+build !windows
package process_tree_test

import "core:time"

// (process trees are Linux's and Windows'; elsewhere the tests only compile)
@(private)
alive :: proc(pid: int) -> bool { return false }

@(private)
ends_within :: proc(pid: int, bound: time.Duration) -> bool { return true }
