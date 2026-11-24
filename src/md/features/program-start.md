# A program's start

Every program opened its log, installed its crash handler, began its session and read the last report, in five lines
that were the same in each, and two of them got the order wrong. `host.program_start` is those lines, once.

## The order, and why it is fixed

1. The log first: the crash handler is given the log's tail (`tk_log.tail`) as a Source, so the log must exist.
2. The crash handler, before any thread: a thread started earlier crashes with no report.
3. `begin_session`, then `last_report`. `begin_session` turns a session of a dead process that left no report (a kill, a
   power cut) into an "unclean" report; read before it, `last_report` misses that report. One program read the report first.
4. The warning with the report's path goes to the log the call just made.

## Where it lives

In `host`. It imports `log` and `crash`, which import neither `host` nor `ui`: no cycle. `crash` does not import the log
on purpose (its handler takes Sources), so it cannot hold this procedure. A package of its own would add an import to
every program for two procedures; every program with a window imports `host` already.

`crash_bar.init` stays the program's line: the bar is a part of its window, made when its App exists, and some programs
pass the path to a run procedure first. `program_start` gives the path (`last_crash`, owned) and nothing else.

## Options that exist for one program

- `no_session`: classeur's torn-off tab runs in a process of its own; its end is not the program's end, and the main
  process says the last crash.
- `settings`: cliche puts its changed settings in a report.
- `quiet`: cliche echoes its log on standard error only in a debug build.
- `dir`: a test's folder, so the test runs the real sequence in a child process without touching the user's folders.

## Restart after exit

"Restart now" after an update starts the new copy of the program once this one has ended. Six programs kept a
`launch_after` field and called `setup.launch` at their end, each in its own place. `host.restart_after_exit(&p, args)`
asks for it, and `program_end` does it.

- **The path is read at the start.** `program_start` keeps `process.executable_path()` in `Program_Start.executable`.
  An update moves the running file to `<exe>.old` and puts the new program at `<exe>`. On Linux `/proc/self/exe`
  then names `<exe>.old`: a path read at the restart starts the old program again.
- **`program_end` owns it, not `host_close`.** Only `program_end` runs after the program let go of its single
  instance and after `prefs_page.install_launch`. A copy started earlier finds this one still running and hands
  itself over to it. `host_close` runs once per window (classeur closes several), and the instance is released after
  the last one, by the program.
- **The order in `program_end`.** The session ends, then the program starts again, then the log closes. A new process
  that started before the session ended could read this one's open session as a crash. A failed start is logged, so
  the log closes last.
- **The program still quits by itself.** The toolkit cannot end a program's loop. "Restart now"
  (`Page_Options.restart`, `update_badge`) stays the program's procedure: it calls `restart_after_exit`, then quits as
  on any quit. A `Updates_Options` field that does both was refused: it would need the program's quit as a procedure
  too, for one line less.
- **`Program_Start_Options.launch`** replaces `setup.launch` for a test. `tests/host` records the path and the args of
  an end in the test's process, and starts a real program again in a child to see the order: the new process reports
  no crash.

## Frames after a change

`Host.after_input` was 0 by default and every program set it to its own `FRAMES_AFTER_INPUT :: 3`, then wrote
`h.settle = max(h.settle, FRAMES_AFTER_INPUT)` after each change that came with no event. The host now sets
`AFTER_INPUT` (3) when the program did not set a count, and `host_settle(h)` is that line. A program that wants another
count sets the field; the constant leaves the programs.
