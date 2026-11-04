type: Changed

**`font.color_prepare`, textures zeroed on the GPU**: `font.color_prepare` makes what color glyphs are drawn with (Direct2D on a WARP device, about 20 ms) for an application to call on a thread of its own while it starts; the first color glyph a frame looked up made it on the drawing thread. Textures are made render targets too and zeroed by a clear on the GPU (`ClearRenderTargetView`) where they were zeroed by uploads of zeros: a 2048 x 2048 glyph atlas page 6 ms (R8) and 3.5 ms (RGBA) of the CPU before, its first frame's.
