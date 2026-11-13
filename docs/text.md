# Text: the `font` package, `draw.glyph_run`

The `font` package is a text stack for applications that lay text out themselves (a web browser first): faces, font
cascades with per-character fallback, shaping, bidi, line breaks, carets, and glyph bitmaps in an atlas. On Windows,
by default, shaping and analysis come from DirectWrite; with the `native` backend, the only one on Linux, from a Rust
library ([font-backend.md](font-backend.md)). This page describes the DirectWrite path where they differ.

## Faces and cascades

| Call | What |
| --- | --- |
| `load_system(s, family, weight, style, stretch)` | A face of the system collection (Windows' "font family" model: `"Segoe UI"`, `"Segoe UI Semibold"`, `"Arial Black"`). Missing bold / italic are simulated by DirectWrite. Shared by every request that resolves to the same font. |
| `has_system_family(s, family)` | Whether the system has that family. |
| `load_from_file(s, path, index)` | A face of a font file (collections: `index`). |
| `load_memory(s, data, owned, index, simulations, family, weight, style)` | A face from memory (web fonts: the decoded sfnt). The bytes go through a custom `IDWriteFontFileLoader` whose keys are never reused. `load_from_memory` / `load_embedded`: shortcuts. |
| `with_simulations(s, face, bold, oblique)` | The same face with synthetic bold / slant (CSS `font-synthesis`). |
| `axes(s, face)`, `with_variations(s, face, values)` | Variable fonts: the axes, and an instance at axis values (`font-variation-settings`, weight / width axes). DirectWrite (Windows 10 1803+), and the native backend from the face's `fvar` table. |
| `cascade(s, entries, features, no_system_fallback, language)` | A `Font_Id` that takes each character from the first entry whose `ranges` (CSS `unicode-range`) include it and whose face has it, then from the **system fallback** (`IDWriteFontFallback::MapCharacters`, based on the first face's family, weight and style), then from the first face (its .notdef). `features`: OpenType features for every face (`font-feature-settings`, `font-variant-*`, `font-kerning`). `language`: the content's BCP 47 tag (CSS `lang`, e.g. `"sr"`, `"ja"`, `"zh-Hant"`), which selects a face's language-specific forms (`locl`: Serbian/Macedonian Cyrillic, Han unification of CJK, Romanian ș/ț...); empty when none. A face is its own one-entry cascade. |
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
  joining, Indic reordering, mirroring in right-to-left runs...) and the cascade's `language` as the shaping locale
  (the `locl` feature: Serbian / Macedonian Cyrillic, the Han unification of CJK, Romanian ș/ț). Two cascades that
  differ only in language are distinct `Font_Id`s, so the word cache tells their shaped words apart.
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

**Grapheme clusters** (`src/font/grapheme.odin`, UAX #29 on `core:unicode/utf8`'s segmentation): what a reader calls one
character, e.g. an emoji family (5 code points), a flag (2), a letter and its combining marks, a Hangul syllable, an Indic
conjunct. `grapheme_next(s, i)` and `grapheme_prev(s, i)` give the boundary after / before any byte index (also one inside a
code point or a cluster), `is_grapheme_boundary`, `grapheme_count`. The arrows, Backspace and Delete of `ui.line_edit` and
`ui.text_edit`, clicks (`hit_index`), the cut of a toast and the line breaks of `ui.wrap_lines` work on clusters: nothing
is ever left of a half emoji.

**A field's keys** (`ui.field_key(f, owner, key, mods)`): what a key does to a `Text_Field`, as `ui.line_edit` does it (the
caret by clusters and by words, Shift for the selection, Backspace and Delete with Ctrl for a word, Ctrl+A, the clipboard,
undo and redo). A field the keyboard reaches another way gives it its keys: the search of a menu opened with
`ctx_menu_open(..., search = true)` is a `Text_Field` edited by it, the menu keeping the arrows, Enter and Escape. That menu
keeps the corner and the width of its first layout while it filters.

**Its scroll bars** are the toolkit's: a `text_edit` scrolls itself and places its bars, which `ui.scrollbar_paint` draws as
it draws a view's (`draw_scrollbar`): the same track, the same thumb in the interface's greys, held a step toward the text. A
widget of a program that scrolls itself draws its bar with it too.

**Paste** (`src/ui/paste.odin`). Ctrl+V and Shift+Insert in a `line_edit` or a `text_edit`, and a field menu's Paste, do not
wait for the clipboard: the build that sees the key asks for the text (`ui.paste_request(key)`, `key` the widget's), and the
widget inserts it in a later build, when the answer has come (`ui.paste_answer(key)`): over its selection, in one undo step,
if it is still built and still has the focus. Otherwise the answer is dropped. The window's clipboard is asked with
`platform.clipboard_request`; `Build_Params.clipboard_get`, when a program gives one (its own clipboard in memory, a
test's), is read at once and its text given in the next build. A field reached another way names its `owner` for
`field_key`, `field_paste(owner)` and `field_menu(key, f, owner)`, and inserts the answer with
`field_paste_answer(f, owner)` in each build (the menu's search does). See [clipboard.md](clipboard.md).

**The clipboard's keys** are one set wherever text is typed (`ui.line_edit`, `ui.text_edit`, `term`): Ctrl+C or Ctrl+Insert
copies, Ctrl+X or Shift+Delete cuts, Ctrl+V or Shift+Insert pastes.

**Editing wrapped text** (`src/ui/text_lines.odin`, `src/ui/text_edit.odin`). `ui.text_visual_lines(fonts, font, size, text,
width)` gives the visual lines of edited text: each paragraph ("\n") breaks at the backend's line break opportunities
(`line_breaks` on the whole paragraph: spaces, hyphens, CJK, Thai / Lao / Khmer / Myanmar words), a word wider than the
line between grapheme clusters; trailing spaces stay on their line. A wrapped line's end is also the next line's start:
`visual_line_of(lines, index, upstream)` says which line the caret is on (`Text_Area.upstream`: after End, or a click
past a line's end). `ui.text_edit(..., wrap = true, auto_height = true, min_lines, max_lines)`: lines wrap at the box's
width (no horizontal scrolling; Up / Down / Home / End and the mouse follow visual lines; line numbers per paragraph), the
box is as tall as its lines within the limits, then scrolls. `Edit_Result.caret` is the caret in box coordinates (this
build); `ui.text_edit_caret_rect(a)` gives the caret and the selection's other end in window coordinates as last drawn
(completion popovers, input method windows). Example: the composer of `examples/fidget`.

**Syntax colouring** (`src/ui/text_edit.odin`). `ui.text_edit(..., highlight = &hl)` with a `ui.Text_Highlight` draws coloured
runs the caller classifies; the editor itself knows no language. `hl.spans(user, line_text, para, &out)` is called per
*visible* paragraph (never the whole document) and appends `ui.Text_Span{start, end, color}` byte ranges into `line_text`
(in order, non-overlapping); a byte no span covers uses the box's text colour, and a zero colour `{0,0,0,0}` falls back to
it too. Colouring a wrapped editor works: a span is drawn where it falls on each visual line. `hl.error_line(user, para)`
underlines a paragraph in `hl.error` (a zero colour falls back to a theme red) — for a line the caller's own validator
rejects. `Edit_Result.hover_line` is the paragraph under the pointer (or -1): show a `ui.tooltip()` with its message. The
cost is only the visible lines'. Example: an editor of content-blocker filters colours Adblock
syntax and underlines lines its engine would drop.

**Rich text** (`src/ui/rich_text.odin`). `ui.rich_paragraph(id, runs, max_lines)` draws a paragraph of `Rich_Run`s:
each run has its text and a `Rich_Style` (face, size, `bold`, `italic`, `code` (mono font, the theme's `code_bg`),
colour, background, `underline`, `strike`, `link`). Lines break at the backend's opportunities computed on the whole
text, so a word whose style changes in the middle is not broken there; "\n" always breaks; a word wider than the line is
cut between grapheme clusters; `max_lines` ends the last line with "…"; the box's `text_align` aligns the lines. The box
is full width and as tall as its lines (`Box.measure_y`: its height follows the width the layout gave it). Links: the
result's `link_hovered`, `link_clicked`, `link` and `link_focused` (the paragraph is a Tab stop; Tab / Shift+Tab go
through its links, Enter / Space choose one; the pointer is a hand over them). `ui.rich_links(text, style, &runs)` turns
plain text into runs whose web addresses (`http://`, `https://`) are links, without the sentence's closing marks
(`web_address_len` finds one). Bold and italic runs take the faces given
by `ui.set_family(state, regular, bold, italic, bold_italic)`, else the system's family, else simulated ones; a widget
asks `ui.styled_face(face, bold, italic)` and gets the same (a toast's title, a section's name). Layouts are kept by content
(`rich_layout_cached`): thousands of runs are laid out once. The geometry is public for selection and custom drawing:
`rich_layout`, `rich_text` (the whole text), `rich_index_at` (hit test), `rich_caret`, `rich_range_rects`,
`rich_link_at`. Example: `examples/markdown`.

**Selecting text outside fields** (`src/ui/selection.odin`). Labels, paragraphs and rich paragraphs built with
`.Selectable` (`next({flags = {.Selectable}})`, or `style({flags = {.Selectable}})` around a whole document: clickable
boxes in it stay buttons) share one selection that runs across boxes in build order. Press and drag selects (into the
nearest selectable box when the pointer leaves the text: above a box its start, below it its end), Shift+click
extends, a double click selects a word, a triple click the box's paragraph (the drag then extends by words /
paragraphs), Shift+Left / Right / Up / Down / Home / End move the moving end when no field has the keyboard, Ctrl+C
or Ctrl+Insert copies (in a dialog too: text selected in the dialog on top is copied, text behind it is not) (boxes joined by "\n"), Ctrl+A over a box selects it all, a press on nothing clickable clears (a press on a button
keeps it: a Copy button reads it on release). Text in a dialog or a popover selects like any other: their panel is
`.Press_Stop`, clickable only so that what is under it gets no press, so a press on it is a press on nothing, and a
selection stays on the surface it started on. A press on a link clicks the link. The pointer is the text cursor over
selectable text, the selection is drawn in the theme's "selection" colour behind the text. For apps: `selected_text`,
`has_selection`, `selection_serial` (moves with every change) and `selection_changed` (this build), `clear_selection`,
`select_box`. Example: `examples/markdown`.

`measure(s, id, size, text, opts)` is `shape(...).width` without building the glyph list: what a layout engine calls.
`text_width(s, id, size, text)` is `measure` with default options.

**Threads.** Loading faces, shaping, measuring and the analyses may run on any thread at once. The word cache is sharded
(64 shards, each with two generations: a full generation is dropped when the next one fills, so it stays bounded:
`Settings.word_cache` words); a shard's lock is shared by the threads that find their word in its current generation,
so the threads of a page shaping the same words read side by side. Each thread keeps the widths of the short words it
measured last in a small cache of its own (no lock on a hit). Every lock, and what was measured: [locks.md](locks.md).

## Analyses

- `bidi_levels(s, text, dir)`, `bidi_runs`, `visual_order(runs)`, `reorder(levels)`: UAX #9 levels per byte and L2.
- `line_breaks(s, text)`: UAX #14 break opportunities (`AnalyzeLineBreakpoints`, with DirectWrite's dictionaries for
  Thai, Lao, Khmer, Myanmar).

## Glyph bitmaps and drawing

`glyph_image(s, face, gid, size, subpixel)` rasterizes on first use (`IDWriteGlyphRunAnalysis`, grayscale antialiasing,
`Settings.rendering` / `grid_fit`) at `Settings.subpixel_steps` horizontal positions per pixel (`subpixel(s, x)` splits
a pen x). Color glyphs are drawn by Direct2D into a straight-alpha sRGB RGBA bitmap (see below for the versions of Windows).
`glyph_images(s, size, reqs, out, fg)` does the same for a whole run (`Glyph_Request{face, id, sub}`; face 0: nothing to
draw), and `slug_glyphs(s, glyphs, ppem, out)` for the Slug data: the atlas lock is taken once, shared, for what is
already there (threads that draw at once look up side by side), then alone per glyph made. `draw.glyph_run` uses them.

Bitmaps live in **atlas pages** kept on the CPU (gray: 1 byte per texel; color: 4). Each draw context uploads what
changed since it last looked (`atlas_sync_page`), so several renderers can share one font state. A page is never
cleared while a frame may still draw from it: pages remember the atlas clock of their last use, contexts the clock at
the start of their frame (`atlas_begin_frame`, until `atlas_end_frame`: a context between frames, a hidden window's, holds no
page); when every page of a kind is in use and the limit is reached
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

The draw layer (`src/draw/text.odin`):

- `draw.glyph_run(dc, size, pos, color, glyphs)`: draws shaped glyphs with the text origin at `pos` (left, baseline):
  coverage glyphs are `KIND_GLYPH` instances sampling a gray page (`t0`; a page change starts a batch), color glyphs
  are `KIND_IMAGE` instances of a color page (tinted by the text's alpha). Under scale + translation glyphs snap to the
  pixel grid at their subpixel position; scaled text is rasterized at its screen size beyond
  `TEXT_RASTER_TOLERANCE`; under rotation / skew the quads go through the GPU transform (at their subpixel position in
  local units when not rescaled). Inside `draw.picture_begin` / `picture_end` the run is recorded with its pages (see
  [draw.md](draw.md), Retained drawing).
- `draw.glyph_run_stroke(dc, size, pos, color, glyphs, width)`: the outlines of the same run as a line of `width`, half inside and half outside, its joins round (CSS `-webkit-text-stroke`).
- `font.glyph_ink_extent(s, face, gid, lo, hi, across)`: where a glyph has ink inside a band, in ems, from its outline, kept per glyph and band; `font.run_ink_spans(s, glyphs, size, top, bottom, gap)`: the same for a run, left to right, joined by their gap (the gaps of a skipping underline).
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
   provider (`Outline_Provider`, replaceable with `slug_set_provider`) fills it: with the dwrite backend DirectWrite's
   `GetGlyphRunOutline` (variable instances and simulated bold / slant included). DirectWrite hands out cubics: those
   that are degree-raised quadratics (every TrueType glyph) come back as the exact quadratic, true cubics (CFF) are cut
   into pieces within `Settings.slug_tolerance` (em). With the native backend, the Rust library's outlines.
2. **Glyph data** (`slug_build.odin`): curve texels (RGBA16F; a contour of n curves takes n+1 texels because a curve ends
   where the next starts), and band texels (RG16UI): horizontal and vertical bands (the count per axis is chosen to
   keep the fullest band small), each a list of the curves that touch it (with a 1/1024 em overlap, flat curves left out,
   sorted by descending far coordinate so the shader stops early, identical neighbours sharing a list).
3. **Store** (`slug_cache.odin`): `slug_glyph(s, face, gid)` builds on first use and caches per (face, glyph). Data lives in
   pages of 4096 texels, a page being one row of each texture; a glyph's data is in one page. `Settings.slug_pages` pages
   are kept, then the least recently used page that no current frame draws from is cleared (new epoch: pictures that
   drew from it are stale, `slug_pages_hold`), else one more is made. A glyph the provider has no outline for, a color
   glyph, or one that does not fit a row is drawn from the atlas (`Slug_Kind.Atlas`); a space is `Blank`.
4. **Draw** (`src/draw/slug.odin`, `src/render/slug.wgsl`): a glyph is one `KIND_SLUG` instance in the ordinary instance list (so
   order, clips, fades, transforms and pictures are as for any primitive); `slug_runs` tells the renderer which ones, and
   `frame_submit` draws a batch in pieces, switching between the two pipelines in order. The vertex shader grows each
   glyph's box by half a pixel on screen whatever the transform (the reference's dynamic dilation); the pixel shader is
   the reference's, then the same text correction as the atlas path (`render.Text_Rendering`), the clip shapes and the
   color. `slug.wgsl` is read after `rect.wgsl` (one module: the shared helpers are written once); WebGPU compiles it as it is, Direct3D 11 uses the HLSL naga writes from it.

`-define:FONT_TEXT_RENDERER=slug` makes Slug the default of a build (the pixel tests of the other packages run with
it: all pass except the ones that count atlas pages or compare 8-bit atlas coverage). `odin run tools/textcompare --
-sweep` measures a page zoom animation (every frame at a new scale: the atlas rasterizes again, Slug does not).

Positions: the pen is not rounded across; the baseline is put on a whole pixel (of the screen when the transform is a
scale and a translation, as the bitmaps do). By default there is no hinting (`Settings.slug_hint_ppem` asks for it with the native backend, [slug-small-text.md](slug-small-text.md)): horizontal stems are as the outline says (the Slug
README suggests sizes whose cap height is a whole number of pixels).

## Text per colour stripe

`Settings.subpixel_text` (`.Rgb`, `.Bgr`; default `.Off`) gives text a coverage per colour stripe of the screen's pixels: three
samples a third of a pixel apart instead of one, so it is sharper across at few pixels per letter, with faint colours on its edges.
For a window that is opaque, on a screen that has such stripes: many OLED panels have not, and there the colours show. It is the
application's to set; `system_subpixel_text` says what the system does (on Windows its ClearType setting and order; on Linux
fontconfig's `antialias` and `rgba`, as other applications read them: grey when it is not smoothed, its stripes unknown, vertical or
none; macOS grey).

- **Bitmaps** (the atlas, Windows): DirectWrite's ClearType analysis, its filter applied. A pixel's three coverages sit side by side
  in an ordinary Gray page, the bitmap three times as wide (`Glyph_Image.lcd`, `FLAG_LCD`): nothing changes in the pages, their
  upload or their eviction. They are read texel by texel, so only for bitmaps that land on the screen's pixels as they are
  (`draw.glyph_run`: baked, not capped); `Bgr` swaps the bytes when the bitmap is made.
- **Slug** (`slug_dual.wgsl`): a sample's coverage is over a box a pixel wide; taken a third of a pixel to each side it is three
  stripes each filtered over their neighbours, with no filter of its own. Small text takes two half-pixel samples per stripe (six
  in all, against four in grayscale).
- **Blending**: three coverages need a blend factor per channel, which is dual-source blending: the shader writes the colour and
  what to blend it by. Anything but such text writes its alpha on all three channels, the same blend as by the alpha to the bit
  (tested), so on Direct3D 11 the whole frame's target uses it (`rect_dual.wgsl`, around `ps_main` made a function by
  `module_source`) and no batch is split. On WebGPU only the Slug pipeline does, when the device has the `dual-source-blending`
  feature (`text_subpixel_supported`); `rect.wgsl` keeps its entry point as it is there, see the note above it.
- **Elsewhere**: a layer has one alpha per pixel, so the frame's own target is the only one blended per channel. There the usual
  shader averages the three coverages: the same glyphs and pictures are right in a layer, in grey. Text that does not run along the
  pixels' rows has no stripes: under a transform it is asked for in grey, and a picture recorded with them and replayed turned
  reads the row of coverages as one finer bitmap.

Text in stripes is a touch bolder (`Settings.slug_stripe_weight`, default `SLUG_STRIPE_WEIGHT_PX` = 0.2 pixels, at every size, as
MacType does): three thin stripes read lighter than grey text. The weight is across only (the stems' sides move out, the baseline,
the x-height and the tops stay), so the letters keep their lines. Slug only: the atlas's ClearType bitmaps are DirectWrite's.

The text correction (render.Text_Rendering) applies to each stripe. Changing the setting forgets the bitmaps and makes what was
recorded stale, as the other rendering settings do. `tests/subpixel` holds all of this on both backends.

## Color glyphs: the COLR interpreter, built-in emoji

`Settings.color_engine` says who draws COLR / CPAL color glyphs (`System`, the default: Direct2D, as before; `Builtin`:
this package).

**The interpreter** (`src/font/colr.odin`, `colr_raster.odin`, `colr_gsub.odin`; no DirectWrite in them: their tables come from DirectWrite on Windows and from the native backend elsewhere, so Linux gets the same emoji) reads the face's `COLR` and `CPAL` tables (`TryGetFontTable`: system fonts, files and memory fonts alike) and draws
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
  Noto Color Emoji (`tools/tk emoji_board`) it is 0.3 to 0.7 / 255 at 16 to 64 px and 100 % to 175 %.

**Built-in emoji** (`src/font/emoji.odin`): `set_emoji_source(s, path)` or `set_emoji_source(s, data = ...)` hands the package an
emoji font (Wren ships Noto Color Emoji, `tools/tk fetch_emoji`). It loads on the first emoji that needs it. In shaping it
takes the characters drawn as emoji by default (`Emoji_Presentation`, regional indicators), any emoji followed by U+FE0F or
U+20E3 even when a face of the cascade has a text glyph, and it replaces the system's own color emoji font when a font
stack names one; ZWJ sequences, modifiers, flags, keycaps and tag sequences stay in one face. U+FE0E asks for text, and
a text-presentation emoji nothing else draws falls back to the emoji font before .notdef. Tag sequences (England, Scotland,
Wales) go through the face's GSUB `ccmp` ligatures (`gsub_ligate`), which DirectWrite does not apply to tag characters.
All 3 963 fully qualified sequences of Unicode 18's `emoji-test.txt` shape to one glyph (`tests/colr`).

**One color glyph as pixels** (`src/font/color_canvas.odin`): `color_glyph_rgba(s, face, gid, size, fg)` rasterizes a single
color glyph to a straight-alpha RGBA `Color_Glyph{px, w, h, ox, oy}` at an exact em size, with `(ox, oy)` the offset from
the pen (baseline origin, y down) to the bitmap's top-left corner; `glyph_is_color(s, face, gid, size)` says whether a
glyph is drawn in color. Unlike `glyph_image`, nothing goes through the atlas or the draw layer: the caller owns the
pixels and composites them itself. This is the path a 2D canvas uses for emoji in `fillText` / `strokeText`: the glyph is
drawn as an image, so it takes the canvas transform, alpha, shadow and clip like any `drawImage`. The COLR interpreter
draws the glyphs it owns (`color_engine = .Builtin`, or the glyphs Direct2D must not be given); Direct2D draws the rest.
`fg` (sRGB) colors foreground / text-color layers. The pixels are on the allocator passed in (a temp allocator by
default). The signature is platform-neutral; off Windows (no color-glyph rasterizer yet) both functions compile and
report no color glyph, so a caller falls back to the outline.

## Find in page

`src/ui/find.odin` finds a needle in the text the interface shows (labels, wrapped paragraphs, rich paragraphs) after each
layout, in reading order, with the rectangles of each match whether on screen or scrolled away, and paints them behind
the text. The application owns the search field and the navigation:

```odin
ui.find(needle, scope)        // every build while searching ("" stops); scope: the box whose subtree is searched (0: all)
ms := ui.find_matches()       // the last layout's matches (window coordinates); Find_Match.index counts occurrences
n  := ui.find_count()
ui.find_set_current(i)        // the occurrence painted as current (-1: none)
```

Theme entries: `find_match background` (every match), `find_current background` (the current one). Matching ignores
case (simple folding, rune by rune). Limits: a match may span the runs of one rich paragraph but not two boxes; text the
build did not make is not searched (a part folded away); the matches are those of the last layout, so a new needle has its
matches one frame later.

Over a lazy column, what is far from the view is not built, so it cannot be read at every frame. The build that reads it all is
a sweep, made once for a needle:

```odin
lz := ui.lazy_begin(all = ui.find_sweep())   // true for the build that must make every item
ui.find_all()                                // every match of the sweep: rects in the scope's content, whatever the scroll
ui.find_pending()                            // a needle not swept yet: find_count is not its answer
ui.find_refresh()                            // the text changed where nothing is built (a page read above the view): sweep again
```

A sweep waits for the needle to rest (`FIND_QUIET_MS`: typing is not held up) and comes again when what is built no longer
answers what it found: text that came in, a part unfolded, another width, no sooner than `FIND_SWEEP_GAP_MS` (`needs_frame`
asks for the frames until then). Between two, `find_matches` is what the last layout built, its indices those of the sweep:
`find_all` says where to scroll, and the match is lit once the view brought it in. A part folded away after the sweep is still
counted until the next one.

## Limits

- Text per colour stripe (below) only in the frame's own target, and only for the renderer's own text: Direct3D 11 with the atlas,
  WebGPU with Slug. The other two pairs stay grayscale.
- Color glyphs: on Windows 11 22H2 and later every format (COLR v0 and v1, bitmaps, SVG); from Windows 10 1607 no COLR v1
  paint trees (their v0 layers, else the outline). Text-color layers take the text's color. Off Windows: COLR v0 and v1 through the interpreter, CBDT from its PNG images (`src/font/cbdt.odin`); no sbix or SVG.
- No kerning or ligature across a space (words are shaped apart, as Blink does with its word cache).
- Horizontal text only.
- Before Windows 8.1 (no `IDWriteFactory2`): no system fallback, no color glyphs, ClearType analyses averaged to gray.
