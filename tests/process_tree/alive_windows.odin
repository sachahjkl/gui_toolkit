#+build windows
package process_tree_test

import win "core:sys/windows"
import "core:time"

@(private)
alive :: proc(pid: int) -> bool {
	return !ends_within(pid, 0)
}

// Whether the process `pid` has ended, or ends within `bound`.
@(private)
ends_within :: proc(pid: int, bound: time.Duration) -> bool {
	h := win.OpenProcess(win.SYNCHRONIZE, false, win.DWORD(pid))
	if h == nil { return true }
	defer win.CloseHandle(h)
	return win.WaitForSingleObject(h, win.DWORD(time.duration_milliseconds(bound))) == win.WAIT_OBJECT_0
}
