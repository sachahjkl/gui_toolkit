type: Added

**`host.restart_after_exit(&p, args)`**: "Restart now" after an update. `program_end` ends the session, then starts the executable `program_start` read (`Program_Start.executable`: the new copy, not `<exe>.old`), then closes the log. `Program_Start_Options.launch` replaces the start in a test.
