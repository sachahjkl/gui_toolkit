type: Fixed

**Closing your session no longer reads as a crash.** On Linux, a program the system ends (SIGTERM when the desktop session closes, SIGHUP, Ctrl+C) ends its crash session cleanly: the next start no longer shows an "unclean" report after each logout. A program that handles these signals itself keeps its own handler.
