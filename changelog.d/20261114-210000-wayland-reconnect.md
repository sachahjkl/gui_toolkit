type: Fixed

**Windows open again after the Wayland compositor ended the connection**: once the compositor ended a program's connection (a protocol error, the compositor restarted) and no window of it was left, every new window was refused ("no window: libwayland-client"). The next window now starts a new connection. While a window of the old connection lives, nothing of it is taken down.
