type: Added

**A lazy list's active row and `onActivate` (plugin API level 8)**: a plugin's `list` shows its active row as the
toolkit's lists do; a press on a row sets it, and Up, Down, Page Up, Page Down, Home and End move it while the list has
the keyboard. Enter on the active row, or a double click on a row, calls the list's new `onActivate(index)`. A move of
the active row is not sent to the plugin. `plugins.List_Info` gives the active row and whether the list has the
keyboard. Plugins of levels 1 to 7 keep working.
