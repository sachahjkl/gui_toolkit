package tk_process

// Other processes on Windows: a start time (the process's creation time) and an end (TerminateProcess). Windows has no
// signals: Terminate and Kill both end the process at once, the others are not here. A priority and an affinity are not
// here yet. The process is opened, then its creation time must be the one given: a handle names one process for as long
// as it is open, so the check and the act are on the same process.

import win "core:sys/windows"

// The exit code of a process ended by signal_process: what Windows' own Task Manager gives.
@(private = "file") TERMINATED_EXIT_CODE :: 1

process_start_time :: proc(pid: i32) -> (start: u64, ok: bool) {
	if pid <= 0 { return }
	h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return }
	defer win.CloseHandle(h)
	return creation_time(h)
}

signal_process :: proc(pid: i32, start_time: u64, sig: Signal) -> (r: Act_Result, errno: int) {
	if sig != .Terminate && sig != .Kill { return .Unsupported, 0 }
	if pid <= 0 { return .Gone, 0 }
	h := win.OpenProcess(win.PROCESS_TERMINATE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return result_of_error(win.GetLastError()) }
	defer win.CloseHandle(h)
	start, ok := creation_time(h)
	if !ok || start != start_time { return .Gone, 0 }
	if !win.TerminateProcess(h, TERMINATED_EXIT_CODE) { return result_of_error(win.GetLastError()) }
	return .Done, 0
}

set_priority :: proc(pid: i32, start_time: u64, nice: int) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }
affinity :: proc(pid: i32, start_time: u64) -> (cpus: Cpu_Set, r: Act_Result, errno: int) { return {}, .Unsupported, 0 }
set_affinity :: proc(pid: i32, start_time: u64, cpus: Cpu_Set) -> (r: Act_Result, errno: int) { return .Unsupported, 0 }

@(private = "file")
result_of_error :: proc(e: win.DWORD) -> (Act_Result, int) {
	switch e {
	case win.ERROR_INVALID_PARAMETER: return .Gone, int(e)   // (no process has that pid any more)
	case win.ERROR_ACCESS_DENIED:     return .Denied, int(e)
	}
	return .Failed, int(e)
}
