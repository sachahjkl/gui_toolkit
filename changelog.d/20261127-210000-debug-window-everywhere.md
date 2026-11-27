type: Fixed

**The debug window opens in every program**: Ctrl+Alt+Shift+D did nothing in a program that registered no debug panel. Every window that `gt:host` opens (`host_open`, `host_adopt`, a view's own window) now has the debug window with its View tab (the wireframe, the exploded view, the frame times, the density, the zoom) in a build with the devtools; a program's panels add their tabs. A release build without `-define:TOOLKIT_DEVTOOLS=true` stays as it was.
