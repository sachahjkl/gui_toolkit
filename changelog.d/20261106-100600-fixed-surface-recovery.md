type: Fixed

**`render.set_fixed_surface`** survives a device loss: the chain made again had the window's size, and a window larger than it was clipped. A translucent window that fell back to opaque during a recovery tries DirectComposition again at the next one.
