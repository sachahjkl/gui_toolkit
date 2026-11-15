type: Fixed

**A machine with no graphics driver**: a program on a machine with no usable graphics driver says so and ends, instead of crashing. `host.host_open` returns false and says why in the log, on standard error and, for a Windows program without a console, in a message box (`host.open_error`, `render.init_failure_text`); a Direct3D 11 window falls back to WARP when no hardware device can be made.
