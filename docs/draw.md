# Drawing: transforms, clips and images

The `draw` package is the immediate-mode layer under `ui`: you can also use it on its own (see `examples/smoke` and
`examples/transforms`). This page covers the 2D transforms, the clips and the images added in 0.4.0, and the layers (group opacity) and
offscreen rendering added in 0.4.1.

![examples/transforms](screenshots/transforms.png)

## Affine transforms

```odin
Affine :: struct { a, b, c, d, e, f: f32 }

//   x' = a*x + c*y + e
//   y' = b*x + d*y + f
```

The convention is the one of CSS `matrix(a, b, c, d, e, f)`, canvas `setTransform` and SVG, so a CSS matrix goes in
as is: `draw.Affine{a, b, c, d, e, f}`. Screen space is y-down: a positive angle turns clockwise on screen, as CSS
`rotate()` does.

| Proc | Meaning |
|---|---|
| `AFFINE_IDENTITY` | identity |
| `affine_mul(m, n)` | `m` after `n`: `apply(mul(m, n), p) == apply(m, apply(n, p))`. CSS `transform: t1 t2` is `mul(t1, t2)` |
| `affine_translate(t)`, `affine_scale(s: Vec2)`, `affine_rotate(radians)`, `affine_skew(ax, ay = 0)` | constructors (CSS `translate`, `scale`, `rotate`, `skew`) |
| `affine_around(m, origin)` | `m` around `origin` (CSS `transform-origin`) |
| `affine_apply(m, p)`, `affine_apply_vector(m, v)` | point / direction |
| `affine_inverse(m) -> (Affine, ok)` | inverse; `ok = false` when singular (zero scale) |
| `affine_bounds(m, r) -> Rect` | axis-aligned bounds of a transformed rect |
| `affine_determinant`, `affine_scale_factor`, `affine_is_identity`, `affine_is_scale_translate` | queries |

### The transform stack

```odin
draw.push_transform(dc, draw.affine_around(draw.affine_rotate(0.3), draw.rect_center(card)))
draw.rect(dc, card, color, 12)            // rounded corners, border, shadow: all rotate
draw.text(dc, font_id, 15, pos, white, "Rotated")
draw.image(dc, tex, icon_rect, radius = 6)
draw.pop_transform(dc)
```

