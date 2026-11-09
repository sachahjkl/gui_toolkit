type: Fixed

**Wayland**: `platform.minimize` before the first `show_window` (or while hidden) is asked at the show, once the toplevel's first configure came, as `set_maximized` and `set_fullscreen` are. A window with no fractional scale from the compositor yet follows the output's integer scale, and a hidden window no longer sets a buffer scale on its destroyed surface.
