type: Fixed

**Windows: a program started again comes back in front with the keyboard**: after an update or Restart, `setup.launch` allows the new process the foreground (`AllowSetForegroundWindow`), where it opened behind the other windows; a program that started its new copy with `os.process_start` calls `setup.launch`. A second start of the program brings the first one's window back on screen and in front, even minimized (`platform.raise_window`), where it only flashed in the taskbar.
