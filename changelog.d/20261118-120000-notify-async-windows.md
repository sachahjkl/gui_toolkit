type: Fixed

**Notifications no longer pause the window on Windows**: `platform.notify_async` (and so `ui.announce`) returns at once. A notification thread of the toolkit shows the toast, and `done` runs from the window loop when it answers, as on Linux. A replace, `notify_close` and the click and button events work as before. On an offscreen window `notify_async` now returns false, and `done` does not run.
