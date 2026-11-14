type: Fixed

**A test session's failed action says why at once**: on Linux and macOS, an action of `testkit/session` that fails (a box not found, a wait past its bound) now fails the test with its message and goes on with the next test, instead of a "Test timed out" with no message. Windows keeps the time limit of 0, after the message, because of how its test runner handles signals.
