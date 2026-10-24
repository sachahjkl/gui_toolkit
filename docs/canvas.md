# The 2D canvas engine (Direct3D 11)

`render/canvas.odin`, `canvas_types.odin`, `canvas.wgsl`. Added in 0.26.0. A renderer for the drawing model of the HTML 2D canvas (paths, gradients, images, the 26 composite operators, clips, shadows, filters), meant for programs that keep a bitmap per canvas and want it drawn on the GPU. It is not part of `draw`: it has its own targets and its own shaders (module `Canvas` of `tools/shaders`), and what it makes is an ordinary RGBA texture that `draw.image` shows.

```odin
tex := render.canvas_texture_create(&r, 800, 600, target = true)     // a canvas: a render target, kept while it lives
list: render.Canvas_List                                              // what the owner recorded since the last flush
// ... fill list.insts / paints / stops / heap / cmds / sources ...
render.canvas_submit(&r, tex, &list)                                  // replay it: a few draw calls
draw.image(&dc, tex, rect, {}, draw.WHITE)                            // show it as it is, no copy
px := make([]u8, 800 * 600 * 4)
render.canvas_read(&r, tex, 0, 0, 800, 600, px)                       // premultiplied sRGB RGBA8 (getImageData)
```

## Textures

`canvas_texture_create(r, w, h, target, mips = true)`: RGBA8 holding **premultiplied, sRGB-encoded** values whatever the renderer's blend space (`texture_space` says `Srgb`). `target = true`: a canvas drawn into by `canvas_submit`; else a source that `canvas_upload(r, t, x, y, w, h, pixels, stride)` fills (an `ImageBitmap`, a decoded image). With `mips` the chain is rebuilt before the next draw that samples the texture after it changed (`canvas_texture_changed` when level 0 was written another way). 0 comes back when the size is out of range or the device refuses. `canvas_set_opaque(r, t, true)`: no alpha channel (`alpha: false`), draws leave alpha at 1. `destroy_texture` frees a canvas and its clip masks. After a device loss the textures are recreated empty (same handle; `device_generation` changes); masks, layers and pooled textures are dropped.

`canvas_supported(r)`: false on the WebGPU backend (the functions then return false or 0 and the caller draws in software) and once the pipeline failed to build.

## Recording and replay

A `Canvas_List` holds what one flush draws, in order (`canvas_types.odin` describes each field):

- `insts`: 96-byte instances, a quad of device pixels with a geometry (`CG_RECT`, `CG_RRECT`, `CG_ELLIPSE`, or `CG_SHAPE`: a polygon whose edges are in `heap`, in bands by y), a transform from device pixels to local space, a paint and an operator;
- `paints`: solid colors, linear / radial (two circles) / conic gradients (stops in `stops`, evaluated in the shader), and images (source rectangle, wrap modes, four filters: nearest, bilinear, trilinear, anisotropic);
- `cmds`: `Draw` runs of instances (consecutive instances with the same operator, source, clip mask and scissor are one draw call), `Clip_Make` / `Clip_Free` (R8 masks, multiplied by their parent), `Put` (`putImageData`), `Snapshot` (`drawImage` of the canvas itself), `Layer_Begin` / `Layer_Fx` / `Layer_End` / `Layer_Free` (layers with color-matrix and gaussian-blur passes: shadows and `filter`), `Clear`;
- `sources`: the textures the draws sample (canvas textures or any RGBA texture, a converted video included).

Coverage is analytic for rectangles (exact box filter when axis-aligned), rounded rectangles and ellipses; polygons take 16 N-rook samples on their boundary pixels only, with the fill rule applied per sample, so the overlapping pieces of a stroke never count twice. The 11 Porter-Duff operators are blend states of the batch; the 15 blend modes read a copy of the backdrop. Large blurs run on an image reduced by 2, 4, 8 (`CANVAS_BLUR_DIRECT_SIGMA`).

`canvas_submit(r, target, list)` returns false when the pipeline is unavailable (WebGPU backend, device lost, shaders that failed to build), when `target` is not a canvas made with `target = true`, or when the GPU buffers could not be made; the owner then draws its recording in software.

## Reading back

`canvas_read(r, t, x, y, w, h, out)` waits for the GPU. `canvas_read_begin` / `canvas_read_ready` / `canvas_read_finish` / `canvas_read_cancel` copy into a staging texture and let the caller poll (the pixels of a canvas read while the page keeps running). `canvas_read_mask(r, t, id, out)` reads the R8 coverage of a live clip mask. `canvas_clear(r, t, color)` clears at once.

## Statistics and memory

`canvas_stats(r)` / `canvas_stats_reset(r)`: submits, draw calls, instances, copies, layers, clip masks, read-backs and uploads (counts and bytes). `canvas_pool_bytes(r)`: the pooled textures (clip masks, layers, snapshots) kept for reuse and released after `CANVAS_POOL_IDLE` submits unused.

## Tests

`tests/canvas` (`tools\test_backends.ps1 -Only canvas`, WARP, 12 tests): exact rectangle edges, alpha and source-over, ellipses and rounded rectangles, polygon coverage, even-odd and nonzero, gradients, the operators and blend modes against their formulas, clip masks, layers with blur and color matrix, image sampling, `Put` and read-back.
