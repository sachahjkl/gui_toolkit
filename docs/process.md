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

## Children

```odin
r := process.run({"git", "status", "--porcelain"}, {dir = repo}, context.temp_allocator)   // waits for its end
if r.ok { use(r.stdout) } else { log.errorf("git: %s", r.stderr) }
r = process.run({"pkexec", "tee", path}, {input = text})                                  // its standard input
p, err := process.start({command = {"ffmpeg", ...}, stdin = read})                        // the child, to wait for later
```

Starting a process is not safe from two threads at once (Linux's fork, Windows' inheritable handles). `start`, `run` and
`pipe` hold one lock of the package, around the spawn only: a long child never holds up another start. Use them for
every child; do not call `os.process_start`, `os.process_exec` or `os.pipe` for a child. Each is a blocking call
(`base.blocking`): run it on a worker, never on the interface's thread.

| Procedure | |
|---|---|
| `start(desc) -> (os.Process, os.Error)` | starts a child. A bare name is found in the absolute folders of `PATH`, never in the current folder (`Not_Exist` otherwise). On Windows the ends in `desc.stdin`, `stdout` and `stderr` are inheritable during the spawn only, then as they were; the child has no console window and inherits no other handle of the program; a `.bat` or `.cmd` script runs through cmd.exe with quoting it cannot misread (an argument it cannot carry: `Invalid_Command`). In a restricted process (`base.restricted`: elevated) only a full path in an administrator's folder starts; else `io.Error.Permission_Denied` and nothing runs |
| `tree_start(desc) -> (Tree, os.Error)` | starts a child as a process tree (below) |
| `run(command, Run_Options{dir, env, input}, allocator) -> Ran` | starts it and waits for its end. Its standard output and error are read at once (neither blocks the other) and `input` is written on a thread of its own, then closed ("": the null device). `env` is its whole environment (nil: this process's) |
| `ran_destroy(&r, allocator)` | frees `r.stdout` and `r.stderr` |
| `pipe() -> (r, w: ^os.File, os.Error)` | a pipe whose ends no child inherits until `start` gives one to a child |

| `Ran` | |
|---|---|
| `started` | the child started; false: `stderr` says why |
| `ok` | it started and exited with 0 |
| `code` | its exit code; -1 when it did not start or did not exit (a signal) |
| `stdout`, `stderr` | what it wrote, in the allocator given |

A child that ends before it read its input makes the write fail; `SIGPIPE` is ignored for that, unless the program set
a handler of its own. For a time limit, use `start` and `os.process_wait(p, limit)`, then `os.process_kill`.

### The command's file

`start`, `run` and `tree_start` find a bare name before the spawn, in each absolute folder of `PATH` (the child's
`PATH` when `desc.env` is given, else this process's). An empty or relative entry (`.`) is skipped: it names the
current folder, where a planted `git` would run. On Windows each extension of `PATHEXT` is tried (`.COM;.EXE;.BAT;.CMD`
when unset): `gemini` finds npm's `gemini.cmd`. A name with a folder in it is the caller's own path. argv[0] stays as the
caller wrote it. The same rule as a pure procedure, for a program that shows what will run:

```odin
path, ok := process.resolve_command("gemini", path_env, pathext, windows = true, exists = my_exists, user = nil)
```

### Windows: command lines, scripts and BatBadBut

A script (`.bat`, `.cmd`) runs through `<system folder>\cmd.exe /e:ON /v:OFF /d /c ""<script>" <args>"`, with the
quoting of Rust's standard library since its fix of CVE-2024-24576: an argument with a character cmd.exe reads is
quoted, `"` is doubled, `%` becomes `%%cd:~,%` (no variable expands). An argument with a line break, a script path with
`"`, `^` or `%`, and a NUL anywhere are refused. A program gets the C runtime's quoting. Both lines are pure and
tested on every system:

```odin
cl, err := process.windows_command_line(`C:\npm\gemini.cmd`, {"gemini", "--acp"}, `C:\Windows\System32`)
// cl.application: C:\Windows\System32\cmd.exe
// cl.line:        cmd.exe /e:ON /v:OFF /d /c ""C:\npm\gemini.cmd" --acp"
// err:            .None, .Nul, .Program_Quote, .Script_Name, .Line_Break
process.is_script(`C:\npm\gemini.cmd`)   // true; trailing dots and spaces dropped, as Windows does
```

## Process trees

A child that starts children (an agent: node, its shells and tools) runs as a tree, which ends whole: at `tree_kill` or
`tree_close`, when its child ends (what the child left running is killed), and when this program ends however it ends
(a crash and a `SIGKILL` included). The design is in
[src/md/features/process-trees.md](../src/md/features/process-trees.md).

```odin
in_r, in_w, _ := process.pipe()
out_r, out_w, _ := process.pipe()
tree, err := process.tree_start({command = {"gemini", "--acp"}, stdin = in_r, stdout = out_w})   // on a worker
os.close(in_r); os.close(out_w)
...
process.tree_signal(&tree, .Terminate)        // to every process of the tree
end, ended := process.tree_wait(&tree, 2 * time.Second)   // 0: only asks; negative: no limit
if !ended { process.tree_kill(&tree) }
process.tree_close(&tree)                     // kills what is left, waits TREE_CLOSE_BOUND at most, releases
```

| `Tree` | |
|---|---|
| `pid` | the child's own pid |
| `process` | what ends with the child: Linux its keeper (below), Windows the child; its `handle` (a pidfd, a process handle) can be waited on with others |
| `ended`, `end` | once `tree_wait` saw the end: `end.code` (the exit code, or the signal when `end.signaled`) |

- **Linux.** `tree_start` starts the program's own executable again as the tree's *keeper* (`--gt-process-keeper`,
  run by `gt:process`'s `@(init)` before `main`: nothing to ship). The keeper forks the child into a session (and a
  process group) of its own with `PR_SET_PDEATHSIG(SIGKILL)`, so no terminal of the program's stops it, then waits
  on the child and on a pipe whose other end only the program holds. The pipe closes when the program ends, however it ends: the keeper kills the group and ends. When the child
  ends, the keeper kills what it left in the group and ends with the child's status. A tree started from a thread
  outlives the thread (`PR_SET_PDEATHSIG` alone follows the forking thread). Not reached: a grandchild that left the
  group by its own `setsid` (a daemon).
- **Windows.** The child is created suspended, put in a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and no
  breakaway, then resumed: every process it starts is in the job, and the job ends when the program does. `Terminate`
  and `Kill` both end the job (Windows has no gentle signal for a process without a console); the other signals are
  not sent (`tree_signal` returns false). `tree_wait` that sees the child's end ends the rest of the job.
- **Elsewhere** the tree is the child alone.

`tree_start` is a blocking call (`base.blocking`): run it on a worker. `gt:rpc` runs its child as a tree
([rpc.md](rpc.md)).

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
