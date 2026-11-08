package tk_testkit

// What the system says of the running process's memory and handles (process_<os>.odin), for endurance and leak tests that
// watch what a tracker cannot see (native libraries, arenas, GPU). Zero for a field the system cannot report.
Process_State :: struct {
	resident:     i64,   // in physical memory now (Windows: the working set; Linux: VmRSS)
	private:      i64,   // the process's own memory (Windows: the private commit charge; Linux: RssAnon + VmSwap)
	handles:      i64,   // kernel handles open (Windows: GetProcessHandleCount; Linux: entries in /proc/self/fd)
	gdi_objects:  i64,   // GDI objects (Windows only; 0 elsewhere)
	user_objects: i64,   // USER objects (Windows only; 0 elsewhere)
}

// A read of the current process's state.
process_state :: proc() -> Process_State { return native_process_state() }

// Where the private bytes are, as the system sees them: what the process heaps hold against what they have committed, and
// the private committed pages outside the heaps by kind: read-write (arenas, linear memories, stacks) and executable
// (compiled code). Windows only for now (zero elsewhere).
Memory_Split :: struct {
	heap_allocated, heap_committed: i64,
	vm_rw, vm_exec:                 i64,   // MEM_PRIVATE | MEM_COMMIT pages (the heaps' segments included)
}

memory_split :: proc() -> Memory_Split { return native_memory_split() }
