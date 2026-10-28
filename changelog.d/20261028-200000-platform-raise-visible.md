type: Added

**`platform.raise_window(window)` and `platform.is_window_visible(window)`**: bring an already-shown window to the front (Win32 `SetForegroundWindow`; X11 `_NET_ACTIVE_WINDOW`; a no-op on Wayland, where the compositor owns focus), and whether a window is on screen (mapped and not minimized). An application no longer calls Win32 for the "switch to this window" and "is this window visible" it needs around multi-window and capture flows.
