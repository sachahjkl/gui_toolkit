type: Added

**The first frame on the CPU for a program with its own loop**: `render.cpu_stage_next` says, after each frame, whether the next one is owed at once (it ends the CPU stage, on the GPU) or the device did not come; fidget asks for its device at its start, for `cpu_first`, and shows its first screen at a median of 106 ms from its start instead of 285 (lavapipe, Xvfb). The CPU's frames are drawn in bands on up to eight threads, and the pixels well inside a plain shape skip its distance: fidget's first screen is rasterised in 9 to 17 ms instead of 346.
