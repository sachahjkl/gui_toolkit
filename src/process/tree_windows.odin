package tk_process

// The tree on Windows (process-trees.md, "Windows: a Job Object per tree"): the child is created suspended, put in a job
// of its own that ends every process in it when its last handle closes, then resumed. The job's handle is not
// inheritable: it is this program's alone, and its end closes it.

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import base "../base"

foreign import kernel32_tree "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_tree {
	CreateJobObjectW :: proc(attributes: ^win.SECURITY_ATTRIBUTES, name: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject :: proc(job: win.HANDLE, class: i32, info: rawptr, size: win.DWORD) -> win.BOOL ---
	AssignProcessToJobObject :: proc(job, process: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(job: win.HANDLE, exit_code: win.UINT) -> win.BOOL ---
}

@(private = "file") JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
@(private = "file") JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
// The exit code of the processes that tree_kill ends (Task Manager's).
@(private = "file") KILLED_EXIT_CODE :: 1

@(private = "file")
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: win.LARGE_INTEGER,
	PerJobUserTimeLimit:     win.LARGE_INTEGER,
	LimitFlags:              win.DWORD,
	MinimumWorkingSetSize:   win.SIZE_T,
	MaximumWorkingSetSize:   win.SIZE_T,
	ActiveProcessLimit:      win.DWORD,
	Affinity:                win.ULONG_PTR,
	PriorityClass:           win.DWORD,
	SchedulingClass:         win.DWORD,
}

@(private = "file")
IO_COUNTERS :: struct {
	ReadOperationCount, WriteOperationCount, OtherOperationCount: u64,
	ReadTransferCount, WriteTransferCount, OtherTransferCount:    u64,
}

@(private = "file")
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                IO_COUNTERS,
	ProcessMemoryLimit:    win.SIZE_T,
	JobMemoryLimit:        win.SIZE_T,
	PeakProcessMemoryUsed: win.SIZE_T,
	PeakJobMemoryUsed:     win.SIZE_T,
}

#assert(size_of(JOBOBJECT_EXTENDED_LIMIT_INFORMATION) == 144 || size_of(rawptr) != 8)

tree_start :: proc(desc: os.Process_Desc, loc := #caller_location) -> (t: Tree, err: os.Error) {
	base.blocking("process.tree_start", loc)
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()   // (as start)
	if len(desc.command) == 0 { return {}, os.General_Error.Invalid_Command }
	if !base.may_start(desc.command[0]) {
		fmt.eprintfln("process.tree_start: %s refused: %s", desc.command[0], base.restricted_reason())
		return {}, io.Error.Permission_Denied
	}
	resolved, found := resolve(desc.command[0], desc.env)
	if !found { return {}, os.General_Error.Not_Exist }
	job := CreateJobObjectW(nil, nil)
	if job == nil { return {}, os.Platform_Error(win.GetLastError()) }
	// (no breakaway flag: a process of the tree that asks to leave the job is refused)
	limits := JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, &limits, size_of(limits)) {
		e := win.GetLastError()
		win.CloseHandle(job)
		return {}, os.Platform_Error(e)
	}
	ends := [3]^os.File{desc.stdin, desc.stdout, desc.stderr}
	sync.lock(&start_lock)
	before := ends_inherit(ends)
	process, thread, pid, cerr := create_process(desc, resolved, true)
	ends_restore(ends, before)
	sync.unlock(&start_lock)
	if cerr != nil {
		win.CloseHandle(job)
		return {}, cerr
	}
	if !AssignProcessToJobObject(job, process) {
		e := win.GetLastError()
		win.TerminateProcess(process, KILLED_EXIT_CODE)
		win.CloseHandle(thread)
		win.CloseHandle(process)
		win.CloseHandle(job)
		return {}, os.Platform_Error(e)
	}
	if win.ResumeThread(thread) == ~win.DWORD(0) {
		// (a child left suspended would hold its pipes until the program ends: the job ends it now)
		e := win.GetLastError()
		TerminateJobObject(job, KILLED_EXIT_CODE)
		win.CloseHandle(thread)
		win.CloseHandle(process)
		win.CloseHandle(job)
		return {}, os.Platform_Error(e)
	}
	win.CloseHandle(thread)
	return Tree{process = {pid = int(pid), handle = uintptr(process)}, pid = int(pid), keep = uintptr(job)}, nil
}

// Windows has no signal: Terminate and Kill end the job, the others are not sent.
tree_signal :: proc(t: ^Tree, sig: Signal) -> bool {
	if t.keep == TREE_GONE || (sig != .Terminate && sig != .Kill) { return false }
	return bool(TerminateJobObject(win.HANDLE(t.keep), KILLED_EXIT_CODE))
}

tree_kill :: proc(t: ^Tree) {
	if t.keep == TREE_GONE { return }
	TerminateJobObject(win.HANDLE(t.keep), KILLED_EXIT_CODE)
}

// The child's end; then what it left running in the job is ended (no keeper sees the end before the program does).
tree_wait :: proc(t: ^Tree, timeout: time.Duration) -> (end: Tree_End, ended: bool) {
	if t.ended { return t.end, true }
	if t.process.handle == 0 { return }
	ms := win.INFINITE
	if timeout >= 0 { ms = win.DWORD(min(time.duration_milliseconds(timeout), f64(win.INFINITE - 1))) }
	if win.WaitForSingleObject(win.HANDLE(t.process.handle), ms) != win.WAIT_OBJECT_0 { return }
	code: win.DWORD
	win.GetExitCodeProcess(win.HANDLE(t.process.handle), &code)
	t.end = {code = int(code)}
	t.ended = true
	tree_kill(t)
	return t.end, true
}

tree_close :: proc(t: ^Tree) {
	tree_kill(t)
	if !t.ended { _, _ = tree_wait(t, TREE_CLOSE_BOUND) }
	if t.keep != TREE_GONE {
		win.CloseHandle(win.HANDLE(t.keep))
		t.keep = TREE_GONE
	}
	if t.process.handle != 0 {
		win.CloseHandle(win.HANDLE(t.process.handle))
		t.process.handle = 0
	}
}
