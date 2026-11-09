type: Fixed

**`platform.wait_event` (Wayland)**: less than a millisecond left is a millisecond of sleep. It returned at once, and a loop that waits until a deadline spun through its last millisecond (about 150 wakes).