- `push_transform(dc, m)`: what is drawn next goes through `m` first, then through the transforms already pushed
  (nesting like CSS stacking contexts: a child's screen transform is `parent * child`).
- `pop_transform(dc)` pops one level. `pop_xform` is the same proc (kept for `push_scale`).
- `push_scale(dc, center, s)` is unchanged: scales around a screen point, on top of the current transform.
- `current_transform(dc)` returns the local-to-screen matrix; `affine_inverse` of it maps a mouse position into the
  local space (hit testing).

Everything `draw` draws follows the transform: rects (rounded, per-corner radii, borders, soft shadows), per-corner
gradients (`rect_corners`), text and images. Sizes given in local units (radius, border, shadow softness) scale with
it.

### How it is drawn

- **Uniform scale + translation** (no rotation or skew): baked on the CPU into the instance, as before. This is the
  path of `push_scale` and of everything drawn without a transform; its output is pixel-identical to 0.3 (except
  that the blur of soft shapes now scales with them).
- **Anything else**: the matrix goes once per pushed level into a per-frame table (a structured buffer); each
  instance carries its index (`Rect_Inst.xform`). The vertex shader transforms the 4 corners and grows the quad by
  one screen pixel; the pixel shader evaluates the rounded-rect distance in **local** space and divides it by its
  screen-space rate of change (derivatives of the local position, exact for an affine map). Edges keep a 1 px
  antialiased ramp under rotation, skew and non-uniform scale.
- **Text** is laid out at its nominal size (so `font.text_width` still measures it), but when the transform scales it
  by more than 10 % the glyphs are rasterized at the on-screen size (`TEXT_RASTER_TOLERANCE`): scaled text stays
  sharp. Under scale + translation the glyphs also snap to the pixel grid. Rotated text samples the atlas
  bilinearly.

## Clips

- `push_clip(dc, r)`: as before, a scissor rect (free). Under rotation or skew it becomes the screen bounds of `r`
  plus an exact per-pixel clip of `r`.
- `push_clip_rounded(dc, r, radii: [4]f32)`: clips to a rounded rect in the **current local space** (any
  transform), antialiased, with the same corner shape as `rect` (so a clip matches a box drawn with the same radii).
  Use it for `overflow: hidden` + `border-radius`, or to clip the content of a rotated element. Nested shapes multiply
  (up to `render.MAX_CLIP_DEPTH` = 8 deep). The scissor is the shape's bounds, so pixels outside cost nothing.
- `pop_clip(dc)` pops either kind. `current_clip(dc)` returns the scissor rect.

## Layers: group opacity

```odin
draw.push_layer(dc, bounds, 0.5)      // bounds: current local space, must contain what is drawn
draw.rect(dc, a, red)                  // overlapping shapes...
draw.rect(dc, b, blue)                 // ...do not show through each other
draw.pop_layer(dc)                     // composited once, at 50 %
```

`push_alpha` fades every primitive on its own: where two of them overlap, the one below shows through. CSS
`opacity` (and any "fade this group" effect) needs the group drawn first, then blended once: `push_layer` /
`pop_layer` do that with an offscreen render target.

- The layer covers the screen bounds of `bounds` (through the current transform), cut to the current clip and to
  the frame; pixels drawn outside are lost. Pass tight bounds: the cost is the layer's area.
- Inside, everything works as outside: transforms, clips (rounded, rotated), images, text, nested layers, alpha.
  The alpha stack restarts at 1 inside a layer; the layer's `alpha` times the enclosing alpha applies when it is
  composited.
- The composite is pixel for pixel (`render.FLAG_LAYER`: texels fetched, no filtering), with no transform and no
  clip shape (the content was already transformed and clipped).
- Layers are linear fp16 (`R16G16B16A16_FLOAT`), premultiplied: an opaque layer looks like no layer (antialiased
  edges may differ by a couple of 8-bit levels, the layer keeping more precision).
- Render targets come from a pool in the renderer (`render.acquire_target`, sizes rounded up to 128 px, released
  after 120 unused frames, `render.release_targets`, `render.targets_bytes`).
- A layer that would be empty, or larger than `render.max_texture_size`, falls back to `push_alpha`.
- `draw.layer_depth(dc)`: layers open. `end_frame` closes any left open.

How it is drawn: batches carry a `target` (0 = the frame, k = `layers[k - 1]`); `frame_submit` draws the layers
first, in completion order (an inner layer before the outer one that composites it), each with its own viewport
and `target_origin` (the screen pixel at its texel 0, subtracted by the vertex shader and added back for clip
shapes and scissors), then the frame.

## Offscreen rendering (tests, export)

```odin
render.init_offscreen(&r, {64, 64}, warp = true)   // no window; WARP = software rasterizer, deterministic
// ... draw.begin_frame / render.frame_begin / draw / draw.end_frame / render.frame_end as usual
pixels := render.read_pixels(&r)                    // RGBA8, sRGB, top-down
render.destroy(&r)                                  // releases every GPU object
```

`tests/layers` uses it to check group opacity against direct drawing pixel by pixel.

## Images

```odin
tex := render.create_texture_rgba(&r, w, h)                 // mips = true by default
render.update_texture_rgba(&r, tex, 0, 0, w, h, pixels)      // RGBA8, sRGB, straight (not premultiplied) alpha
draw.image(dc, tex, dst_rect)                                 // whole texture
draw.image(dc, tex, dst_rect, src = {{0, 0}, {32, 32}}, tint = draw.WHITE, radius = 8)
draw.image_corners(dc, tex, dst_rect, src, tint, radii)      // per-corner radii
draw.image_tiled(dc, tex, dst_rect, tile_rect)               // repeat (background-repeat)
render.destroy_texture(&r, tex)
```

| Proc | Notes |
|---|---|
| `render.create_texture_rgba(r, w, h, mips := true) -> Texture` | 0 when out of range (`render.max_texture_size(r)`, 16384 on feature level 11) |
| `render.update_texture_rgba(r, tex, x, y, w, h, pixels, stride := 0)` | sub-rectangle upload; `stride` in bytes (0 = `w * 4`) |
| `render.destroy_texture(r, tex)` | the handle may be reused by a later create |
| `render.texture_size(r, tex) -> [2]int` | |
| `draw.image(dc, tex, dst, src: Rect = {}, tint: Color = WHITE, radius: f32 = 0)` | `src` in texels, zero = whole texture |
| `draw.image_corners(dc, tex, dst, src, tint, radii: [4]f32)` | |
| `draw.image_tiled(dc, tex, dst, tile: Rect, tint = WHITE, radii = {})` | one copy of the whole texture on `tile`, repeated, cropped to `dst` |

- **Color**: pixels are sRGB and not premultiplied (what PNG / JPEG decoders and the web produce). The upload
  converts them to premultiplied alpha in linear light, stored as `R8G8B8A8_UNORM_SRGB`: the sampler decodes to
  linear before filtering, so bilinear filtering and mip averaging are done in linear light on premultiplied values
  (no dark fringes around transparent pixels), matching the renderer's linear blending. `tint` is a linear color
  with straight alpha, like every other color in `draw`; the alpha stack applies.
- **Filtering**: trilinear. Mips are regenerated (`GenerateMips`) before the first frame that follows an update.
  Without tiling, sampling never reads outside `src` (sprite sheets do not bleed).
- **Tiling** uses the hardware wrap mode on the whole texture: seamless, one instance, the tile can be any size and
  offset (scrolling backgrounds). For one-axis repeat make `dst` one tile tall or wide. Repeating a sub-rectangle of a
  texture is not supported in one draw: draw one `image` per tile.
- **Batching**: glyphs read the atlas (t0) and images their own texture (t1), so text, shapes and one image share a
  batch; only switching to a different image (or a different scissor) starts a new draw call.

## Cost

`Rect_Inst` grew from 128 to 144 bytes (transform index, clip index, flags). Measured with `examples/transforms`
(`--stress=N --bench=300`, `-define:GPU_TIMING=true`, 2244 x 1489 window, release build):

| Scene | Instances | Transforms | Draw calls (CPU) | `end_frame` (upload + submit) | GPU |
|---|---|---|---|---|---|
| demo page | 319 | 9 | 0.06 ms | 0.01 ms | 0.56 ms |
| 2,000 cards, flat (CPU-baked path) | 14,890 | 0 | 1.50 ms | 0.086 ms | 0.51 ms |
| 2,000 cards, each rotated | 14,890 | 2,000 | 1.62 ms | 0.090 ms | 0.64 ms |
| 8,000 cards, flat | 62,890 | 0 | 6.47 ms | 0.34 ms | 1.05 ms |
| 8,000 cards, each rotated | 62,890 | 8,000 | 7.09 ms | 0.50 ms | 1.08 ms |

The widget gallery (`fidget --bench=400`, pages 0 and 2) measures the same as 0.3.2 (0.60 / 1.02 ms per frame).

## Limits

- A rotated or skewed `push_clip` / `push_clip_rounded` costs a little pixel-shader work for every pixel drawn inside
  its bounds; more than 8 nested clip shapes are ignored (the outermost 8 apply).
- Soft shapes (shadows, `soft > 1`) blur in local units: under a strong downscale the blur can drop below a pixel.
- Rotated text is the 1x glyph bitmap, sampled bilinearly (slightly softer than axis-aligned text, no hinting).
- Perspective (3D) transforms are not supported (2D affine only).
- A layer costs one render target of its size and a full-screen-sized fill at most; dozens of large layers per
  frame are expensive (callers should fall back to `push_alpha` when the group holds a single primitive, which is
  exact).
