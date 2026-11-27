type: Changed

**The node graph's minimap has a corner and a size**: `Graph_Options.minimap` is a `Graph_Minimap` (`show`, `corner`,
`size`). By default it is a quarter of the area's width, from 100 to 200 pixels, so it no longer covers a narrow
panel. `graph_fit` (and F, and "Back to content") places the nodes beside or above it, never under it.
