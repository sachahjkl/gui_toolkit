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
name a new process by the time a program acts on it. Linux only for now; elsewhere each call answers `.Unsupported`.

```odin
start, ok := process.process_start_time(pid)          // Linux: clock ticks after the boot (field 22 of /proc/<pid>/stat)
r, errno := process.signal_process(pid, start, .Terminate)
r, errno = process.set_priority(pid, start, 5)       // the nice value, for every thread
```

| `Act_Result` | What it means |
|---|---|
| `Done` | sent or set |
| `Gone` | the process ended, or its pid names another process now: nothing was done |
| `Denied` | the process is another user's, or a higher priority needs privileges (`EPERM`, `EACCES`) |
| `Failed` | another error: `errno` says which |
| `Unsupported` | not on this system |

`Signal` is `Terminate` (SIGTERM), `Kill` (SIGKILL), `Stop` (SIGSTOP), `Continue` (SIGCONT), `Hangup` (SIGHUP) or
`Interrupt` (SIGINT).

How it acts on Linux: `pidfd_open` pins the pid (while the descriptor is open, the pid cannot name another process);
the start time is read again from `/proc/<pid>/stat`; only when it is the same does `pidfd_send_signal` send the signal.
`set_priority` pins the process the same way, then calls `setpriority` for each thread of `/proc/<pid>/task`: the nice
value is each thread's, and `setpriority` on the pid alone sets the main thread's. A thread that ends while the list is
read is skipped. `parse_start_time(stat)` reads the start time of a `stat` line (pure, any target).
