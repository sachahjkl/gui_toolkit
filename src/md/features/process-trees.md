# Process trees and safe command lines (`process.tree_start`, `process.start`)

## Purpose

An agent is a child that starts children: `gemini` is node, which runs shells and tools; on Windows an npm install is a
`.cmd` shim that runs cmd.exe, which runs node. When the program stops the agent, or crashes, the whole tree must go:
a node left behind holds files, ports and tokens. And on Windows the shim itself is a trap: cmd.exe parses its command
line again with rules of its own (BatBadBut, CVE-2024-24576). `gt:process` handles both for every program.

## A tree: what ends it

A `Tree` is a child and everything it starts. It ends:

- at `tree_kill` or `tree_close`,
- when its root (the child) ends: what the root left running is killed,
- when this program ends, however it ends: a crash and a `SIGKILL` included.

### Linux: a keeper per tree

The child runs in a process group of its own (`setsid`): one `kill(-pgid)` reaches its tree. But when the program is
killed, nothing in it is left to send that signal. `PR_SET_PDEATHSIG` kills only the direct child (a fork clears the
setting, so a grandchild does not have it), and it fires when the *thread* that forked the child ends, not the process:
a child started from a worker dies with that worker.

So each tree has a keeper: a small process between the program and the child.

```
program --(life pipe)--> keeper (the program's executable again, --gt-process-keeper)
                           \--fork--> child (setsid: group = its pid; PDEATHSIG = SIGKILL) --> grandchildren
```

- The keeper is the program's own executable, started again with a hidden argument; `gt:process`'s `@(init)` runs
  it and ends the process before the program's `main` (as `gt:plugins` hosts a plugin). No second binary to ship.
  It holds no copy of the program's memory: a forked copy that does not exec keeps, page by page, every page that the
  program writes after the fork.
- The program holds the write end of the *life pipe*; the keeper polls its read end and the child's pidfd. The pipe
  closes when the program ends by any cause (the kernel closes its descriptors), or when it calls `tree_kill`: the
  keeper then kills the child's group and ends. A byte on the pipe is a signal to send to the group. The keeper sends
  it before it reaps the child, so the group's id cannot name another group yet.
- The child sets `PR_SET_PDEATHSIG(SIGKILL)` between its fork and its exec. Its parent is the keeper, a process of one
  thread: the thread caveat does not apply, and a keeper killed by anyone takes the child with it.
- When the child ends, the keeper kills its group (what it left running), then ends with the child's status: the same
  exit code, or the same signal (the keeper sends it to itself, with no core file). The program waits on the keeper
  and reads the child's end.
- The child's pid comes back on a report pipe, and so does an exec's error: a command that cannot start fails
  `tree_start` with its errno, as `start` does. The keeper reports the pid after the child's exec (a close-on-exec
  pipe of its own), so the child's session exists by then: a `tree_signal` just after `tree_start` reaches it.
- A session, not only a group (`setpgid`): in a group of the program's terminal session that is not in the
  foreground, the child stops (SIGTTIN, SIGTTOU) at its first read of `/dev/tty`, as a git or ssh prompt does, and the
  agent hangs. With a session of its own it has no terminal: that open fails at once.
- The keeper ignores SIGINT, SIGTERM, SIGHUP and SIGQUIT: a Ctrl+C in the program's terminal ends the program, the
  life pipe closes, and the keeper ends the tree. The child gets the default dispositions and an empty signal mask,
  whatever the program's thread had (an ignored SIGPIPE survives an exec).
- What the keeper cannot reach: a grandchild that left the group by its own `setsid` (a daemon). A cgroup would hold
  it; it needs systemd's help and is refused below.

### Windows: a Job Object per tree

- The child is created suspended, assigned to a new job, then resumed: it runs no instruction outside the job, and
  each process that it starts is in the job from its creation.
