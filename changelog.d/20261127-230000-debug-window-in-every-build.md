type: Changed

**The debug window is in every build, a release too.** Ctrl+Alt+Shift+D opens it in every program, with its View tab (the wireframe, the exploded view, the frame times) and the program's panels; the key or Escape closes it. The define `TOOLKIT_DEBUG_WINDOW` (true by default) holds it: build with `-define:TOOLKIT_DEBUG_WINDOW=false` to leave it out (about 1.6 MB). `TOOLKIT_DEVTOOLS` now holds only the CDP endpoint, as before off in a release. The key is read after the program's own keys: a program whose shortcut is Ctrl+Alt+Shift+D keeps it.
