# Text backends (`font` package)

The `font` package shapes text, analyses it (scripts, bidi, line breaks) and reads faces (coverage, metrics, outlines)
through a **backend**, and finds the system's fonts through the **platform**. Everything else (cascades and
`unicode-range`, the word cache, clusters and carets, letter / word spacing, the glyph atlas, Slug, the COLR
interpreter, the emoji font) is the same code whatever the backend.

| Backend  | What it is                                                                 | Build                               |
|----------|----------------------------------------------------------------------------|-------------------------------------|
| `dwrite` | DirectWrite: `IDWriteTextAnalyzer` (GetGlyphs / GetGlyphPlacements, AnalyzeScript, AnalyzeBidi, AnalyzeLineBreakpoints), `IDWriteFontFace` | default (Windows) |
| `native` | Fontations (`read-fonts` font model: faces, cmap, metrics, outlines, variations, COLR / CPAL), HarfRust (shaping), ICU4X (`icu_segmenter` line breaks with dictionaries, `icu_properties` data for `unicode-bidi`) in a static Rust library `native/text` | `-define:FONT_BACKEND=native` |

`-define:FONT_BACKEND=native` links `build/text/gt_text.lib` (built by `tools/build_text.ps1`) and makes `native` the
default; `Settings.backend` still picks either one for a `State` (read by `init` only), which is how the
`text_backends` test and `tools/text_bench` compare them in one process. Without the define, asking for `native` gives
`dwrite`. `font.backend(s)` tells which one a `State` uses; `font.backend_available(b)` whether this build has it.

## The interface (`font/backend.odin`)

`Text_Backend` is a table of procedures, all callable from any thread at once:

| Procedure       | Does                                                                                             |
|-----------------|--------------------------------------------------------------------------------------------------|
| `start`, `stop` | per-`State` setup (the script item of ASCII text, a version check)                               |
| `face_open`, `face_close` | the backend's side of a face the platform made (native: opens the same file or bytes in Fontations) |
| `has_glyph`     | coverage of one character (the package caches the BMP answers per face)                          |
| `face_metrics`  | design metrics (`Face_Metrics`: upem, ascent, descent, line gap, x / cap height, underline, strike) |
| `glyph_box`     | advance and ink box of a glyph (design units)                                                   |
| `scripts`       | script runs of a word (`Script_Item`: UTF-16 range, ISO 15924 tag, the backend's own data)       |
| `shape`         | one run (one face, one script, one direction, OpenType features) to glyphs (visual order) and clusters (logical order) |
| `bidi`          | UAX #9 levels per byte of a paragraph                                                            |
| `line_breaks`   | UAX #14 opportunities (byte offsets, mandatory or not)                                          |
| `outline`       | glyph outlines for Slug (`Outline_Provider`)                                                    |

`System_Fonts` is the platform's: `fallback` (faces for characters no cascade entry has) and `families` (installed
families, `font.system_families`). On Windows it is DirectWrite whatever the backend (`IDWriteFontFallback`,
the system collection); elsewhere it is a stub (`system_other.odin`, TODO fontconfig / CoreText).

Faces are always opened by the platform first: DirectWrite's face is what the atlas rasterizes (hinted coverage) and
Direct2D draws in color. The native backend then opens the same bytes (`native_source_windows.odin`: the memory of a
web font, or the path of a system font file through `IDWriteLocalFontFileLoader`, plus the face index and the axis
values of a variable instance). With `native`, text is shaped, measured, broken and outlined (Slug) by the library;
gray glyph bitmaps of the atlas and color glyphs still come from DirectWrite / Direct2D or the COLR interpreter.

## The native library (`native/text`)

C ABI, one call per run (`gt_shape`), per paragraph (`gt_bidi_levels`, `gt_line_breaks`, `gt_scripts`) or per glyph
(`gt_glyph_outline`, `gt_glyph_box`); a call whose buffer is too small returns the size it needs. Also
`gt_face_coverage` (code point ranges), `gt_face_table` (raw table bytes: COLR / CPAL for the package's own COLR
interpreter, the same on every platform), `gt_color_glyph` (COLR v0 / v1), `gt_palette` (CPAL colors). Every entry
point catches panics (`panic = "unwind"`): a font the library cannot read is a face without glyphs, not a dead program.
Faces are immutable and shared by threads; shape plans are cached per face (32), buffers per thread.

Built like Wren's `native/media`: exact versions and `Cargo.lock` (`--locked`), fat LTO, one codegen unit, the
library's `rust_eh_personality` renamed so it links next to other Rust static libraries. The toolkit builds it itself
(it already builds Rust: naga for the shaders), so any application of the toolkit gets the backend; Wren links it
through the toolkit's `build/text`.

## Known differences (see the bench report)

- DirectWrite simulates bold and oblique (`with_simulations`); Fontations does not: such faces shape with the
  regular face's advances under `native`.
- Script itemization: HarfBuzz-style (Common / Inherited characters join their neighbours), not DirectWrite's.
- Metrics follow DirectWrite's rule (typo when USE_TYPO_METRICS, else win ascent / descent with hhea's line gap
  adjusted); fonts whose tables disagree may differ by a unit.
- Faces DirectWrite opens through a loader other than files and this package's memory loader cannot be read natively
  (none today).

## Not done yet

- Linux / macOS: the package still uses DirectWrite types in `font.odin`, `raster.odin` and the color files; only the
  backend and system interfaces are platform-neutral. Next: a native rasterizer for the atlas, fontconfig / CoreText.
- Path B (HarfBuzz in C++ with SheenBidi and libunibreak) is not built; `tools/text_bench` is the harness to compare it
  with the same corpus when it is.
