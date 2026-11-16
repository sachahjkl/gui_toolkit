type: Added

**Views' windows in a program's own tests**: `host.view_windows` opens offscreen windows when the owner window is offscreen (they build and draw no picture: `Host.no_picture`), and `session.view_window` gives each window of an attached application as a session. A program's test of a view in its own window needs no backend of its own.
