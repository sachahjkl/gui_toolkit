Type: Changed

**The interface state a build works on is the thread's**: `ui`'s current state (what `begin_build` selects and the public procs use) is thread-local, so several apps of one process build and draw their interfaces at once, each on a thread of its own; before, two threads building at once broke each other's parent stack.
