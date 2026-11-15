# process: the program's process, and the others

`import process "gt:process"` (or the relative path of the submodule). The package is named `tk_process`. Pure Odin and the
system's own calls, any target.

```odin
args := process.command_line_args()     // the arguments without the program's name, as UTF-8
exe := process.executable_path()        // "" when the system cannot say
dir := process.parent_dir(exe)          // "" when the path has no folder; '\' and '/' both separate
process.console_write("done\n")         // the standard output
process.console_error("failed\n")       // the standard error output
```

On Windows `os.args` comes from the C runtime's narrow argv, in the system's ANSI code page: a path with a letter outside it
arrives damaged. `command_line_args` reads the UTF-16 command line instead.

A Windows program with a window has no console of its own. `console_write` writes to the standard output when the parent gave
it one (a redirection to a file, a pipe), else to the console of the process that started it, attached once. A redirection
is never bypassed.

## Other processes

A process is named by its pid and its start time: the system gives a pid again once its process ends, so a pid alone can
name a new process by the time a program acts on it. Linux has every call. Windows has `process_start_time` (the
creation time, a FILETIME), `signal_process` with `Terminate` and `Kill` (both `TerminateProcess`: Windows has no
signals) and `processes_of`; its other calls answer `.Unsupported`, as every call does elsewhere.

### The processes that run a file

```odin
for p in process.processes_of(installed_exe, context.temp_allocator) {   // []Process_Ref{pid, start_time}
	process.signal_process(p.pid, p.start_time, .Terminate)
}
```

`processes_of(exe)` lists this user's processes whose executable is the file `exe`, by its full path, never by its name:
two programs may have files of the same name, and only the copy at that path holds the file (an installer ends them
before it replaces it). The calling process is left out. A process of another user, or one the system does not let this
user open, is left out too. Linux reads `/proc/<pid>/exe`: a process whose file was replaced since it started reads
`<path> (deleted)` and is not found (it no longer holds the file at that path). Windows takes a snapshot of the processes
(`CreateToolhelp32Snapshot`) and reads each one's image (`QueryFullProcessImageNameW`); the case and the direction of
the slashes do not count there. `same_executable(found, exe)` is that comparison.

```odin
start, ok := process.process_start_time(pid)          // Linux: clock ticks after the boot (field 22 of /proc/<pid>/stat)
r, errno := process.signal_process(pid, start, .Terminate)
r, errno = process.set_priority(pid, start, 5)       // the nice value, for every thread
cpus, r, errno := process.affinity(pid, start)       // the logical processors it may run on (a Cpu_Set)
process.cpu_set_put(&cpus, 3, false)                 // not on processor 3
r, errno = process.set_affinity(pid, start, cpus)    // for every thread; an empty set is refused (Failed, EINVAL)
```

| `Act_Result` | What it means |
|---|---|
| `Done` | sent or set |
| `Gone` | the process ended, or its pid names another process now: nothing was done |
| `Denied` | the process is another user's, or a higher priority needs privileges (`EPERM`, `EACCES`) |
| `Failed` | another error: `errno` says which |
| `Unsupported` | not on this system |

`Signal` is `Terminate` (SIGTERM), `Kill` (SIGKILL), `Stop` (SIGSTOP), `Continue` (SIGCONT), `Hangup` (SIGHUP),
`Interrupt` (SIGINT), `Quit` (SIGQUIT), `User1` (SIGUSR1) or `User2` (SIGUSR2).

How it acts on Linux: `pidfd_open` pins the process, and so does a descriptor of its folder `/proc/<pid>`: once the
process ends, every read through that folder fails, even when the pid names a new process. The start time is read
through the folder; only when it is the same does `pidfd_send_signal` send the signal. `set_priority` and `set_affinity`
pin the process the same way, list its threads through the same folder (`task`) and call `setpriority` or
`sched_setaffinity` for each: a priority and an affinity are each thread's, and the call on the pid alone sets the main
thread's. A thread that ends while the list is read is skipped. Then the pidfd says whether the process still runs: when
it ended in between, its thread ids may name another process's threads, and the answer is `Gone`. `Cpu_Set` holds up to
`CPU_SET_MAX` (1024) processors: `cpu_set_has`, `cpu_set_put`, `cpu_set_count`. `parse_start_time(stat)` reads the start time of a `stat` line (pure, any target).
