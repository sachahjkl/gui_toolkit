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
| `render/rect.wgsl`, `filter.wgsl`, `slug.wgsl`, `mip.wgsl` | the shaders, written once (see "One source for the shaders"); `mip.wgsl` is mip chain generation, which WebGPU lacks (Direct3D 11 has `GenerateMips`) |

The pixel tests run on both backends with the same expectations: `tools\test_backends.ps1 -Backend d3d11|wgpu` (the wgpu ones one
test at a time: WARP's D3D12 crashes now and then when several devices work at once). Run `tools\fetch_wgpu.ps1` first: with DXC
next to the test programs a package takes a third of the time it takes with FXC. The CI splits the packages in four groups, one per
job (`-Group ci1` .. `ci4`, defined in the script, which checks that together they hold every package once); a pull request runs
`-Group sample`; `-Define TOOLKIT_WGPU_DX12_COMPILER=fxc` runs a package with FXC.
`tools\render_probe` draws a few primitives on the offscreen renderer and writes a PPM; `tools\ppm_diff.ps1` compares two.

## One source for the shaders

Every shader is written once, in WGSL (`render/*.wgsl`). WebGPU compiles it as it is. Direct3D 11 embeds the HLSL that **naga** (the translator wgpu uses) writes from it, compiled ahead of time to DXBC as before (no shader compiles at start-up under D3D11):

```
render/*.wgsl --tools/wgsl2hlsl (naga 29.0.4)--> render/shaders/*.hlsl --D3DCompile--> render/shaders/*.dxbc (embedded)
```

* `odin run tools/shaders` does both steps (`-- -check` only compares). It builds the translator first (`tools\build_naga.ps1`: a small Rust program, `tools\wgsl2hlsl`; naga is pinned exactly in `Cargo.toml`, `Cargo.lock` carries the SHA-256 of every crate and the script pins `Cargo.lock` itself, builds with `--locked`; needs `cargo`).
* The first line of each generated HLSL names the SHA-256 of the WGSL it came from: `tests/shaders` fails when a `.wgsl` file was edited and `tools/shaders` was not run, and when a blob is not what the embedded HLSL compiles to. CI also runs `tools/shaders -- -check` (naga writes the HLSL again and it must be identical).
* A module is the WGSL files concatenated: `rect`, `filter`, and `slug` (= `rect.wgsl` + `slug.wgsl`, the text shaders reuse rect's transforms, clips and text correction). `render/shaders.odin` lists the modules and the Direct3D 11 slot of every resource (`RECT_BINDINGS`...: group.binding = register), which is what naga is told and what the backend binds.
* What the translation needed on the D3D11 side: the instance layout uses naga's `LOC0..LOC8` semantics, the tables (transforms, clips, points, gradients, retained heaps) are raw buffers read as `ByteAddressBuffer`, filter passes use a plain clamp sampler (the shader adds the transparent border), and naga's sampler heaps (Direct3D 12) become plain `SamplerState`s (a few lines of text processing in the translator).
* Cost: none at run time (same DXBC pipeline); the naga HLSL is a little bigger (pixel shader 110 KB, was 100 KB) and measures the same on the GPU (see the CHANGELOG).

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
* `video_convert` takes pictures in memory only (I420, NV12; P010 and 10-bit I420 when the adapter has `TextureFormat16bitNorm`): a
  decoder's Direct3D 11 texture (`Video_Picture.gpu_texture`) is refused, wgpu-native cannot import it.
* Not implemented, and they say so (`false`, 0 or an empty result): `capture_request` (`capture_poll` has nothing; offscreen
  readbacks, `draw.offscreen_end` + `readback_poll`, work), the GPU canvas engine (`canvas_*`, docs/canvas.md),
  `surface_create` (second windows), `set_fixed_surface` and `set_max_frame_latency`. Use the Direct3D 11 backend for those.

Measurements and the recommendation: see the notes of the WebGPU prototype (Wren repository, `docs`), and `CHANGELOG.md`.
