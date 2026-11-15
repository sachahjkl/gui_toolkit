type: Fixed

**Linux: the session bus kept in memory it did not own**: a thread's session-bus connection (the tray, notifications, the portals, the screen saver's inhibitions, the accessibility bridge) took its memory from the first caller's allocator, and kept writing in it after that allocator freed it. It lives in the heap now, as long as its thread, with the accessibility bus's address and the list of inhibitions. The `host` tests run on Linux too (they crashed there after a few tests).
