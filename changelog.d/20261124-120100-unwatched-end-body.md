type: Fixed

**A failure in an `unwatched.run` body ends the test at once on Windows**: a session's action that fails, or `testing.fail_now`, ends the body there, its cleanups run on its thread, and `run` returns. Before, the test blocked until its time limit and leaked the body's thread. `unwatched.end_body(t)` ends the body for other code that stops a test.
