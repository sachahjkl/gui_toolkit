# Frame formats

A frame is stored in one of two formats:

- **8 bits a channel** (B8G8R8A8): an opaque window, an offscreen renderer, a translucent window that blends in sRGB.
- **Half floats** (R16G16B16A16_FLOAT): a translucent window that blends in linear light. On Direct3D 11 that is every
  DirectComposition window in the linear space (`render_d3d.odin`, `composition_format`). On WebGPU it is a surface the
  compositor takes with its alpha, premultiplied, when the surface offers half floats (`wgpu_wants_fp16`).

## Why half floats

DirectComposition reads an 8-bit buffer as sRGB values. A frame blended in linear light must reach it as scRGB, which
is half floats. Linear values stored in 8 bits also lose the dark tones: their steps are visible bands. Half floats are
there for **precision in linear light, never for range**. Nothing the toolkit draws is meant past 1: a colour, an alpha
and a coverage are all in [0, 1]. HDR video is tone-mapped into an ordinary texture before it is drawn (`video.odin`).

## Why every output is clamped

An 8-bit target clamps what a shader writes to [0, 1] before blending, and clamps a blend factor too. A half-float target
keeps the value as it is. A value past 1, below 0 or infinite then blends into results an 8-bit frame never holds. For
example, a stripe factor of 3 from subpixel text weighs what is under it below zero, and an infinity gives a NaN at the
next blend. A translucent window shows such a pixel as a hole: the desktop or the window behind it.

So every fragment shader that draws instances saturates its outputs: `ps_main` (shapes, text, images, layer
composites, shadows, gradients, blend-mode composites), `ps_slug`, and both outputs of the per-stripe shaders
(`ps_main_dual`, `ps_slug_dual`). A saturate per fragment costs nothing that can be measured. With it, the two formats
hold the same values, and a scene tested in 8 bits is right in half floats.

Refused: a clamp only when the target is half floats. It costs a branch or a second pipeline per format, and it keeps
two behaviours where one is enough.

The filter passes (`filter.wgsl`) write layers only. What they make reaches a frame through a layer composite of
`ps_main`, which clamps it.

Not covered: an application shader's colour (`app.wgsl`). Its alpha is already saturated. Its colour is the
application's: a change of `app.wgsl` makes the compiled shaders of every program stale.

## How the tests and the verify see both formats

- `render.init_offscreen(..., half_float = true)` makes the offscreen frame a translucent window's. The session asks for
  it with `Options.half_float`. `read_pixels` gives that frame as an 8-bit frame holds it (clamped). `read_pixels_float`
  gives its values unclamped, so a test can see what the window gets.
- The damage verify (`render.damage.verify`, `damage_side_frame`, `damage_compare`) compares frames in their own format,
  texel by texel, to the bit. Before, it skipped half-float frames, the format of the windows where holes were seen.
- `tests/partial_redraw` runs its scenes in both formats. Each checks that its last frame is exact and opaque: every value
  is finite and in [0, 1], and alpha is 1, both within a half's rounding.

The WGSL is the source. The HLSL in `src/render/shaders` and its compiled `.dxbc` are generated from it by `tools/shaders`.
