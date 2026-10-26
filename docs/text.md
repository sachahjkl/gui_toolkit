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
| `unload(s, id)` | Frees a font, the shaped words and the glyph bitmaps that use it. Not while anything else uses the state. Its slot is reused by a later font: a `Font_Id` is the slot (low 20 bits) and its generation, so the id of an unloaded font reaches nothing (`valid` is false, no glyph, no width) even once the slot is taken. A state holds up to 2^20 fonts at once; loading and unloading is unlimited. |
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
  ligature, the cluster shared out evenly between its graphemes).
- `hit_index(sh, text, x)`: the byte index whose caret is nearest to `x`; always a grapheme boundary.
- `x_from_index`, `index_from_x`: the same from a string.
- `selection_spans(sh, text, lo, hi)` (`x_spans_of_range` from a string): the stretches of the line, left to right,
  that the characters `[lo, hi)` occupy on screen. One for text in one direction; several across a change of direction,
  where the stretch between the two carets would cover letters that are not selected. `ui.line_edit` and `ui.text_edit` draw
  one rectangle per stretch.

**Grapheme clusters** (`font/grapheme.odin`, UAX #29 on `core:unicode/utf8`'s segmentation): what a reader calls one
character, e.g. an emoji family (5 code points), a flag (2), a letter and its combining marks, a Hangul syllable, an Indic
conjunct. `grapheme_next(s, i)` and `grapheme_prev(s, i)` give the boundary after / before any byte index (also one inside a
code point or a cluster), `is_grapheme_boundary`, `grapheme_count`. The arrows, Backspace and Delete of `ui.line_edit` and
`ui.text_edit`, clicks (`hit_index`), the cut of a toast and the line breaks of `ui.wrap_lines` work on clusters: nothing
is ever left of a half emoji.

**Editing wrapped text** (`ui/text_lines.odin`, `ui/text_edit.odin`). `ui.text_visual_lines(fonts, font, size, text,
width)` gives the visual lines of edited text: each paragraph ("\n") breaks at the backend's line break opportunities
(`line_breaks` on the whole paragraph: spaces, hyphens, CJK, Thai / Lao / Khmer / Myanmar words), a word wider than the
line between grapheme clusters; trailing spaces stay on their line. A wrapped line's end is also the next line's start:
`visual_line_of(lines, index, upstream)` says which line the caret is on (`Text_Area.upstream`: after End, or a click
past a line's end). `ui.text_edit(..., wrap = true, auto_height = true, min_lines, max_lines)`: lines wrap at the box's
width (no horizontal scrolling; Up / Down / Home / End and the mouse follow visual lines; line numbers per paragraph), the
box is as tall as its lines within the limits, then scrolls. `Edit_Result.caret` is the caret in box coordinates (this
build); `ui.text_edit_caret_rect(a)` gives the caret and the selection's other end in window coordinates as last drawn
(completion popovers, input method windows). Example: the composer of `examples/fidget`.

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

**Big text.** A bitmap that does not fit a page (`Settings.page_size`, 2048) is never kept, and asking for one makes no
page and evicts none. `draw.glyph_run` therefore rasterizes at most `raster_size_limit(s)` pixels per em (half a page,
1024 by default) and draws the bitmap stretched: text of 1100 px at 200 % shows, a little soft, instead of vanishing.
`Settings.page_size` is read by `init` only. The Direct2D canvas of a color glyph (up to 4096 x 4096) is given back after a
glyph that needed more than 1M pixels.

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

## Color glyphs: the COLR interpreter, built-in emoji

`Settings.color_engine` says who draws COLR / CPAL color glyphs (`System`, the default: Direct2D, as before; `Builtin`:
this package).

**The interpreter** (`font/colr.odin`, `colr_raster.odin`, `colr_gsub.odin`; no DirectWrite in them, so Linux gets the same
emoji) reads the face's `COLR` and `CPAL` tables (`TryGetFontTable`: system fonts, files and memory fonts alike) and draws
the glyph at the requested pixel size on the CPU:

- COLR v0 layers and v1 paint graphs: `PaintColrLayers`, `PaintSolid`, linear / radial / sweep gradients (the three extend
  modes, the stop rules of the specification, the sweep angle bias), `PaintGlyph` (a clip: coverage is multiplied down the
  graph), `PaintColrGlyph` (its own clip box applies), every `PaintTransform` / `Translate` / `Scale` / `Rotate` / `Skew`
  with and without a center, `PaintComposite` with the 28 modes (Porter-Duff and the separable and HSL blend modes, in
  isolated groups), `ClipList` boxes. Palette 0; entry 0xFFFF is the text color (the glyph is then kept once per text color).
  Variable COLR is read as its default instance.
- Shapes are the glyph outlines of the Slug outline provider (`Outline_Provider`), kept per face in a cache of
  `Settings.colr_cache_kb`; scan conversion is exact horizontally and `Settings.colr_samples` times per pixel row vertically.
  The bitmaps go to the same Color pages, async queue and `uses_fg` handling as Direct2D's.
- Untrusted input: every offset is checked, a graph with a cycle or more than `COLR_MAX_PAINTS` nodes is refused (the glyph is
  then its plain outline), canvases are limited to `COLR_CANVAS_LIMIT`. `tests/colr` mutates a COLR table 400 times and
  builds hostile tables by hand (`hostile_test.odin`). The work of a glyph is bounded: the surfaces alive at once to
  `COLR_SURFACE_LIMIT` bytes (256 MiB; `Colr_Params.surface_limit`) and `COLR_MAX_COMPOSITES` (8) levels of `PaintComposite`
  inside one another; the pixels visited (fills, gradients, clips, composites; 16 per outline curve) to 256 times the
  canvas' area between `COLR_WORK_FLOOR` and `COLR_WORK_CEIL` (`Colr_Params.work_limit`). A glyph over a bound is refused
  and drawn as its outline. The drawing runs without the atlas lock (the other threads that draw are not held up), and
  two threads that draw the same glyph keep one bitmap.
- **Which glyphs go to Direct2D** (`Color_Engine.System`): a graph that nests a `PaintGlyph` in a `PaintGlyph` crashes
  Direct2D of Windows 11 24H2 as first released, so those are drawn here (`colr_nests_glyph`). The answer leans towards
  the interpreter: a graph that cannot be read to its end (a cycle, an offset outside the table, an unknown format, more
  than `COLR_MAX_PAINTS` paints) counts as nested, since it may hold the pattern further on; the interpreter refuses it and
  the outline shows. A face whose COLR table cannot be read at all (a base glyph list that does not fit the table) is not
  given to Direct2D either. The GSUB reader (`gsub_ligate`) is bounded too: one budget of steps, shared feature tables
  read once, at most 256 lookups; over it, the sequence is shaped the usual way.
- Against Direct2D on the color-fonts test glyphs the mean difference is 0.7 / 255; against Chrome / Edge on 115 emoji of
  Noto Color Emoji (`tools\emoji_board.ps1`) it is 0.3 to 0.7 / 255 at 16 to 64 px and 100 % to 175 %.

**Built-in emoji** (`font/emoji.odin`): `set_emoji_source(s, path)` or `set_emoji_source(s, data = ...)` hands the package an
emoji font (Wren ships Noto Color Emoji, `tools\fetch_emoji.ps1`). It loads on the first emoji that needs it. In shaping it
takes the characters drawn as emoji by default (`Emoji_Presentation`, regional indicators), any emoji followed by U+FE0F or
U+20E3 even when a face of the cascade has a text glyph, and it replaces the system's own color emoji font when a font
stack names one; ZWJ sequences, modifiers, flags, keycaps and tag sequences stay in one face. U+FE0E asks for text, and
a text-presentation emoji nothing else draws falls back to the emoji font before .notdef. Tag sequences (England, Scotland,
Wales) go through the face's GSUB `ccmp` ligatures (`gsub_ligate`), which DirectWrite does not apply to tag characters.
All 3 963 fully qualified sequences of Unicode 18's `emoji-test.txt` shape to one glyph (`tests/colr`).

## Limits

- Grayscale antialiasing only: ClearType needs the background under each glyph (dual-source blending, opaque targets),
  which layers and translucent backgrounds do not give.
- Color glyphs: COLR v0 layers. Bitmap (sbix / CBDT / PNG) and SVG glyphs are drawn from their outline when they have
  one (DirectWrite's `TranslateColorGlyphRun` is asked for outline formats only), COLR v1 paint trees from their v0
  fallback layers (Segoe UI Emoji has both). "Text color" layers are black.
- No kerning or ligature across a space (words are shaped apart, as Blink does with its word cache).
- Horizontal text only.
- Before Windows 8.1 (no `IDWriteFactory2`): no system fallback, no color glyphs, ClearType analyses averaged to gray.
