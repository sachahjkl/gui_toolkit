# crash: crash reports

`import crash "gt:crash"` (the package is `tk_crash`). Windows and Linux; on other systems `install` returns false.

When a program crashes, it writes a report of the crash as it dies: one text file per crash, in the program's folder. The next
start can learn of it and offer to open or copy the report. Nothing is sent anywhere.

```odin
crash.install({program = "myapp", version = VERSION, commit = COMMIT,
               log_tail = {tk_log.tail, logger.data}, settings = {settings_snapshot, &app.snapshot}})
crash.begin_session()                        // at the start, before the interface's loop
if path, ok := crash.last_report(); ok {     // the last session crashed, or was killed
	// show "it crashed: open the report, copy it"
}
...
crash.end_session()                          // the clean end
```

Importing the package does nothing. A program opts in with the call to `install`.

## Install

`install(o: Options) -> bool` installs the handler of crashes, once for the process. A second call does nothing and returns false.

| `Options` | |
|---|---|
| `program` | the program's name: its report folder and the report's `program` line |
| `version` | the program's version |
| `commit` | the source's commit ("": not known) |
| `report_dir` | "": `default_report_dir(program)`, that is `platform.user_dir(.State, program)/crashes` |
| `minidump` | Windows: a minidump beside each report (`<report>.dmp`, for WinDbg or Visual Studio) |
| `log_tail` | a `Source`: the last lines of the log (`tk_log.tail`, [log.md](log.md)) |
| `settings` | a `Source`: the settings that differ from their default, one per line |

A `Source` is `{text, user}`. `text` is a `Source_Proc :: proc "contextless" (user: rawptr, buf: []u8) -> int`: it copies its
text into `buf` and returns the count of bytes. It runs in the crash handler, on a thread that can hold any lock: it must not
allocate, take a lock or wait. Copy a snapshot that the program keeps up to date (the settings change rarely: keep their text
when they change).

This package imports neither the log nor the configuration. The program joins them with the two Sources.

- Linux: the handler catches SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT and SIGTRAP on an alternate signal stack of 256 KiB (a
  stack overflow on the main thread is reported). It allocates nothing and writes with system calls only. Every other thread
  is asked for its stack with the real-time signal `SIGRTMAX - 2`, and the report waits for them for one second at most. A
  program that uses that signal itself must not use `install`.
- Windows: an unhandled exception filter, and a vectored handler for what never reaches the filter (a heap corruption, a stack
  overflow, a fail-fast, a stack the system cannot walk). A thread made at `install` writes the report while the faulting
  thread waits. Every other thread is suspended in turn and its stack copied. An `ExitProcess` or a `TerminateProcess` of the
  program itself while the session is open leaves an `exit` report with the stack that asked for it.

After the report, the process dies as it would have: a core dump (Linux, when enabled), the exit code and the Application
Error event (Windows).

`default_report_dir(program, allocator) -> string`, `report_dir() -> string` (the folder `install` was given) and
`build_id() -> string` (the running executable's build, as the report names it) complete the API.

## Sessions

`begin_session()` writes `session.txt` in the report folder: the process id and its start. `end_session()` removes it and
writes `clean-end.txt`. When `begin_session` finds a `session.txt` whose process is gone, the last session ended without a
report: the process was killed (the out-of-memory killer, `kill -9`, a watchdog), the machine stopped, or a fail-fast ended it.
`begin_session` then writes an `unclean` report for it. A crash report removes `session.txt` itself.

`last_report(allocator) -> (path: string, ok: bool)` is the newest report written after `clean-end.txt`: the last session
crashed, was killed or ended itself. After the next clean end, `last_report` gives nothing for it again.

`begin_session`, `end_session` and `last_report` read and write files on the calling thread: call them at the start and at the
end, not in a frame.

## The report

`<report_dir>/crash-<yyyymmdd>-<hhmmss>-<pid>.txt` (`unclean-...` and `exit-...` for the other kinds; the date is UTC):

```
gt-crash-report: 1
program: fidget
version: 0.51.0
commit: 1a2b3c4
build: 9f86d081884c7d65
system: linux amd64
date: 2026-11-13T17:03:00Z
pid: 4242
kind: signal
code: SIGSEGV
reason: segmentation fault (an invalid memory access)
address: 0x0
pc: 0x55D0C0DE1234
thread: 4242
[thread 4242]
  name: fidget
  crashed: yes
  #00	0x55D0C0DE1234	fidget	0x1234	?
  #01	0x55D0C0DE0F00	fidget	0xF00	?
[thread 4243]
  name: store
  #00	0x7F0012340000	libc.so.6	0x25000	?
[modules]
  0x55D0C0DE0000	0x5000	fidget	/home/me/fidget
[log]
  2026-11-13T17:02:59.120Z INFO  opened /home/me/a.txt
[settings]
  theme = dark
[symbols]
  0x7F0012340000	futex_wait+0x10
[end]
```

- The first line names the format and its version (`FORMAT_VERSION`). A reader of an older version reads the keys it knows.
- A header line is `key: value`. `kind` is `signal` (Linux), `exception` (Windows), `exit` or `unclean`. `build` is the GNU
  build id of the executable (Linux) or its PE time stamp and image size, `%08X%X` (Windows).
- A section starts with `[name]` at the start of a line. Every line in it is indented by two spaces, so no line of the log
  can start a section.
- A frame is `#<n>`, its address, its module, its offset in the module and its symbol (`?`: not known), separated by tabs. The
  faulting thread comes first.
- `[symbols]` gives the names the system found after the stack was written (exported symbols on Linux, the PDB's on Windows):
  naming can take locks that the crash left held, so the handler names last.
- `[end]` is the last line. A report without it was cut short.

`report_parse(text, allocator) -> (Report, ok)` reads a report. `ok` is false when the text is not a report. The strings of the
`Report` point into `text`; its arrays are in `allocator` (`report_destroy`). The `[symbols]` names go into the `symbol` of the
frames of their address. `report_text(r, allocator) -> string` writes a `Report` as the handler would: the symbolizer writes
its result with it.

## Naming the frames

A release has no debug information beside it, and the program's own functions are not exported: its frames are module offsets.
`tk crash_symbolize <report> <symbols>` names them ([toolbox.md](toolbox.md), "Crash reports"):

- Windows: link with `-extra-linker-flags:/MAP` (`toolbox.CRASH_LINKER_FLAGS`) and call `toolbox.crash_publish_symbols(exe)`
  after each link: it renames the map `<exe stem>-<build>.map`. Keep the map with the release.
- Linux: link with `-extra-linker-flags:-Wl,--build-id`. Keep the executable: `addr2line` reads its debug information, and
  the build id says it is the one that crashed.

## Tests

`tests/crash`: a report written and read back; a real crash of a child process (the test program itself, started again) that
leaves a report with each thread's stack, the modules, the log and the settings; a killed session found at the next start; a
clean session that leaves nothing.
