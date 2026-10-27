# Attribution

The architecture of `ui`, `draw`, `font` and `render` (box tree with keyed persistence, size kinds and the layout passes,
signals, tag-based themes, the SDF rect shader, the frame loop) is a port to Odin of the corresponding layers of the
[RAD Debugger](https://github.com/EpicGamesExt/raddebugger). No C code is copied; the design and algorithms are.

RAD Debugger is MIT licensed:

    Copyright (c) Epic Games Tools

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

`ui/icons.ttf` (compiled into the exes) is the icon font from `raddebugger/data/`.

## Slug (text drawn from outlines)

`render/slug.wgsl` (and the HLSL naga writes from it) is derived from the reference shaders of the Slug algorithm by Eric Lengyel
(<https://github.com/EricLengyel/Slug>, commit `be3c13eb7d63f9e8aa5c583e42d92c374cb91d98`; the originals are kept,
with their licenses and SHA-256, in `font/slug_ref/`): the coverage function, the root solvers and the dynamic dilation
are his, adapted to this renderer's instances and transforms. The algorithm is described in "GPU-Centered Font
Rendering Directly from Glyph Outlines", Journal of Computer Graphics Techniques 6(2), 2017, and "A Decade of Slug"
(<https://terathon.com/blog/decade-slug.html>). The patent was dedicated to the public domain on 2026-03-17. The code
may be used freely for any purpose provided credit is given, as here. License (MIT, also available under Apache-2.0):

    Slug shader code Copyright (c) 2017 Eric Lengyel

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
    documentation files (the "Software"), to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
    permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of
    the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
    THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.

## Embedded fallback fonts

Compiled into the exes and used only when the Windows fonts (Segoe UI, Consolas) are missing, e.g. under Wine:

- `font/data/Roboto-Regular.ttf`: Roboto, font data copyright Google 2011, Apache License 2.0
  (`font/data/Roboto-LICENSE.txt`).
- `font/data/Inconsolata-Regular.ttf`: Inconsolata, copyright (c) 2006-2012 Raph Levien, copyright (c) 2011-2012
  Cyreal, SIL Open Font License 1.1 (`font/data/Inconsolata-OFL.txt`).

## Emoji (optional, `font.set_emoji_source`)

- Noto Color Emoji (COLR v1), copyright Google, SIL Open Font License 1.1 (`font/data/NotoColorEmoji-OFL.txt`), is not part of
  this repository: `tools\fetch_emoji.ps1` fetches it (Google Fonts' build, pinned by commit and SHA-256) for programs that
  ship it. The COLR interpreter itself reads any COLR font.
- `font/emoji_data.odin` is generated from Unicode's `emoji-data.txt` (Unicode 18.0.0, Unicode License v3,
  <https://www.unicode.org/license.txt>).
- The color glyph test fonts of `tests/color_glyphs/data` keep their own licenses (see `data/README.txt`).

## Native text backend (optional, `-define:FONT_BACKEND=native`)

`native/text` (`gt_text.lib`, linked statically; `font/backend_native.odin`) is the portable text backend used on
every platform in place of DirectWrite. It is built on, under their own licenses:

- [HarfRust](https://github.com/harfbuzz/harfrust) (`harfrust` 0.15.0), MIT, the shaper (a Rust port of HarfBuzz):
  OpenType features, kerning, ligatures, marks, Arabic joining, Indic reordering, mirroring.
- [Fontations](https://github.com/googlefonts/fontations) (`read-fonts` 0.46.0), MIT or Apache-2.0: reading faces,
  glyph metrics, outlines, coverage, variation axes and COLR / CPAL tables.
- [ICU4X](https://github.com/unicode-org/icu4x) (`icu_segmenter`, `icu_properties` 2.4.0), Unicode-3.0: UAX #14 line
  breaking with the Thai / Lao / Khmer / Myanmar dictionaries, and the bidi character property data.
- [unicode-bidi](https://github.com/servo/unicode-bidi) (`unicode-bidi` 0.3.18), MIT or Apache-2.0: the UAX #9
  bidirectional algorithm (embedding levels).
- [memmap2](https://github.com/RazrFalcon/memmap2-rs) (`memmap2` 0.9.8), MIT or Apache-2.0: memory-mapping font files.

Exact versions and SHA-256 are in `native/text/Cargo.lock` (the build runs `--locked`). See `docs/font-backend.md`.

## Accessibility adapter (optional, `-define:A11Y_ACCESSKIT=true`)

`native/a11y` (`gt_a11y.lib`, linked statically) is built on [AccessKit](https://github.com/AccessKit/accesskit)
(`accesskit` 0.25.2, `accesskit_consumer` 0.39.2, `accesskit_windows` 0.35.2), MIT or Apache-2.0, and its dependencies:
the [windows](https://github.com/microsoft/windows-rs) crates 0.62 (MIT or Apache-2.0), `hashbrown` and `uuid` (MIT or
Apache-2.0), `foldhash` (Zlib), and the build-time crates `syn`, `quote`, `proc-macro2`, `static_assertions` (MIT or
Apache-2.0) and `unicode-ident` ((MIT or Apache-2.0) and Unicode-3.0). Exact versions and SHA-256 in
`native/a11y/Cargo.lock`.

## WebGPU backend (optional, `-define:TOOLKIT_RENDER=wgpu`)

- [wgpu-native](https://github.com/gfx-rs/wgpu-native) (wgpu and naga), MIT or Apache-2.0, linked through Odin's `vendor:wgpu`; `wgpu_native.dll` ships with programs built with `WGPU_SHARED=true`.
- [DirectX Shader Compiler](https://github.com/microsoft/DirectXShaderCompiler) (`dxcompiler.dll`, `dxil.dll`), LLVM Release License (University of Illinois/NCSA), optional, next to the program.
