type: Fixed

**`font`**: a hostile COLR font can no longer exhaust memory or hang through color lines: the stops of a gradient count against the work allowance of a glyph (a graph that reads too many is refused and shows its outline), and finding a stop no longer walks along them.
