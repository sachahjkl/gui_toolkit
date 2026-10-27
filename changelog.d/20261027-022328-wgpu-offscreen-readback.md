type: Added

**Offscreen readback on the WebGPU backend**: `draw.offscreen_end` gives a `render.Readback_Id` and `render.readback_poll` the picture (straight RGBA8, sRGB values, alpha kept) as under Direct3D 11: the frame copies the target into a buffer, the poll maps it without waiting (`Pending` until the GPU is done). `tests/layers` checks the pixels on both backends.
