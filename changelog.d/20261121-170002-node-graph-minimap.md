type: Fixed

**Node graph minimap freeze and Back to content**: dragging near or past the edge of a node graph's minimap no longer
accelerates the view exponentially into a float32 grid-loop freeze (the minimap transform freezes during the drag and the
grid loop is bounded in `f64`), and panning all nodes off-screen now shows a "Back to content" button above the minimap
to fit the graph back into view.
