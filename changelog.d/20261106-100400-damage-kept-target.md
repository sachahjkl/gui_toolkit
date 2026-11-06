type: Fixed

**Partial redraw**: a frame that stopped halfway (Direct3D 11), that had no surface texture (WebGPU) or whose region could not be cleared leaves nothing the next region starts from: the next frame is whole. Their rectangles were lost, or composed onto a blank target.
