type: Fixed

**Closing your session no longer reads as a crash.** A program the system ends ends its crash session cleanly, so the next start no longer shows an "unclean" report after each logout. On Linux this covers SIGTERM when the desktop session closes, SIGHUP and Ctrl+C; a program that handles these signals itself keeps its own handler. On Windows it covers a sign-out or a shutdown.
