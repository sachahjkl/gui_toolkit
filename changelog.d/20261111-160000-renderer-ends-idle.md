type: Fixed

**A renderer that ends waits for the GPU**: `render.destroy` lets the GPU finish what it was given first (Direct3D 11: an event query; WebGPU: a poll that waits). An offscreen frame is only flushed, and a renderer released while WARP still drew it could end the process.
