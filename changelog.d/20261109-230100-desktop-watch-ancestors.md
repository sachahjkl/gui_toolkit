type: Changed

**`desktop.watch_start`**: no timer any more. A place that does not exist (nothing installed yet, a folder or a key deleted) is followed through its nearest existing ancestor, which wakes the program only when the next folder (or key) toward the place comes; the place that comes is watched itself. On Linux the watcher also follows the install folder, the Desktop and the autostart folder, and an overflow of inotify's queue is a change.
