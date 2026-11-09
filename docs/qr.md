# qr: QR Codes

`import "gt:qr"` (or the relative path of the submodule). Pure Odin: no platform code, no C library, any target. It
encodes a text or bytes as a QR Code (ISO/IEC 18004, model 2). `ui.qr_code` draws one in a box.

```odin
code, err := qr.encode("https://example.org/pair/0123", .Medium)   // context.allocator
if err != .None { ... }                                            // Too_Long
defer qr.destroy(&code)
for y in 0 ..< code.size {
	for x in 0 ..< code.size { if qr.module(code, x, y) { ... } }  // true: a dark module
}
```

| Procedure | |
|---|---|
| `encode(text, ecc = .Medium, allocator) -> (Code, Error)` | `text` at the smallest version (1 to 40) that holds it. The mode is numeric if the text is all digits, alphanumeric if it is all in `0-9 A-Z space $%*+-./:`, else bytes (the text's UTF-8). |
| `encode_bytes(data, ecc = .Medium, allocator) -> (Code, Error)` | `data` in byte mode, at the smallest version that holds it. |
| `module(code, x, y) -> bool` | the module at column `x`, row `y`: true is dark. Outside the symbol (the quiet zone) it is false. |
| `destroy(&code, allocator)` | frees `code.modules`. |

`Code` is `{size, version, ecc, mask, modules}`: `size` is `version * 4 + 17` (21 to 177), `modules` is `size * size`
values, row-major, true for dark. The symbol does not include the quiet zone: a reader needs `QUIET_ZONE` (4) light
modules around it.

## Levels and limits

`Ecc` is `.Low`, `.Medium`, `.Quartile` or `.High`: the symbol can lose about 7, 15, 25 or 30 % of its codewords and
still read. The level stays the one asked: `encode` does not raise it when the version has room left.

| At version 40 | `.Low` | `.Medium` | `.Quartile` | `.High` |
|---|---|---|---|---|
| bytes | 2953 | 2331 | 1663 | 1273 |
| digits | 7089 | 5596 | 3993 | 3057 |
| alphanumeric | 4296 | 3391 | 2420 | 1852 |

A longer input returns `.Too_Long` and an empty `Code`. One mode covers the whole text: a text that mixes modes is
encoded as bytes (no segment optimisation), and there is no Kanji mode and no ECI. A URL of 98 characters takes
version 6 at `.Medium` (41 x 41 modules).

## The algorithm

It follows [Project Nayuki's QR Code generator](https://www.nayuki.io/page/qr-code-generator-library): the data bits,
the terminator and the pad bytes; Reed–Solomon codewords over GF(2^8) (polynomial 0x11D) for each block; the blocks
interleaved; the function patterns (finders, timing, alignment, format and version information); the data in the zigzag
of two-column strips; each of the 8 masks scored by the standard penalty (runs, 2 x 2 blocks, finder-like patterns, the
balance of dark modules), and the lowest one kept. For one text and level, the matrix is the one Nayuki's `encode_segments`
gives with `boostecl = False`.

## ui.qr_code

```odin
ui.qr_code("###pair", url, math.round(160 * ui.scale()))   // a square of 160 logical pixels
```

`qr_code(id, text, size, ecc = .Medium) -> Signal` builds a square box of `size` device pixels (as `px`; a `next` before
it can place it or change its size). It draws:

- a white square on the whole box, then black modules, whatever the theme: a scanner needs dark on light;
- the quiet zone of 4 modules, inside the box;
- each module as a whole number of device pixels: the most that fit the box's shorter side (at least 1), the code centred
  on a whole pixel. If one pixel a module does not fit, the box clips the code.

The box keeps its code between builds (`State.qr_codes`, by the box's key): a build with the same text and level does
not encode again, and a box that is not built drops its code at the end of the build. A text too long for version 40
draws the white square alone. Partial redraw needs nothing more: the modules are in the custom draw's digest.

To a screen reader it is an image (`.Image`) named "QR code: " and the text.

Tests: `odin test src/qr -vet` (the matrices of Nayuki's reference for numeric, alphanumeric, UTF-8, empty and URL texts
at each level; the CRC-32 of its matrices at versions 11, 32 and 40; the version at each version's capacity and one
character over it, for each mode and level; `.Too_Long`), and `tests/scenarios` (`qr_code_test.odin`: every pixel of
the symbol and of its quiet zone black or white as its module says, on a dark theme; a new text through partial redraw;
the name a screen reader reads).
