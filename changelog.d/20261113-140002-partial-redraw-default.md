type: Changed

**`rendering.partial_redraw` is on by default**: each frame redraws only what changed; a frame that cannot (a backdrop, a plane) is drawn whole as before. A program that set it on through `Standard_Defaults.values` drops that line.
