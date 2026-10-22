# Text: `font` on DirectWrite, `draw.glyph_run`

The `font` package is a text stack for applications that lay text out themselves (a web browser first): faces, font
cascades with per-character fallback, shaping, bidi, line breaks, carets, and glyph bitmaps in an atlas. Everything
comes from DirectWrite (the platform): no font file parsing, no shaping or bidi tables of our own.

## Faces and cascades

| Call | What |
| --- | --- |
| `load_system(s, family, weight, style, stretch)` | A face of the system collection (Windows' "font family" model: `"Segoe UI"`, `"Segoe UI Semibold"`, `"Arial Black"`). Missing bold / italic are simulated by DirectWrite. Shared by every request that resolves to the same font. |
| `has_system_family(s, family)` | Whether the system has that family. |
| `load_from_file(s, path, index)` | A face of a font file (collections: `index`). |
| `load_memory(s, data, owned, index, simulations, family, weight, style)` | A face from memory (web fonts: the decoded sfnt). The bytes go through a custom `IDWriteFontFileLoader` whose keys are never reused. `load_from_memory` / `load_embedded`: shortcuts. |
| `with_simulations(s, face, bold, oblique)` | The same face with synthetic bold / slant (CSS `font-synthesis`). |
| `axes(s, face)`, `with_variations(s, face, values)` | Variable fonts: the axes, and an instance at axis values (`font-variation-settings`, weight / width axes). Windows 10 1803+. |
| `cascade(s, entries, features, no_system_fallback)` | A `Font_Id` that takes each character from the first entry whose `ranges` (CSS `unicode-range`) include it and whose face has it, then from the **system fallback** (`IDWriteFontFallback::MapCharacters`, based on the first face's family, weight and style), then from the first face (its .notdef). `features`: OpenType features for every face (`font-feature-settings`, `font-variant-*`, `font-kerning`). A face is its own one-entry cascade. |
| `unload(s, id)` | Frees a font, the shaped words and the glyph bitmaps that use it. Not while anything else uses the state. |
| `metrics(s, id, size)` | Ascent, descent, line height, x-height, cap height, underline and strike-through offset / thickness (the first face's). |

Combining marks, variation selectors, joiners and emoji modifiers stay in the face of their base; when the base goes to
the system fallback, the whole cluster goes with it (emoji ZWJ sequences: 👩‍💻, 🏳️‍🌈).

## Shaping

`shape(s, id, size, text, opts, allocator) -> Shaped`: one line of UTF-8 text to glyphs.

- **Bidi**: the line is split into directional runs (UAX #9, `IDWriteTextAnalyzer::AnalyzeBidi`) with
  `opts.direction` as the paragraph direction (`Auto`: the first strong character), and the runs are put in visual
  order (L2). A caller that resolved bidi itself (a layout engine, per line) passes `one_run = true`: the text is one
  run in `direction`.
- **Words**: each run is cut into words at U+0020 and each word is shaped on its own and cached (as Blink's word
  cache): script analysis (`AnalyzeScript`; ASCII reuses one analysis), face itemization (above), then `GetGlyphs` /
  `GetGlyphPlacements` with the cascade's features (ligatures, kerning, contextual forms, mark positioning, Arabic
  joining, Indic reordering, mirroring in right-to-left runs...).
- **Spacing**: `letter_spacing` after each character (and optional ligatures off, as CSS wants), `word_spacing` after
  each U+0020 / U+00A0, `justify` after each U+0020.

`Shaped.glyphs` are in **visual order** (left to right): face, glyph index, position (x from the text origin, y down),
advance, the byte index of its cluster, `rtl`. `Shaped.clusters` are in **logical order**: bytes `[start, end)`,
visual extent `[x0, x1)` (spacing included), `rtl`. Carets and hit testing:

- `caret_x(sh, text, index)`: x of the caret before byte `index` (in a right-to-left cluster, its right edge; inside a
  ligature, the cluster shared out evenly between its characters).
- `hit_index(sh, text, x)`: the byte index whose caret is nearest to `x`.
- `x_from_index`, `index_from_x`: the same from a string.

`measure(s, id, size, text, opts)` is `shape(...).width` without building the glyph list: what a layout engine calls.
`text_width(s, id, size, text)` is `measure` with default options.

**Threads.** Loading faces, shaping, measuring and the analyses may run on any thread at once. The word cache is sharded
(64 shards, each with two generations: a full generation is dropped when the next one fills, so it stays bounded:
`Settings.word_cache` words), and each thread keeps the widths of the short words it measured last in a small cache of
its own (no lock on a hit).

## Analyses

- `bidi_levels(s, text, dir)`, `bidi_runs`, `visual_order(runs)`, `reorder(levels)`: UAX #9 levels per byte and L2.
- `line_breaks(s, text)`: UAX #14 break opportunities (`AnalyzeLineBreakpoints`, with DirectWrite's dictionaries for
  Thai, Lao, Khmer, Myanmar).

## Glyph bitmaps and drawing

`glyph_image(s, face, gid, size, subpixel)` rasterizes on first use (`IDWriteGlyphRunAnalysis`, grayscale antialiasing,
`Settings.rendering` / `grid_fit`) at `Settings.subpixel_steps` horizontal positions per pixel (`subpixel(s, x)` splits
a pen x). Color glyphs (COLR / CPAL: Segoe UI Emoji) are translated into layers (`TranslateColorGlyphRun`), each layer
rasterized and composited "over" into a straight-alpha sRGB RGBA bitmap.

Bitmaps live in **atlas pages** kept on the CPU (gray: 1 byte per texel; color: 4). Each draw context uploads what
changed since it last looked (`atlas_sync_page`), so several renderers can share one font state. A page is never
cleared while a frame may still draw from it: pages remember the atlas clock of their last use, contexts the clock at
the start of their frame (`atlas_begin_frame`); when every page of a kind is in use and the limit is reached
(`Settings.max_gray_pages` / `max_color_pages`), the least recently used page no current frame drew from is cleared,
else one more page is made. (The stb_truetype atlas cleared itself in the middle of a frame when it was full: glyphs
drawn earlier in that frame then showed whatever was rasterized over them.)

A cleared page starts a new **epoch** (`Glyph_Image.epoch`): retained drawing keeps `Page_Ref{page, epoch}` for the
pages its glyphs are on and checks them before replaying (`atlas_pages_hold`, which also marks the pages used by the
current frame). New rendering settings (`set_settings`: subpixel steps, rendering mode, grid fit, color glyphs)
forget the cached bitmaps and bump `atlas_settings_generation`; `clear_atlas` clears every page. After a device loss
the draw context uploads its pages again from the CPU copy.

The draw layer (`draw/text.odin`):

- `draw.glyph_run(dc, size, pos, color, glyphs)`: draws shaped glyphs with the text origin at `pos` (left, baseline):
  coverage glyphs are `KIND_GLYPH` instances sampling a gray page (`t0`; a page change starts a batch), color glyphs
  are `KIND_IMAGE` instances of a color page (tinted by the text's alpha). Under scale + translation glyphs snap to the
  pixel grid at their subpixel position; scaled text is rasterized at its screen size beyond
  `TEXT_RASTER_TOLERANCE`; under rotation / skew the quads go through the GPU transform (at their subpixel position in
  local units when not rescaled). Inside `draw.picture_begin` / `picture_end` the run is recorded with its pages (see
  [draw.md](draw.md), Retained drawing).
- `draw.text(dc, id, size, pos, color, s)`, `draw.text_ex(..., opts)`: shape then `glyph_run`.

The coverage is raw (linear) coverage, as DirectWrite gives it before Direct2D applies its gamma: the renderer's text
correction (`render.Text_Rendering`, Skia's) applies to it as it did to stb_truetype's.

## Slug: glyphs drawn from their outlines

`Settings.text_renderer = .Slug` (default `.Atlas`) makes `draw.glyph_run` draw glyph outlines on the GPU with the Slug
algorithm (Eric Lengyel; JCGT 6(2), 2017; the shaders are MIT, the patent is in the public domain; credit in
NOTICE.md). No bitmap is made: the glyph's quadratic Bézier curves are in a texture and the pixel shader computes the
coverage of each pixel from the curves of its band. The text is sharp at any size and under any rotation or skew, glyphs
sit at their exact subpixel position, and a scale change (page zoom, a pinch, a press animation) costs no
re-rasterization: a picture of Slug text stays valid at any scale. Color glyphs (emoji) stay atlas images.

The path, from the font to the screen:

1. **Outline** (`slug_outline.odin`, `slug_dwrite.odin`): `Outline` is closed contours of quadratics in em units (y up). A
   provider (`Outline_Provider`, replaceable with `slug_set_provider`) fills it: on Windows DirectWrite's
   `GetGlyphRunOutline` (variable instances and simulated bold / slant included). DirectWrite hands out cubics: those
   that are degree-raised quadratics (every TrueType glyph) come back as the exact quadratic, true cubics (CFF) are cut
   into pieces within `Settings.slug_tolerance` (em). A TrueType / CFF reader in Odin can replace the provider on other
   platforms.
2. **Glyph data** (`slug_build.odin`): curve texels (RGBA16F; a contour of n curves takes n+1 texels because a curve ends
   where the next starts), and band texels (RG16UI): horizontal and vertical bands (the count per axis is chosen to
   keep the fullest band small), each a list of the curves that touch it (with a 1/1024 em overlap, flat curves left out,
   sorted by descending far coordinate so the shader stops early, identical neighbours sharing a list).
3. **Store** (`slug_cache.odin`): `slug_glyph(s, face, gid)` builds on first use and caches per (face, glyph). Data lives in
   pages of 4096 texels, a page being one row of each texture; a glyph's data is in one page. `Settings.slug_pages` pages
   are kept, then the least recently used page that no current frame draws from is cleared (new epoch: pictures that
   drew from it are stale, `slug_pages_hold`), else one more is made. A glyph the provider has no outline for, a color
   glyph, or one that does not fit a row is drawn from the atlas (`Slug_Kind.Atlas`); a space is `Blank`.
4. **Draw** (`draw/slug.odin`, `render/slug.wgsl`): a glyph is one `KIND_SLUG` instance in the ordinary instance list (so
   order, clips, fades, transforms and pictures are as for any primitive); `slug_runs` tells the renderer which ones, and
   `frame_submit` draws a batch in pieces, switching between the two pipelines in order. The vertex shader grows each
   glyph's box by half a pixel on screen whatever the transform (the reference's dynamic dilation); the pixel shader is
   the reference's, then the same text correction as the atlas path (`render.Text_Rendering`), the clip shapes and the
   color. `slug.wgsl` is read after `rect.wgsl` (one module: the shared helpers are written once); WebGPU compiles it as it is, Direct3D 11 uses the HLSL naga writes from it.

`-define:FONT_TEXT_RENDERER=slug` makes Slug the default of a build (the pixel tests of the other packages run with
it: all pass except the ones that count atlas pages or compare 8-bit atlas coverage). `odin run tools/textcompare --
-sweep` measures a page zoom animation (every frame at a new scale: the atlas rasterizes again, Slug does not).

Positions: the pen is not rounded across; the baseline is put on a whole pixel (of the screen when the transform is a
scale and a translation, as the bitmaps do). There is no hinting: horizontal stems are as the outline says (the Slug
README suggests sizes whose cap height is a whole number of pixels).

## Limits

- Grayscale antialiasing only: ClearType needs the background under each glyph (dual-source blending, opaque targets),
  which layers and translucent backgrounds do not give.
- Color glyphs: COLR v0 layers. Bitmap (sbix / CBDT / PNG) and SVG glyphs are drawn from their outline when they have
  one (DirectWrite's `TranslateColorGlyphRun` is asked for outline formats only), COLR v1 paint trees from their v0
  fallback layers (Segoe UI Emoji has both). "Text color" layers are black.
- No kerning or ligature across a space (words are shaped apart, as Blink does with its word cache).
- Horizontal text only.
- Before Windows 8.1 (no `IDWriteFactory2`): no system fallback, no color glyphs, ClearType analyses averaged to gray.
