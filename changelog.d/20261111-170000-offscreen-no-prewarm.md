type: Changed

**An offscreen renderer does not pre-warm** (WebGPU): it makes a pipeline when it first draws with it. Pre-warmed, each one compiled all eight pipelines on a thread and `destroy` waited for them, used or not: every test session paid them, and on WARP the slowest CI packages spent most of their time there (`subpixel_slug` and `scenarios`: 48 s to 30 s on a GPU). A window's renderer still pre-warms: its start hides the compiles. `TOOLKIT_WGPU_PREWARM` is gone.
