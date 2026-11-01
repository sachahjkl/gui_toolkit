type: Fixed

**The plain text clipboard of an offscreen window on Linux**: `get_clipboard` gave nothing and `set_clipboard` did nothing, while `clipboard_set` kept to the process's store: a headless program could not copy and paste its own text.
