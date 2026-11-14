type: Fixed

**A view's window hides with its main window**: a program that hides its main window (`host.host_hide`) left the windows of its views on the screen, frozen. They now hide with it and come back with it (`host.host_show`), where they were; a window that was about to show waits for the main one. `ui.views_windows_follow(state, shown)` does it for a backend of the program's own; `session.hide` and `session.show` in tests.
