# A table per channel

The code is `src/image/lut.odin` (the tables, applied on the CPU), `src/draw/effects.odin` (`filter_lut`) and
`src/render/filter.wgsl` (the `Lut` pass). A program's author reads [docs/draw.md](../../../docs/draw.md) and
[docs/image.md](../../../docs/image.md).

## Why

galerie's edits (levels, gamma, exposure, curves) ran on the CPU over every pixel at each move of a slider: a 50 MP
picture answered in hundreds of milliseconds. The GPU's effects had only colour matrices; a matrix cannot bend a curve
(levels' gamma, exposure in light, a curve's S). Its notes refused a second path that would show what the file would
not get.

## Decisions

- **One table for both.** `image.Lut` is the table the program builds once; `draw.lut_texture` uploads it as is
  (`render.LUT_SIZE` texels, RGBA: the four channels side by side), `image.lut_apply` writes the same into the file.
  The preview is the file: only the 8-bit rounding of the layer differs (within a value or two).
- **A 1D texture, not uniforms.** 256 entries x 4 channels do not fit the pass's constants beside the matrices, and a
  table changes when a slider moves: an upload of 1 KB into one texture. The pass reads it through `src2` (the shadow's
  and the mask's second source): no new binding, no new pipeline, one more mode.
- **Straight sRGB values, as the matrices.** CSS's `feComponentTransfer` and the file's 8-bit values are both straight
  sRGB: a table made for the file is right on the screen. Exposure is computed inside the table (decoded, scaled,
  encoded), not in the pass.
- **Linear between entries** (the bilinear sampler, the coordinate at a texel's centre for each entry): a smooth
  curve from 256 entries, and the identity table is the identity.
- **The texture is the program's.** The chain releases what it reads once done; it never releases a table (it is not
  a target of the pool). A cached layer (`cache_id`) keys on the texture and `lut_version`: a table changed under
  the same texture says so by its version.
- **Curves are Fritsch and Carlson's monotone cubic**: between two points the curve never goes past them (an editor's
  curve that overshoots clips the highlights the person did not touch).

## Refused

- A table in the pass's constants (too large beside the matrices, and a new layout for every backend).
- A 3D table (a colour cube): one channel's value then depends on the others (a look, a grade); levels, gamma,
  exposure and curves do not need it, and its size is 64 times as large. It can come as another mode.

## Direct3D 11

The HLSL and DXBC of `filter.wgsl` are written by `tools/shaders` on Windows (`.github/workflows/shaders.yml`): a
change of `filter.wgsl` made on Linux leaves them stale until the workflow runs on the branch (tests/shaders says so).
