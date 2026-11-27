# The chores: one pool per process, restartable

`ui.chores()` is the process's pool for work the interface must not wait for (`ui.task`, `ui.open`, the system's file
dialogs, the picker's reads). `ui.chores_stop` ends it at a program's end.

## Decisions

- **A stop retires the running pool; the next use starts another.** The first version started the pool once
  (`sync.Once`) and kept a `stopped` flag for good. A process that ran a second app after the first ended (a program's
  tests: galerie, feuille, papier; a window opened after the last closed) then lost every task: `ui.task` called
  `lost` at once, `ui.open` did nothing, a file dialog never answered. Nothing in an app's end may change what a later
  app of the process gets.
- **A stop refuses until it ends; only then is the pool retired.** The stop drains the pool: the chores still running
  end, those waiting run. A chore that asks for another meanwhile (a plugin's channel, a chain of reads) gets the
  stopping pool and a refusal, as before the restart existed. Retired at the start of the stop, the ask started a new
  pool whose work ran after the program had ended. A second stop during the first returns at once.
- **A retired pool's struct is never freed.** A thread may have taken the pointer from `chores()` just before the
  stop; its `tasks.add` then reads a pool that is stopping and answers false (the task's `lost` runs). A bounded stop
  that ran out of time leaves its threads running on that struct. One small struct per stop, at most one stop per
  app, is the price.
- **Refused: a pool per State.** A program with many States (windows, views) would hold threads per window, and a
  task's work does not belong to a window. Refused: a count of owners that stops the pool at zero: a program that
  calls `chores_stop` means its end, and a later app is a new start.

## The test that breaks it

`tests/post/task_test.odin`, `a_task_after_an_app_that_stopped_the_chores_answers`: two apps in turn in one process,
each stops the chores as a program ends; the second's task must answer.
`a_chore_that_asks_for_more_while_the_chores_stop_is_refused`: a chore running at the stop asks for one more; it must be
refused and never run.
