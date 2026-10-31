type: Fixed

**`ui.destroy` after `platform.destroy_window`** no longer writes to the freed window, and a post no longer wakes it: the State forgets a window when it is destroyed.
