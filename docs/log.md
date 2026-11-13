# log: a program's log

`import tk_log "gt:log"` (the package is `tk_log`: `core:log` is `log`). Pure Odin, any target.

A program's log is a file of lines, written by a thread of its own: the thread that logs never waits on the disk. The log is a
`runtime.Logger`: the program sets it as `context.logger` once, and `core:log`'s procedures (`log.info`, `log.warnf`...) write
there.

```odin
import "core:log"
import tk_log "gt:log"

logger := tk_log.install({program = "myapp", echo = ODIN_DEBUG})
context.logger = logger
log.infof("opened %s", path)
...
tk_log.close(logger)    // at the end: writes what waits
```

## Install

`install(o: Options, allocator) -> runtime.Logger` makes the log and starts its writer.

| `Options` | |
|---|---|
| `program` | the file's name: `<program>.log` |
| `dir` | "": `default_dir(program)`, that is `platform.user_dir(.State, program)/logs` |
| `level` | the lowest level written (the zero value: `.Debug`) |
| `options` | `.Short_File_Path`, `.Long_File_Path`, `.Line`, `.Procedure`: where each line was logged, at its end |
| `max_bytes` | the file is rotated before it passes this size (0: `MAX_BYTES_DEFAULT`, 1 MiB) |
| `keep` | the older files kept (0: `KEEP_DEFAULT`, 3) |
| `echo` | each line on standard error too (by the writer) |
| `tail_lines` | the lines `tail` gives at most (0: `TAIL_LINES_DEFAULT`, 100) |

A line is `2026-11-13T17:03:00.123Z INFO  text`: the UTC time, the level (`DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`), the text.
A line end in the text starts a new line indented by four spaces: one entry stays together.

Before a line would make the file pass `max_bytes`, `<program>.log` becomes `<program>.log.1`, `.log.1` becomes `.log.2`, and so
on: `keep` older files stay. A file holds at least one line, however long. When the file cannot be opened, the lines go only
to the ring (and to standard error with `echo`).

## Writer and order

Each line is formatted on the thread that logs and put, under one lock, after the lines before it. The writer is one job of a
`tasks.Pool` of one thread ([tasks.md](tasks.md)): it takes every line that waits and appends them to the file. The file has the
lines in the order the threads logged them.

- `flush(logger)`: every line logged before the call is in the file when it returns.
- `close(logger)`: flushes, ends the writer and frees the log. Set another `context.logger` first.
- `path(logger) -> string`: the file ("": the system has no folder for it).

## The last lines

The log also keeps its last lines in a ring of `TAIL_BYTES` (32 KiB) in memory. `tail(user, buf) -> int` copies the last
`tail_lines` whole lines, oldest first, into `buf`, with `user` the logger's data (`logger.data`). It takes no lock and
allocates nothing: it is a `crash.Source_Proc` ([crash.md](crash.md)), and a crash report shows the lines the writer had not
written yet too.

```odin
crash.install({program = "myapp", version = VERSION, log_tail = {tk_log.tail, logger.data}})
```

The `crash` package does not import `log`, and `log` does not import `crash`: each works alone, and the program joins them.

## Tests

`tests/log`: rotation in a temporary folder (the sizes, the files kept, the lines in order across them); lines from eight threads
at once (each whole, each thread's in order, none lost, the tail equal to the file's end); the tail from a small buffer (whole
lines only); a level below the lowest.
