type: Fixed

**A window that closed after a right click on a file no longer hangs**: `ui.shell_menu_destroy` stops the system menu's worker before it lets its answer's gate go; the answer of a query still on its way read freed memory, and the close waited for ever.
