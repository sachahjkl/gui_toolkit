type: Fixed

**The clipboard with no window on Windows**: `get_clipboard` and `set_clipboard` given no window read nothing and write nothing, as on Linux; they crashed.
