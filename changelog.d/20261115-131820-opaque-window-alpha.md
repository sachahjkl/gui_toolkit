type: Fixed

**An opaque theme can no longer show the desktop through a window (Windows)**: a window whose theme is opaque is now shown with its transparency ignored, so no part of it (a panel, a dialog, a list's rows) can show the desktop or the window behind it. A translucent theme still shows the desktop's backdrop, and a switch between the two changes the window at once. On Linux, a see-through window (an overlay) with an opaque frame is shown opaque the same way.
