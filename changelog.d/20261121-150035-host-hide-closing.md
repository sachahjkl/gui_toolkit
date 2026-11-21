type: Fixed

**`host.host_hide`**: takes off the screen a window whose close was asked; it did nothing then on Linux, and a program that quits on the close could not hide its window before its last work (its workers stopped, its files written, the renderer let go).
