type: Fixed

**A capture started from a menu no longer shows the menu**: on Windows, `capture.output` and `capture.desktop` wait at
most 400 ms for a popup menu (a tray icon's, a context menu) to finish its fade-out and leave the screen, then take the
picture. A menu that stays longer is captured with it, and the capture does not fail.
