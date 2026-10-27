type: Added

**`render.surface_*` on WebGPU**: a second window drawn by the same renderer now works with the WebGPU backend, not only Direct3D 11. `surface_init` / `surface_use` / `surface_destroy` create a per-window WebGPU surface (with its own present and latency state, and the DirectComposition visual for a translucent window) and swap it with the renderer's window state, mirroring the Direct3D path. The device, queue and pipelines stay shared (`wgpu_surface.odin`).
