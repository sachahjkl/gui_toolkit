# A body the runner does not watch, and how it ends

`gt:testkit/unwatched` runs a test's body on a thread of its own on Windows (the package comment says why). This file
records how that body ends when the test fails in it.

## The fault

A session's action that failed in a body on Windows did not end the test. `session.stop_test` logged the message, set
the test's time limit to 0 and slept for ever. The runner then ended the test's own thread, which waited in
`thread.join`. The body's thread slept on. Its `Thread` (296 bytes, made by `thread.create` with the test's
allocator) was never freed, and the runner reported it as a leak. A program saw the test block, then the leak.

The time limit of 0 stays the way to end a test's own thread: `testing.fail_now` there raises a signal, and the
runner's handling of a second signal waits for ever (`session/stop_windows.odin`).

## The design

- `unwatched.end_body(t)` ends the body where it is called, when this is the body's thread. The body's cleanups run
  on its thread, last first, as when it returns. The thread-local cleaners run. Then `ExitThread` ends the thread.
  Anywhere else it does nothing.
- `run` always joins and frees the thread: the thread ends in every case (a return, `end_body`, `fail_now`, an
  exception). `run` then returns on the test's thread, and the test ends failed by the message logged.
- `session.stop_test` on Windows logs its message, then calls `end_body`. Outside a body, it goes on to the time
  limit of 0.
- `testing.fail_now` in a body ends by a trap. The package's exception handler sees `_fail_now_called` and ends the
  body as `end_body` does. The message was logged by `fail_now`.
- Any other exception keeps its path: the handler records its code, module and offset, and ends the thread at once.
  The cleanups stay for the runner: the body's state is not whole.

The body's deferred statements do not run when it ends early, as with `fail_now` on the test's own thread.

## Refused

- **Terminating the body's thread from the test's thread.** `TerminateThread` stops a thread inside any lock it holds
  (the heap's, DirectWrite's). The test's next allocation could then wait for ever.
- **Cleanups left to the runner after a stop.** The runner runs them on another thread, and a window answers only on
  its own. A stop comes from the session's own code, so the state is whole and the body's thread can run them.
- **A `stop` in `unwatched` that replaces `session.stop_test`.** How a test ends is the session's matter; which thread
  ends, and how, is this package's.

## Tested

`tests/testkit/unwatched_windows_test.odin` runs on Windows only. A body calls `end_body` after it registers a
cleanup that frees memory. The test checks that the body stops there, and that the cleanup runs on the body's thread.
The runner's leak check covers the `Thread` and the memory. The exception path and `fail_now` path end the test failed,
so no passing test covers them.
