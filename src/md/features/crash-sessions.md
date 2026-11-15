# Crash sessions (`gt:crash`)

A program learns at its start that its last run ended badly: a crash wrote a report, or nothing did (a kill, the
out-of-memory killer, a power cut). The second case needs a trace that the run leaves while it runs and removes when it
ends: the session file.

## Decisions

- **One session file per process**: `session-<pid>.txt` in the report folder, its process id and its start. Two
  instances of a program run at the same time (two windows, a test instance beside the person's). One shared file was
  overwritten by the second instance, so a crash of the first went unreported, and a clean end of either removed the
  trace of the other while it still ran.
- **A start reads every session file.** A file whose process is gone, or whose process id now names another process
  (its start differs), gets an `unclean` report and is removed. The file of a process that still runs is left alone.
  A name that starts with `session` and ends with `.txt` is a session file, so the single file of an older version is
  read the same way.
- **An end removes only its own file**: a clean end, and the crash handler, which knows its path from `install` (the
  handler allocates nothing).
- **"Seen" is the start of the session that ended cleanly, not its end.** `last_report` gives the newest report newer
  than `clean-end.txt`. A session saw, at its start, every report written before it began (the crash bar shows it then).
  A report written while it ran is another instance's crash, and it saw nothing of it. So the clean end renames its own
  session file to `clean-end.txt`: the file keeps its time, the start. When that start is older than the time
  `clean-end.txt` has, the newer one stays (an instance that began earlier and ended later says nothing new).

## Refused

- **A lock file per program** (one instance owns the session): a second instance would have no trace at all, and a
  stale lock after a crash is the same problem again.
- **The end's time in `clean-end.txt`**: it hid the crash report of an instance that crashed while another one ran and
  then ended cleanly.

## Subtle points

- Only `fsx` stamps are compared, never a clock read in the program and a file's time: the rename keeps the stamp the
  file system gave when the session began.
- The test of the design runs real child processes: one holds its session while another crashes, then ends cleanly;
  the next start still gives the crash.
