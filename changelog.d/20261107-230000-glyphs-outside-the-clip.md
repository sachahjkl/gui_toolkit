type: Fixed

**Text outside the clip makes no instance**: a glyph placed in screen pixels and wholly outside the clip rectangle is no longer drawn (nothing recorded in a picture: it is replayed elsewhere). Text drawn again in strips, as a find in page paints the letters of its matches, made every glyph of the box in every strip: a needle with thousands of matches took 72 MB of instances and 300 MB of buffers in one frame.
