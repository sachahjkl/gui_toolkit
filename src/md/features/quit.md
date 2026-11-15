# A running program closed before its install

An installer (atelier, a script, a test) replaces a program's file. A copy of the program may run from that file. On
Windows the file cannot be replaced while a process runs it: the install fails. On Linux the file is replaced, but the
copy that runs keeps the old version until it ends. In both cases the right default is to close the program first, with
the person's agreement, and to close it so that it keeps its work.

## The parts

1. **Whether it runs**: `<program> --status` says `running: true|false` (`Setup_Options.running`, the program's single
   instance: `instance.MESSAGE_PING`). It existed before this work.
2. **Whether it can be asked to end**: `--status` says `quit: yes|no` (`Setup_Options.quit` given or not).
3. **The request**: `<program> --quit` sends `instance.MESSAGE_QUIT` to the copy that runs. Its handler does what its own
   Quit does: the window closes, the work is saved, the process ends. `--quit` then waits, at most `QUIT_WAIT`, until the
   instance is gone and no process runs the installed copy's file. The exit code says whether it ended.
4. **The end for sure**: `process.processes_of(exe)` finds the processes that run the installed file, and
   `process.signal_process(pid, start, .Terminate)` ends them (Linux: SIGTERM; Windows: TerminateProcess).

## Decisions

- **A callback in `Setup_Options`, not a fixed message sent by gt:setup.** Each program owns its single instance's name
  (a channel, a profile) and its handler. `quit` sits beside `running`, which already has that shape. The shared
  constants `MESSAGE_PING` and `MESSAGE_QUIT` make the handlers the same in every program.
- **`quit: yes` in `--status`, read from the installed copy.** The copy that runs must understand the request, not the new
  file that an installer carries. A program built before this work has no `--quit`: a run of `<old program> --quit`
  opens its window or fails. So an installer asks the installed copy's `--status` first, and runs its `--quit` only on
  `quit: yes`. Refused: `--help` that lists `--quit` (a second format to parse, and some programs open a window for an
  unknown option).
- **By the full path of the file, never by the name.** Two programs may share a file name; a copy run from a download
  folder does not hold the installed file. `processes_of` compares the whole path (Windows: case and slashes folded).
- **A pid with its start time.** Between the list and the act, a pid can be given again to a new process.
  `Process_Ref` carries both, and `signal_process` acts only when they still match.
- **`--quit` waits for the processes too, not only for the instance.** A program drops its instance before it has
  ended; on Windows the file stays locked until the process is gone.
- **The process that runs `--quit` is left out.** An installer runs `<installed file> --quit`: that process runs the
  installed file too.

## Subtle points

- On Linux, a process whose file was replaced reads `<path> (deleted)`: it is not found, and it does not hold the new
  file. It still runs the old version: `--quit` closes it through its instance.
- Windows has no signals: `Terminate` and `Kill` are both `TerminateProcess`, at once, with no clean end. That is why the
  request through the instance comes first.
