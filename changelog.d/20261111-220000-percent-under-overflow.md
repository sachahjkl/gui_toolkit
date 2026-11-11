type: Fixed

**A box that fills its parent fills it under a box that scrolls sideways too**: under a box with `Allow_Overflow_X` (a table's titles, its rows), a `fill()` kept the size its parent had before an ancestor shrank, the window's width: a table beside a sidebar was as wide as the window and scrolled for nothing.
