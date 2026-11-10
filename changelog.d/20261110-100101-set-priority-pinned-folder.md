type: Fixed

**`process.set_priority`** lists the threads through a descriptor of the process's own `/proc/<pid>` folder, whose start time it checks, and its pidfd says afterwards whether the process still ran: a pid given to another process in between is no longer read or changed.
