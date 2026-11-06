type: Fixed

**Frame statistics on WebGPU**: `frame_end(vsync = false)` on a Fifo surface counts the vblank it waits for, a reconfigured surface starts its run over, and `vblank_grid` says unknown once the compositor stops answering (Direct3D 11 too). `gpu_ms` starts over with a new device.
