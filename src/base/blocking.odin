package base

// The interface's thread makes no system call (docs/tasks.md): a disk asleep, a network share, polkit or a D-Bus peer
// that does not answer would freeze the window. Every procedure of the toolkit that waits on the system (a file read or
// written, a process started, a dialog, a D-Bus call, the clipboard read at once) calls blocking first; on a thread that
// builds an interface (ui.begin_build marks it), in a build with the check (TOOLKIT_BLOCKING_CHECK, on in debug builds),
// it is said on the standard error once per call site, and counted (a test reads blocking_count).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sync"

BLOCKING_CHECK :: #config(TOOLKIT_BLOCKING_CHECK, ODIN_DEBUG)

@(private = "file", thread_local) interface_thread: bool
@(private = "file") blocking_seen: int
@(private = "file") blocking_lock: sync.Mutex
@(private = "file") blocking_sites: map[runtime.Source_Code_Location]struct{}

// This thread builds an interface: what blocks is said from now on (ui.begin_build calls it).
interface_thread_mark :: proc "contextless" () { interface_thread = true }

// Whether this thread builds an interface.
on_interface_thread :: proc "contextless" () -> bool { return interface_thread }

// A call that waits on the system is about to be made (`what`: its name). On an interface's thread, with the check, it
// is said once per call site of the caller and counted.
when BLOCKING_CHECK {
	blocking :: proc(what: string, loc := #caller_location) {
		if !interface_thread { return }
		sync.atomic_add(&blocking_seen, 1)
		sync.lock(&blocking_lock)
		defer sync.unlock(&blocking_lock)
		if blocking_sites == nil { blocking_sites = make(map[runtime.Source_Code_Location]struct{}, runtime.heap_allocator()) }
		if loc in blocking_sites { return }
		blocking_sites[loc] = {}
		fmt.eprintfln("toolkit: %s on the interface's thread (%s:%d): it can freeze the window; make it a task (ui.task)", what, loc.file_path, loc.line)
		_ = os.flush(os.stderr)
	}
} else {
	blocking :: #force_inline proc(what: string, loc := #caller_location) {}
	_ :: fmt
	_ :: os
}

// How many blocking calls the interface's threads made (with the check; 0 without).
blocking_count :: proc "contextless" () -> int { return sync.atomic_load(&blocking_seen) }
