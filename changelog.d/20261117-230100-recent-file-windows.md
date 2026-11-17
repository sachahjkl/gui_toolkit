type: Added

**`platform.add_recent_file` on Windows**: a file opened goes to the user's Recent folder and to the program's jump list (`SHAddToRecentDocs`), as it goes to `recently-used.xbel` on Linux; the call exists on every system (a no-op where there is no list). It is a blocking call: a debug build says so when the interface's thread makes it.
