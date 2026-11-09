type: Added

**`platform.raise_window` (Wayland)**: asks the focus through `xdg_activation_v1`, with the seat's last input serial. It did nothing before. A program shown by a shortcut of the compositor now gets the keyboard on compositors that do not focus a new window by themselves.
