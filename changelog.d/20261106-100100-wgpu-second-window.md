type: Fixed

**Second windows on WebGPU**: a window set aside is made again after a recovery and follows `set_blend_space`, as on Direct3D 11. Its capture, its clear and its first frame are its own, and `surface_destroy` frees its frame statistics.
