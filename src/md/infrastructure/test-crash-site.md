# Where a test crashed, on Linux

Two CI runs stopped on an illegal instruction with nothing in the log but the test runner's own line: no address, no
module, no thread. On Windows `gt:testkit/unwatched` catches the exception and names its module and offset. Linux
had nothing. `gt:testkit/crashsite` gives the same fact there.

## What Odin's runner does

`core:testing` installs one handler for `SIGILL`, `SIGFPE` and `SIGSEGV` (`libc.signal`), in `main`, before the
first test. On a test's own thread it stops the test and logs the signal. On any other thread (a worker, a chore,
a reader of a child's pipe) it returns: the instruction runs again, faults again, and the process spins until the
CI's time limit. Neither case says where.

## The design

- `crashsite.arm()` installs a handler (`SA_SIGINFO`, on the alternate stack when one exists) for `SIGILL`,
  `SIGFPE`, `SIGSEGV` and `SIGBUS`, and keeps the handler it replaces. It is called by what every test already
  calls: `session.start`, `unwatched.run` and `testkit.temp_folder`. Those run after the runner's `main` installed
  its handler, so ours comes second and chains to it. An `@(init)` was refused: it runs before `main`, and the runner
  replaces it.
- The handler writes one line to stderr with `write(2)`: the signal, the faulting address (for a memory fault), the
  instruction's module and offset, and its nearest symbol (`dladdr`). A `ud2` under `SIGILL` is named a trap: an
  assertion, a bounds check or `fail_now`, whose message is above it. Then it calls the handler it replaced.
- A thread that faults again at the same instruction means the replaced handler returned without ending it (the runner
  on a thread it does not know). The second time, the handler restores the default action and returns: the process ends
  by the signal, with the report written once, instead of spinning.
- The handler allocates nothing and takes no lock. `dladdr` is not async-signal-safe by the standard; a process that
  is ending anyway takes that risk, as the Windows handler reads module names.

## Refused

- A backtrace (`backtrace(3)`): it allocates on its first call, and one frame with its module and offset is what the
  symbolizer (`toolbox.crash_symbolize`) needs.
- Replacing the runner's handler: it decides whether a test expected the signal. Ours only adds the place.
