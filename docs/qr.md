# qr: QR Codes

`import "gt:qr"` (or the relative path of the submodule). Pure Odin: no platform code, no C library, any target. It
encodes a text or bytes as a QR Code (ISO/IEC 18004, model 2), and reads one from a picture (see [Reading](#reading)).
`ui.qr_code` draws one in a box.

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

## Reading

```odin
d, err := qr.decode_rgba(pixels, width, height, stride)   // or decode_gray, decode_modules
if err != .None { ... }                                    // Not_Found, Too_Damaged, ...
defer qr.decoded_destroy(&d)
fmt.println(string(d.data))
```

| Procedure | |
|---|---|
| `decode_gray(gray, width, height, stride, allocator) -> (Decoded, Decode_Error)` | the first QR Code in a picture of 8-bit luminance (0 black). |
| `decode_rgba(pixels, width, height, stride, bgra = false, allocator) -> (Decoded, Decode_Error)` | the same from RGBA (BGRA when `bgra`) pixels; alpha is not read. |
| `decode_modules(modules, size, allocator) -> (Decoded, Decode_Error)` | a matrix of modules as `Code.modules` holds them, into its data. |
| `decoded_destroy(&d, allocator)` | frees `d.data`. |

`Decoded` is `{data, version, ecc, mask, errors}`: `data` is what the segments hold (a text's UTF-8 when `encode` wrote
it), `errors` the codewords the Reed–Solomon code corrected.

`Decode_Error`: `Not_Found` (no symbol in the picture), `Bad_Size`, `Bad_Format` (the format information is too
damaged), `Too_Damaged` (a block has more errors than its code corrects), `Bad_Data`, `Unsupported_Mode` (kanji).

How it reads a picture:

1. **Black and white.** One threshold for the picture (Otsu's method), else one per block of 8 pixels from the 5 x 5
   blocks around it; each also inverted, for light modules on a dark ground.
2. **The finder patterns.** Runs of dark, light, dark, light, dark in the ratios 1:1:3:1:1 along each row, checked
   down their column and again along their row; the ones seen on most rows are kept.
3. **The symbol.** Three patterns at the corners of a right isosceles triangle: the right angle is the top left, the
   turn says which other is the top right. Their distance in modules gives the size; past version 6 the version
   information read from the symbol corrects it.
4. **The modules**, read at their centres through the affine map the three patterns make, then decoded: the format
   information (the nearest of the 32 valid ones, both copies), the mask removed, the blocks taken apart and each
   corrected (Berlekamp–Massey, Chien search, Forney), the segments read (numeric, alphanumeric, bytes; ECI, FNC1 and
   structured append markers are skipped).

The map is affine: a picture of a screen (scaled by any factor, turned by quarter turns), not a photograph seen at an
angle (no perspective, no alignment pattern search). A mirrored symbol is not read. Of several symbols, one is read.

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

Tests: `odin test src/qr -vet` (reading: every mode and level and versions 1 to 40 read back from the encoder's
matrices; Reed–Solomon with random errors up to its reach; pictures at whole and fractional scales, turned, inverted,
among other shapes, in BGRA; a picture with no symbol. Writing: the matrices of Nayuki's reference for numeric, alphanumeric, UTF-8, empty and URL texts
at each level; the CRC-32 of its matrices at versions 11, 32 and 40; the version at each version's capacity and one
character over it, for each mode and level; `.Too_Long`), and `tests/scenarios` (`qr_code_test.odin`: every pixel of
the symbol and of its quiet zone black or white as its module says, on a dark theme; a new text through partial redraw;
the name a screen reader reads).
