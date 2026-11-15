#+build !linux
#+build !windows
package tk_process

// Other processes are Linux's and Windows' only so far: every call answers .Unsupported here, and no process is found.

process_start_time :: proc(pid: i32) -> (start: u64, ok: bool) { return }
signal_process :: proc(pid: i32, start_time: u64, sig: Signal) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
set_priority :: proc(pid: i32, start_time: u64, nice: int) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
affinity :: proc(pid: i32, start_time: u64) -> (cpus: Cpu_Set, r: Act_Result, errno: int) { return {}, .Unsupported, 0 }
set_affinity :: proc(pid: i32, start_time: u64, cpus: Cpu_Set) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
same_executable :: proc(found, exe: string) -> bool { return found != "" && found == exe }
processes_of :: proc(exe: string, allocator := context.allocator) -> []Process_Ref { return make([]Process_Ref, 0, allocator) }
