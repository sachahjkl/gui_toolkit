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
* Frame capture (`capture_request` / `capture_poll`) works on both backends: the frame target (surface or offscreen) is
  copied into a mappable buffer before the present, mapped without waiting, and read back as straight RGBA8 with sRGB values
  and alpha forced to 255 (a window is opaque), the same picture the Direct3D 11 path gives. It costs nothing until a capture
  is asked for. Offscreen readbacks (`draw.offscreen_end` + `readback_poll`) also work on both.
* Not implemented, and they say so (`false`, 0 or an empty result): the GPU canvas engine (`canvas_*`, docs/canvas.md),
  `surface_create` (second windows), `set_fixed_surface` and `set_max_frame_latency`. Use the Direct3D 11 backend for those.

Measurements and the recommendation: see the notes of the WebGPU prototype (Wren repository, `docs`), and `CHANGELOG.md`.

## Partial redraw (damage regions)

When only a small part of the window changed since the last frame (a blinking caret, a hovered control, a progress bar,
a video, a local CSS animation), the renderer can rasterize and present only the changed rectangles instead of the whole
window. The application marks the changed boxes between `frame_begin` and `frame_submit` (`render/damage.odin`):

```
render.set_partial_redraw(r, true)         // or draw.set_partial_redraw(c, true)
...
render.frame_begin(r, clear)
render.damage_begin(r)                      // open a region (once; nothing marked = draw nothing)
render.damage_add(r, {x0, y0, x1, y1})      // each changed rectangle, screen pixels, as many as needed
render.damage_scroll(r, rect, dx, dy)       // a scrolled view (presented as a block copy where the backend can)
... draw ...
render.frame_submit(r, frame)
render.frame_end(r)
```

The region is the union of the rectangles, with near ones merged so the list stays bounded (`MAX_DAMAGE_RECTS`). The
renderer clips every frame-target batch to the region (a batch that touches none of it is skipped) and clears only the
region; layers and filter passes run whole (they are intermediate images composed back into the frame). A frame that
opens a region and marks nothing draws and presents nothing. Not calling `damage_begin` means the whole frame is
damaged, exactly as before: the default is lossless.

Correctness is checked by `render.damage.verify` (`set_damage_verify`, or the environment variable
`TOOLKIT_DAMAGE_VERIFY=1`): every frame is also rendered in full and compared; the first differing pixel and the
rectangle it lies in are printed. For development only (it costs a full extra frame and read-backs).

Counters for `wren ctl stats` / diagnostics: `damage_stats(r)` returns the rectangles added and kept, the pixels the
region covers and the pixels of the whole frame, and whether a region is in effect.

### How each backend presents a partial frame

* **Direct3D 11 / DXGI** (`render/damage_d3d.odin`): `Present1` with `DXGI_PRESENT_PARAMETERS` carries the dirty
  rectangles (`pDirtyRects`) and, for a scrolled view, the moved block (`pScrollRect` / `pScrollOffset`). A flip swap
  chain (`FLIP_DISCARD` / `FLIP_SEQUENTIAL`) does **not** keep the back buffer's content between frames: the back buffer
  just acquired holds some earlier frame, how old depending on the buffer count. So a partial frame redraws not only
  this frame's region but the **union of the regions of the last `buffer_age` frames** (the buffer-age scheme), so the
  back buffer holds the same pixels a fully kept buffer would. The age is the swap chain's buffer count (2 or 3); until
  that many partial frames have been presented, a partial frame falls back to a full one. Tearing presents
  (`ALLOW_TEARING`) forbid dirty rectangles, so they present in full.
* **WebGPU / wgpu-native**: the pinned version (29.0.1.1) exposes only `SurfacePresent`, **not** a present-with-damage
  entry point, and a surface texture does not keep its content between frames either. So the renderer composes every
  frame into a **persistent render target** kept across frames (`render/damage_wgpu.odin`): a full frame clears it and
  draws everything; a partial frame loads it (`LoadOp::Load`, keeping the content) and draws only the scissored
  rectangles. The whole target is then copied to the surface texture and presented in full. **The rasterization is
  partial (the win: fewer pixels shaded, fewer pictures replayed); the present is full** — the documented limit of this
  backend until wgpu-native gains present-with-damage. When that lands, the full copy can be replaced by presenting the
  dirty rectangles, as on Direct3D 11.
