#+build !linux
package tk_process

// Other processes are Linux's only so far: every call answers .Unsupported here.

process_start_time :: proc(pid: i32) -> (start: u64, ok: bool) { return }
signal_process :: proc(pid: i32, start_time: u64, sig: Signal) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
set_priority :: proc(pid: i32, start_time: u64, nice: int) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
