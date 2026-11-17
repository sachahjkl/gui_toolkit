type: Added

**`instance.running` and `instance.quit`, and a default wait.** A program asks whether its copy runs, or asks it to quit, with one call each, in place of a `send` of `MESSAGE_PING` or `MESSAGE_QUIT` it wrote itself. `Instance_Options.wait_ms` 0 now waits `instance.WAIT_MS_DEFAULT` (2 s), so a program gives no number of its own; a single try, which 0 meant before, is now a value below 0.
