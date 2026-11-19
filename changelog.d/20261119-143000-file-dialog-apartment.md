type: Fixed

**The system's file dialog no longer crashes on Windows.** It runs on a thread of its own, in a single-threaded apartment it opens and closes. Before, it closed its apartment at once (a `defer` in a block) and ran in the caller's thread, which was in the multithreaded apartment as soon as another thread of the process made one (UI Automation, a decoder): the dialog's Explorer view then corrupted the heap while it listed the files.
