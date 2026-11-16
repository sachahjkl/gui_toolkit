type: Added

**The first window can close while others are open.** `host.host_close` of the first window hands the renderer to another open window, which becomes `Shared.main`: a program started from the tray can close and open its windows freely (a Wayland overlay made again on another output). `render.surface_adopt` makes a second window's surface the renderer's own, for good.
