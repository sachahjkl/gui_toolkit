type: Added

**`platform.clipboard_request`**: reads the clipboard's text or files without waiting for the program that owns it. The call returns an id at once; the answer comes in a later `poll_events` as a `Clipboard_Data` event (`Event.clipboard`: the text, the paths, whether they were cut). On Linux the window's loop reads another program's clipboard (a Wayland pipe it polls, X11 selection events) and gives up after 2 s of silence: a slow or hung owner no longer freezes a paste.
