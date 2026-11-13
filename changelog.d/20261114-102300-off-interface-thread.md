type: Fixed

**No system read or file write on the interface thread for animations, crashes and updates**: the system's animations choice is read once and kept, then set again when the system changes it (`WM_SETTINGCHANGE` on Windows, GNOME's `enable-animations` on Linux, its first read on a thread); it was asked at every build, a file read per frame on Linux. `crash.end_session` writes its files on a thread of its own, and the leftovers of an update are removed off the interface thread.
