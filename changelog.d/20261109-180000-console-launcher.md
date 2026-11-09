type: Added

**The console launcher** (`tools/console_launcher`, `src/console_launcher`): `<stem>.com` beside a program of the Windows subsystem, which `desktop.install` writes with the PATH entry. In cmd or PowerShell it gives a console command its output and its exit code and lets a window go. A program builds its own with its mark and its rules (`LAUNCHER_DEFAULT`, `LAUNCHER_OTHERS`: words as the first argument, flags anywhere, `(none)`) and embeds the bytes. It was Wren's (src/tools/wrencom). See docs/desktop.md.
