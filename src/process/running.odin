package tk_process

// The processes that run a given file (running_linux.odin, running_windows.odin; elsewhere none): what a program's
// installer ends before it replaces that file. A process is found by the full path of its executable, never by its name:
// two programs may have files of the same name, and only the copy at that path holds the file.
//
//	processes_of      the processes of this user whose executable is the file `exe`, the calling process left out
//	same_executable   whether the system's name of a process's file is the file `exe` (Windows: the case and the
//	                  direction of the slashes do not count, as for the file system; elsewhere the same bytes)

// A process found: its pid and its start time, the pair that signal_process takes (a pid alone may name a new process by
// the time a program acts on it).
Process_Ref :: struct {
	pid:        i32,
	start_time: u64,
}
