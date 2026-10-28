type: Added

**`platform.monitor_size(window)`**: the pixel size of the monitor a window is on, neutral across systems (Win32 `MonitorFromWindow` + `GetMonitorInfoW`, the Wayland `wl_output` mode, or the X11 root screen). An application that wants a fixed surface the size of the screen (`render.set_fixed_surface`) no longer needs its own Win32 call.
