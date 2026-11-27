type: Fixed

**No crash after a file tree or a picker goes**: the thread that follows their folders freed itself, at its end, with the allocator of the code that opened them; when that was a test's tracking allocator or another short-lived one, already gone, the program crashed (seen on Windows). The thread now takes the process's heap.
