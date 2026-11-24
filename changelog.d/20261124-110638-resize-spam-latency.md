type: Fixed

**A resize spam no longer leaves the window behind** (Direct3D 11): after many quick resizes from a corner, every later resize showed the content about half a second behind the window, until the window closed. Each frame shown at once during a resize left one frame more in the queue of the swap chain; the renderer now counts those frames and takes them back, and the window stays as responsive as before the spam.
