# Work off the interface's thread

The interface's thread makes no system call: no file read or written, no process started, no D-Bus call that waits,
not even a `stat`. Each of them can take a second (a disk asleep, a network share, polkit), and the window freezes for
it. Such work runs on another thread, and its result comes back to the interface's thread to be shown.

## ui.task: the work there, the result here

```odin
Save :: struct { path: string, text: string, ok: bool }

save_work :: proc(d: rawptr) {                         // on a thread of the chores
	s := (^Save)(d)
	s.ok = os.write_entire_file(s.path, s.text) == nil
}
save_done :: proc(d: rawptr, word: u64) {              // on the interface's thread, at the start of a build
	s := (^Save)(d)
	if !s.ok { ui.announce(&app.announcer, .Bad, "Not saved") }
	free(s)
}
save_lost :: proc(d: rawptr) { free((^Save)(d)) }     // the State was destroyed meanwhile: done does not run

ui.task(&app.ui, save_work, save_done, new_clone(Save{path = path, text = text}), save_lost)
```

| Procedure | |
|---|---|
| `task(s, work, done, data, lost = nil)` | `work(data)` on the chores, then `done(data, 0)` on `s`'s thread at its next build (ui.post; the window wakes). Called on the interface's thread. When `s` is destroyed by then, `done` never runs and `lost(data)` does, on the thread that found it out. `done` nil: nothing comes back |
| `chores()` | the program's pool for that: `CHORES_THREADS` threads, up to `CHORES_GROW` more while some hang; started at its first use |
| `chores_stop(bound = CHORES_STOP_BOUND)` | at the program's end, before `ui.destroy`: the work waiting runs (its results are posted), then the threads are joined, within `bound` (2 s; 0: no bound). False: a chore that hangs was left to the process's end |

The data of a task is the caller's until `done` or `lost` runs: allocate it with an allocator other threads may use
(the heap), not the frame's temporary memory.

## The system's programs and dialogs

| Procedure | |
|---|---|
| `open(target, kind = .Path)` | opens a file or folder (`.Path`), a web address (`.Url`) or shows a file in its folder (`.Reveal`) with the system's program, on the chores: a launch can wait on the disk, the shell or D-Bus. `target` is copied |
| `file_dialog(s, kind, d, done, user)` | the system's file dialog (`.Open`, `.Save`, `.Folder`; `d` a `platform.File_Dialog`, copied) on the chores: a modal loop (Windows) or another process (zenity, kdialog, the portal) that the interface's thread would wait for. `done(result, user)` comes at a next build of `s`; the result's paths are freed after it |

`platform.open_url`, `open_path`, `reveal_in_folder` and the `platform.*_dialog` procedures wait: they are for a
thread that may wait (a task's work).

## Finding what blocks

In a debug build (`TOOLKIT_BLOCKING_CHECK`, on with `-debug`), every procedure of the toolkit that waits on the system
(`platform` dialogs, opening, notifications, the clipboard read at once; `fsx` reads and writes; `config` files;
`desktop.theme_icon`, `desktop.open_with`; `setup.facts`) called on a thread that builds an interface says so on the
standard error, once per call site of the program:

```
toolkit: fsx.write_atomic on the interface's thread (<program>/prefs.odin:88): it can freeze the window; make it a task (ui.task)
```

`base.blocking_count()` counts them (a test of a program can expect 0 after a scenario). `ui.begin_build` marks its
thread; a call before the first build (the start-up's reads) is not said.

## gt:tasks: pools and jobs

`import tasks "gt:tasks"`. A `tasks.Pool` is a few threads; `ui.chores()` is one. A program makes its own for work of its
own order (a pool per connection; the pictures last asked for first).

| Procedure | |
|---|---|
| `start(p, Options)` | `threads` started now (0: none, see below), `grow` more while all are held for `stuck` (1 s), an added one ending after `extra_idle` (5 s) with nothing to do; `newest_first`; `clock` a test's clock |
| `add(p, work, data, Add{after_ms, urgent})` | work for a thread: in the order it came (or the newest first), `urgent` before all that waits, `after_ms` from now with no thread asleep for it. False once `stop` began |
| `stop(p, drop = nil, bound = 0)` | without `drop`, what waits runs first (timed work too); with it, what waits does not run and `drop` gets its data. The threads are joined: work that hangs holds the stop, unless `bound` > 0: then it returns false after that long and leaves the pool to the process's end (a later `stop` joins it) |
| `ask(p, &job)` | a run of a `Job{work, data}`: asked while one waits, nothing more; asked while it runs, one more run after it |
| `busy(p, &job)` | a run waits or goes on |
| `state(p)`, `wait_rest(p, bound)` | for tests: what waits and runs; until it rests |

A reader asked again and again (a folder read again each time it changes, a scan of every process) is a `Job`: its work
reads into a result of its own, then posts it (`ui.post`) or swaps it in under a lock of its own.

**A pool of no thread** (`threads = 0`) runs work at once on the thread that adds it, and timed work when `pump(p)` says,
by `Options.clock` (`poke(p)` after the test moves it): a test drives it in its own order and by its own clock.

Tests: `src/tasks/tasks_test.odin` (order, urgent and newest first, the test's clock, a job's merged asks, a held pool
that grows then shrinks, a stop that hands back what waits), `tests/post/task_test.odin` (a task's result on the
interface's thread; a task that ends after its State is destroyed).
