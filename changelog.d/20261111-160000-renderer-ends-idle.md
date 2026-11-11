type: Fixed

**A renderer that ends waits for the GPU**: `render.destroy` lets the GPU finish what it was given first (Direct3D 11: an event query; WebGPU: a poll that waits). An offscreen frame is only flushed, and a renderer that ended while WARP still drew it kept about two megabytes, or ended the process: a test package of a hundred and more sessions fell at about the hundred and twentieth, whichever test that was. `tests/lifecycle` makes and ends a session's pieces thirty times: its private memory and its handles stay where they were.
