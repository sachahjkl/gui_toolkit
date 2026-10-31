type: Fixed

**Closing Chrome's DevTools could leave a window on freed memory**: the connection was freed while the DOM side still held it, so the edits could stay and the program could hang. They now go with the client, every time.
