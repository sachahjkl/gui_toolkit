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

## Frames after a change

`Host.after_input` was 0 by default and every program set it to its own `FRAMES_AFTER_INPUT :: 3`, then wrote
`h.settle = max(h.settle, FRAMES_AFTER_INPUT)` after each change that came with no event. The host now sets
`AFTER_INPUT` (3) when the program did not set a count, and `host_settle(h)` is that line. A program that wants another
count sets the field; the constant leaves the programs.
