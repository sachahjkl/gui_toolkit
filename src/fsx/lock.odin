package fsx

import "core:time"
import base "../base"

// An exclusive lock on a file, between the processes of the person: one holds it, the others wait or give up. The
// system lets go when the process ends, crashed or not, so a lock is never left behind. The file stays: removing it
// while another process opens it would give two holders.
//
// Linux: flock(LOCK_EX), on the open file (two opens in one process exclude each other too). Windows: LockFileEx on its
// first byte. Other systems: no lock (Locked at once).
File_Lock :: struct {
	handle: uintptr,
	held:   bool,
}

Lock_Result :: enum u8 {
	Locked,
	Busy,     // another holds it still at the end of the wait
	Failed,   // the file cannot be opened (no folder, no rights): nothing is locked
}

// How often a wait for a lock tries again.
LOCK_POLL :: 50 * time.Millisecond

// Takes the lock of `path` (made when it is not there), waiting for it at most `wait` (0: one try). Release it with
// file_unlock. It waits on the system: call it from a task, or at a start before any window.
file_lock :: proc(path: string, wait: time.Duration, loc := #caller_location) -> (l: File_Lock, result: Lock_Result) {
	base.blocking("fsx.file_lock", loc)
	start := time.tick_now()
	for {
		l, result = file_lock_try(path)
		if result != .Busy { return }
		if time.tick_since(start) >= wait { return {}, .Busy }
		time.sleep(LOCK_POLL)
	}
}
