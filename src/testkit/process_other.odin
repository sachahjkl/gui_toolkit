#+build !windows
#+build !linux
package tk_testkit

// Other platforms: no reader yet (the Windows and Linux ones show how; macOS would use task_info / proc_pidinfo).
@(private)
native_process_state :: proc() -> Process_State { return {} }

@(private)
native_memory_split :: proc() -> Memory_Split { return {} }
