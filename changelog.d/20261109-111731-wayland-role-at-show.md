type: Fixed

**A window never shown is in no task bar (Wayland)**: `open_window` makes a surface with no role, and the toplevel is made at the first `show_window`. A program that starts hidden in the notification area was listed in the task bars that show every toplevel (ShojiWM). `set_maximized` and `set_fullscreen` asked before the first show are asked by the new toplevel.
