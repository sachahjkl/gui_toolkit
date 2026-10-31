type: Fixed

**Partial redraw: a frame with a backdrop or a blend mode into the frame is drawn whole**: outside the region it would have read the last frame's finished pixels, and a kept backdrop kept them.
