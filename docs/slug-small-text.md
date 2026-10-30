# Slug's small text

Slug draws a glyph's exact outline with a one-pixel box filter: sharp at any scale or transform, but small text has no
grid fitting and only grayscale antialiasing, so next to DirectWrite's hinted bitmaps it can look softer. Three settings
of `font.Settings` address it; each is off by default (0) and they combine.

| Setting | What it does | Cost |
| --- | --- | --- |
| `slug_hint_ppem` | Screen-aligned glyphs at most this many pixels per em use an outline hinted for their size: the native backend's light auto-hinter (skrifa), vertical only, so the baseline, the x-height and horizontal stems land on whole pixels while shapes and advances stay as designed. | One glyph per size (quarter pixels) instead of one per face; a hinting instance per face and size in the Rust library. Needs `-define:FONT_BACKEND=native` (DirectWrite's backend has no hinter: nothing happens). |
| `slug_darken` | Stem darkening: every edge moves outwards by this many pixels at 12 px per em and less, fading out linearly by 36. The side is the glyph's winding (`Slug_Glyph.orient`: TrueType clockwise, CFF counter-clockwise). | Nothing measurable: two additions per root in the shader. |
| `slug_supersample_ppem` | Glyphs at most this many pixels per em take four coverage samples on a rotated grid, each over its own half-pixel box, instead of one estimated from two rays. | Four times the fragment work of those glyphs. |

The darkening and the samples travel in `colors[1]` of the glyph's instance (x: signed pixels, y: 1 for four samples);
the shader takes `fwidth` once at the top of `ps_slug` and passes it to each `SlugRender` call.

## Comparing

`odin run tools/slugsmall -define:FONT_BACKEND=native -- -out build/slugsmall [-dpr 1.5] [-darken 0.15] [-hint 24] [-ss 20]`
renders an opencode-like dark interface and a light page (Segoe UI and Cascadia Mono, 11 to 16 px) with DirectWrite's
bitmaps and with Slug in seven combinations, stacked in one PNG per scene and scale, plus a 3x enlargement of the first
lines. Build the Rust library first (`tools\build_text.ps1`).

Mean difference per pixel from DirectWrite (/255, green channel), with the defaults above:

| | Slug | + darkening | + hinting | + both | + 4 samples | all |
| --- | --- | --- | --- | --- | --- | --- |
| dark interface, 100 % | 2.15 | 4.24 | 3.69 | 5.26 | 2.26 | 5.38 |
| dark interface, 150 % | 1.99 | 2.37 | 3.32 | 3.58 | 2.05 | 3.64 |
| light page, 100 % | 2.60 | 5.20 | 4.03 | 6.13 | 2.61 | 5.95 |
| light page, 150 % | 2.55 | 2.93 | 3.91 | 4.13 | 2.65 | 4.17 |

Closer to DirectWrite is not the same as sharper: the auto-hinter does not place lines where Segoe UI's own instructions
put them for DirectWrite, and darkening thickens on purpose. Judge by eye.
