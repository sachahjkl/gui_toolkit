type: Fixed

**A bar no longer gets a frame from the finish**: in the machined, edged, gradient and glass finishes, a box that declares its sides (a sidebar with its right line, a top bar with its bottom line) shows those lines alone, and a bar against the window's edge shows no frame. Before, the finish drew a lit line one pixel inside its top, left and right, so a sidebar under a top bar showed a double line. New `ui.box_rimmed` says whether a box gets that line; `ui.paint_rect_corners` takes `rim = false` to paint a face without it.
