type: Fixed

**Two instances of a program no longer hide each other's crashes**: every instance keeps its own session file (`crash.session_file`, `session-<pid>.txt`). One shared file was overwritten by a second instance, so a crash or a kill of the first went unreported, and the clean end of either removed the other's trace. A start reports every session whose process is gone, and leaves the ones that still run. A clean end now marks as seen what was there when its session began: a crash of another instance while it ran is still shown at the next start.
