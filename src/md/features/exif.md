# A camera's metadata (`gt:exif`)

The metadata a camera writes in a picture, read and, for one value, written. Moved from galerie (its
`src/exif`), where it was written to show a photo's details and turn it losslessly; classeur needs the orientation
for its thumbnails, and `image.decode` for `Decode_Options.orient`.

## Decisions

- **A package of its own, under `gt:image`, not in it.** `image` imports `exif` (to turn the pixels); `exif`
  imports nothing of the toolkit, so a tool that reads a photo's date links no decoder. It reads bytes, it never
  decodes pixels.
- **Read what a program shows, not every tag.** `Info` holds the fields a viewer's details show (camera, lens, date,
  exposure, GPS); a program that needs another tag reads the TIFF block itself (`tiff_of`). Refused: a tag table of the
  whole standard, maker notes.
- **Damage reads as none.** Every read goes through `u16_at`, `u32_at` and `value_at`, which answer 0 or -1 outside the
  block; an IFD of more than 1000 entries is not read; a tag written twice keeps the last value and frees the first's
  string. A fuzz test with a fixed seed holds it.
- **`orientation` apart from `read`.** A decoder asks it for every file: it must not allocate the strings `read` makes.
- **The embedded thumbnail is a slice, checked, not decoded.** IFD1's offset and length must lie inside the block and
  the bytes must start as a JPEG; the caller decodes it (`image.decode`). Its orientation is the picture's.
- **One write: the orientation, in place or inserted.** A lossless turn changes two bytes when the tag is there (one
  SHORT inside its entry). With no metadata, a block of one tag goes after JFIF's segment (which must stay first). Any
  other case is refused rather than rewritten: adding a tag to an existing IFD moves every offset after it, and a
  header that does not walk cleanly to the scan may hide a block that a second one would contradict.

## Subtle points

- `orientation_turn`: the mirror is applied first, then the quarters clockwise. 5 is the mirror then three quarters (a
  transpose), 7 the mirror then one quarter (the other diagonal). `image.orient` and the test of the eight
  orientations hold the table against pixels.
- A WebP's EXIF chunk sometimes keeps the JPEG's `Exif\0\0` before the TIFF header; it is skipped. A PNG's `eXIf` comes
  before `IDAT`; one after is not read (the specification's rule).
