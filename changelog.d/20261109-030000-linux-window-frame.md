type: Fixed

**An integrated title bar on Linux works as a frame**: a press on the caption moves the window (Wayland `xdg_toplevel.move`, X11 `_NET_WM_MOVERESIZE`), the bands along its four sides resize it (with the resize cursor over them), a double click on the caption maximizes or restores it, and a right click there opens the compositor's window menu. Nothing of that happened: the window could not be moved. The window menu now gets the press's serial and the surface's coordinates.
