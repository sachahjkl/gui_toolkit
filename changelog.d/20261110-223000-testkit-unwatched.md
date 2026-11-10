type: Added

**`testkit/unwatched`** (was `tests/unwatched`, the toolkit's own): a test's body on a thread the runner of `core:testing` does not watch, for a program's tests on Windows. There the runner fails a test on any exception of its thread, even one DirectWrite, Direct3D or DXGI raises and catches itself ("Signal caught: Unknown", now and then). `unwatched.run` now also does the body's `testing.cleanup`s on its thread when it returns: a window or a testkit session made in the body ends on the thread that made it. docs/testkit.md.
