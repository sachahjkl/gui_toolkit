type: Fixed

**A program no longer hangs or crashes when a background task answers at once.** Since 0.311.0, a task's answer could
run on the interface's thread while the worker that posted it was still unlocking: it unlocked freed memory, and closing
the window then waited for ever, or the program crashed. Rare, and possible in every program on 0.311.0.
