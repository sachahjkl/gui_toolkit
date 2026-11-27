# Child processes

A program runs other programs: git, nix, `journalctl`, `gio`, a thumbnailer, ffmpeg, a plugin's process, its own
installed copy. `gt:process` starts them: `start` gives the child, `run` waits for its end and gives its output, `pipe`
makes a pipe for a child.

## One lock, around the spawn only

Starting a process is not safe from two threads at once:

- **Linux.** `os.process_start` forks. The child gets a copy of the memory as it is at that moment. If another thread
  holds a lock (the allocator's, the runtime's), the child waits for it before `exec`, and that lock never opens. Two CI
  runs stopped on an illegal instruction in `tests/process` while another test started a child.
- **Windows.** `CreateProcess` with `bInheritHandles` gives the child every inheritable handle of the process.
  `os.pipe` makes both ends inheritable. A child started on another thread meanwhile holds a pipe end that was made for
  someone else. The reader of that pipe then never sees its end: a plugin stayed "Starting" for ever.

So every start goes through `process.start`, which holds one lock of the package. socle and atelier each had a lock of
their own; inspecteur, classeur and the toolkit's `desktop` had none. Two locks are no lock: the one lock lives in the
lowest package that every start can import.

The lock covers the spawn only, never the wait. socle's `run` held its lock across `os.process_exec`, so a `nix build`
of ten minutes held up every other start of the program. `run` takes the lock in `start` and lets go of it before it
reads the output.

## Pipes on Windows

`process.pipe` makes both ends not inheritable, under the same lock. `start` makes the three ends it gives the child
inheritable for the spawn only, then puts each back as it was. A pipe end is thus inheritable only while its own child
starts. The plugins' `pipe_not_inherited` and the lock they held around their pipes are this, in one place.

An end that the caller opened inheritable on purpose (toolbox's log file, `.Inheritable`) stays inheritable, but
reaches only the child it is given to: `CreateProcessW` gets a list of the three handles to inherit
(`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`, [process-trees.md](process-trees.md)), and no other handle passes.

On Linux `os.pipe` sets close-on-exec, and the child gets only what is put in its places 0, 1 and 2.

## The spawn itself

`start` does not call `os.process_start` on Linux and Windows. It finds a bare name in `PATH` itself (never in the
current folder), and spawns with its own fork and exec (Linux) or its own `CreateProcessW` (Windows: the application
name given, no console window, a `.bat` or `.cmd` script quoted for cmd.exe). Why, and the rules:
[process-trees.md](process-trees.md).

## `run`

- Its standard output and its standard error are read at the same time, one of them on a thread. A child that fills
  the pipe of the one not read waits for ever. `os.process_exec` polls the two pipes in a loop that never sleeps.
- Its input (`Run_Options.input`) is written on a thread of its own and then closed. A child can answer before it read
  all of its input. A child that ends before it read it makes the write fail: `SIGPIPE` is ignored, as
  `platform.sigpipe_ignore` does, unless the program set a handler of its own.
- An empty input is the null device, not a pipe: a child that reads its input gets its end at once.
- `Ran.code` is -1 when the child did not start or did not exit (a signal). `Ran.started` says which. When it did not
  start, `Ran.stderr` says why.
- `start` and `run` call `base.blocking`: a fork or a `CreateProcess` can take tens of milliseconds, and a run waits
  for the child. They run on a worker.

## Refused

- **A lock per caller.** Two locks do not exclude each other.
- **The lock around the wait.** One long child holds up every start.
- **`os.process_exec`.** Its pipes are inheritable on Windows, it starts outside the lock, and it spins while it waits.
- **A timeout in `Run_Options`.** One caller needs one (the thumbnailer), and it uses `start` with
  `os.process_wait(p, limit)`.

## The test that breaks it

`tests/process_start`: twelve threads run six children each at once, the test program itself started again. A
package of tests/, not a test file of `src/process`: its `@(init)` (the child's mode) would run in every program that
imports `gt:process`. `tests/globals` refuses an `@(init)` in a test file of `src`.
Each child writes its own argument and input on its standard output and error and exits with its own code. Every
result must be its own child's, no memory is left (a tracking allocator per thread), and on Linux no descriptor is
left open. A second test runs a child that waits on another thread, and a quick child must start and end meanwhile.
