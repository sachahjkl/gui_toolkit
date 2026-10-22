# The WebGPU render backend (experimental)

`render` has two backends behind one interface, chosen when the program is compiled:

```
odin build examples/fidget -define:TOOLKIT_RENDER=d3d11   # Direct3D 11, the default
odin build examples/fidget -define:TOOLKIT_RENDER=wgpu    # WebGPU (wgpu-native) over Direct3D 12
```

The procedures of the interface (`render.init`, `frame_begin`, `frame_submit`, `frame_end`, textures, targets, retained heaps,
`read_pixels`, ...) are the same; `render/api.odin` lists the ones whose work depends on the backend and calls its `d3d_*` or `wgpu_*`
implementation (`when`, resolved at compile time: only the chosen backend is in the program). `render.backend_name()` tells which.

## What it is

| file | |
|---|---|
| `render/wgpu_core.odin` | device (on a thread of its own), surface, pipelines (made on a pre-warming thread), textures, targets, retained heaps, device loss |
| `render/wgpu_frame.odin` | `frame_submit`: one render pass per run of draw calls into a target, copies for snapshots, filter passes, readback |
| `render/wgpu_present.odin` | present modes, the frame latency object and the frame statistics (rebuilt from the compositor's timing) |
| `render/wgpu_profile.odin` | `gpu_ms` and `gpu_profile`, from timestamp queries between passes |
| `render/wgpu_dcomp.odin` | translucent windows: a DirectComposition visual fed through `SurfaceSourceSwapChainPanel` |
| `render/rect.wgsl`, `filter.wgsl`, `mip.wgsl` | WGSL ports of `rect.hlsl` and `filter.hlsl`, and mip chain generation (WebGPU has no `GenerateMips`) |

The pixel tests run on both backends with the same expectations: `tools\test_backends.ps1 -Backend d3d11|wgpu` (the wgpu ones one
test at a time: WARP's D3D12 crashes now and then when several devices work at once).
`tools\render_probe` draws a few primitives on the offscreen renderer and writes a PPM; `tools\ppm_diff.ps1` compares two.

## Dependencies

`tools\fetch_wgpu.ps1` checks (or downloads) the pinned wgpu-native 29.0.1.1 that `vendor:wgpu` links (SHA-256) and puts
`wgpu_native.dll` and DXC 1.9.2609 (`dxcompiler.dll`, `dxil.dll`, SHA-256) in a directory. By default `vendor:wgpu` links the static
library; a program that already links another Rust static library must use `-define:WGPU_SHARED=true` (and ship `wgpu_native.dll`).

DXC next to the program (found by itself) is what makes Direct3D 12 start in a reasonable time: FXC, the fallback, needs 2.8 s
to compile the main shader, DXC 0.3 s. `-define:TOOLKIT_WGPU_DX12_COMPILER=fxc|dxc|auto`. Vulkan: `-define:TOOLKIT_WGPU_BACKEND=vulkan`.

## Environment

`TOOLKIT_RENDER_TRACE=1`: the time of the first present, the surface calls, the CPU time per phase of a frame (once per second).
`TOOLKIT_WGPU_PREWARM=0`: no pre-warming of the pipelines.

## Differences to know about

* No `SetSourceSize` in wgpu: a resize configures the surface again (2 to 3 ms), the resize slack is not used.
* Frame statistics (`take_displayed`, `vblank_grid`) are estimated from `DwmGetCompositionTimingInfo`: a frame is "shown" at the first
  vblank after its present; a frame the GPU finished late is not seen. The frame latency object (`frame_waitable`) is a waitable
  timer armed on that vblank.
* No border address mode: the transparent border of reduced filter results is applied in the shader.
* The detailed GPU profile (every draw call) is not available; the per-step one is.
* Sync intervals above 1 (`set_sync_interval`) are not available (Fifo presents every refresh).

Measurements and the recommendation: see the notes of the WebGPU prototype (Wren repository, `docs`), and `CHANGELOG.md`.