- The job has `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and neither breakaway flag: a process of the tree that asks for
  `CREATE_BREAKAWAY_FROM_JOB` is refused. The job's handle is the program's alone (not inheritable): when the program
  ends, by any cause, the last handle closes and the system ends every process of the job.
- `tree_kill` is `TerminateJobObject`. Windows has no gentle signal for a process without a console window, so
  `Terminate` is the same act. The gentle stop of an agent is the end of its standard input.

### Elsewhere

macOS and the BSDs get the child alone: `tree_start` is `start`, and `tree_kill` kills the child. No program
drives agents there yet.

## Every start: the name resolved first; on Windows our own CreateProcessW

- **A bare name is found in `PATH`, never in the current folder.** `CreateProcessW` with no application name searches
  the current folder first, and Odin's `os.process_start` on Linux falls back to `./name`: a `git` dropped in a
  folder that the program opens would run. The name is resolved before the spawn, in each absolute folder of `PATH`
  (the child's `PATH` when its environment is given, else the program's). A relative or empty entry of `PATH` names
  the current folder: it is skipped. On Windows each extension of `PATHEXT` (`.COM;.EXE;.BAT;.CMD` when unset) is
  tried, and a name that already ends with one of them is tried as it is first.
- **Windows: the application name is given** to `CreateProcessW`, which then searches nothing.
- **Windows: only the three standard handles are inherited.** `CreateProcessW` must inherit to pass them, and then
  gives every inheritable handle of the program: a pipe end of a library, a log file opened inheritable on purpose. A
  `STARTUPINFOEX` with `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` names the three (each once: a handle listed twice is an
  invalid parameter). The ends are still made inheritable during the spawn only, under the lock: the list accepts only
  inheritable handles.
- **Windows: no console window.** `CREATE_NO_WINDOW`: a program with a window that starts git or node flashes no
  console. A child's three ends are pipes, files or NUL: it has nothing to show in a console.
- **Linux: our own fork and exec.** The keeper needs three more descriptors in the child, which `os.process_start`
  cannot place; plain `start` uses the same spawn, so there is one.

## BatBadBut: a `.bat` or `.cmd` script

`CreateProcessW` runs a script through cmd.exe, which reads the command line with its own rules: `&`, `|`, `>` and
`%VAR%` act even where the C runtime's rules saw a quoted argument. An argument from a person or a file then runs
commands. Rust's standard library fixed it (1.77.2); its rules are followed here, from
`library/std/src/sys/args/windows.rs` (`make_bat_command_line`, `append_bat_arg`):

- The script is known after its name is resolved, by its extension (`.bat`, `.cmd`, any case; trailing dots and
  spaces dropped, as Windows drops them).
- The application is `<system folder>\cmd.exe`, and the line is
  `cmd.exe /e:ON /v:OFF /d /c ""<script>" <args>"`: extensions on (the `%` trick needs them), delayed expansion off
  (`!VAR!` stays text), no AutoRun commands, and the outer quotes that `/c` strips.
- A script path that holds `"`, `^` or `%`, or ends with `\`, is refused.
- An argument that holds `\r` or `\n` is refused: cmd.exe ends the line there.
- An argument is quoted when it is empty, ends with `\`, or holds an ASCII character other than letters, digits and
  `#$*+-./:?@\_`, or a control character.
- Inside, `"` is doubled (the backslashes before it doubled too), and each `%` becomes `%%cd:~,%`: a substring of
  `%cd%` of length zero, then the `%`, so `%PATH%` is never expanded.
- An argument that holds a NUL is refused, for scripts and programs alike.

A program (not a script) gets the C runtime's quoting (Rust's `append_arg`): the program's path always in quotes, an
argument quoted when it is empty or holds a space or a tab, the backslashes doubled before a `"` (which gets one
more) and before the closing quote.

Both are one pure procedure (`windows_command_line`), tested on every system with the inputs of Rust's
`tests/ui/std/windows-bat-args.rs`.

## Refused

- **`PR_SET_PDEATHSIG` alone.** It reaches the child, not its children, and it follows the forking thread.
- **A forked keeper that does not exec.** No exec, but it keeps the program's memory as the program writes it.
- **A cgroup per tree.** It catches even a daemon, but it needs a systemd scope (D-Bus) or a delegated cgroup tree;
  the keeper covers the agents in view.
- **One keeper for every tree.** It saves a process per tree at the cost of a protocol between keeper and program; a
  program has a few trees (agents, servers).
- **`PROC_THREAD_ATTRIBUTE_JOB_LIST`.** Windows 10 only, and the suspended start gives the same: nothing runs outside
  the job.
- **Searching the current folder, the program's folder or the system folders before `PATH`.** The first runs a
  planted binary; the others are `CreateProcessW`'s and Rust's habits, which a person who set `PATH` does not
  expect.

## The test that breaks it

`tests/process_tree`: the test program starts itself as a parent that starts a tree whose child starts a grandchild;
the test kills the parent with SIGKILL, and the child and the grandchild must be gone within a bound. A pure table
checks the command lines of Rust's inputs on every system; Windows' code is compile-checked from Linux.
