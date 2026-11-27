# exif: a camera's metadata

`import exif "gt:exif"`. The metadata a camera writes in a picture (EXIF: a TIFF structure of tagged values), read
from a JPEG's APP1 segment, a PNG's `eXIf` chunk or a WebP's `EXIF` chunk. Pure Odin, any target, no allocation but
the strings of `read`. A damaged or crafted block reads as none: every read is bounded by the block's bytes. The
intent: [src/md/features/exif.md](../src/md/features/exif.md).

```odin
info := exif.read(file)                    // the file's bytes; Info's strings in the allocator
defer exif.destroy(&info)
if info.found { show(info.make, info.model, exif.exposure_words(info.exposure)) }

o := exif.orientation(file)                // 1 to 8, 0: none said; no allocation
small := exif.thumbnail(file)              // the camera's own small JPEG, a slice of file (nil: none)
```

## Reading

| Call | What it gives |
|---|---|
| `read(data, allocator) -> Info` | the metadata of a JPEG, PNG or WebP file (by its first bytes); `Info.found` false when it has none |
| `read_tiff(block, allocator) -> Info` | the same from a TIFF block (the bytes after `Exif\0\0`) |
| `destroy(&info, allocator)` | frees its strings |
| `tiff_of(data) -> []u8` | the TIFF block of a file, a slice of it (nil: none) |
| `orientation(data) -> int` | the orientation (1 to 8; 0: none said, shown as 1), with no allocation: what a decoder asks before it turns the pixels |
| `thumbnail(data) -> []u8` | the JPEG a camera embeds (IFD1, often 160 x 120): a slice of `data` that starts as a JPEG and lies inside the block, nil when there is none. Shown at once while the picture decodes; its orientation is the picture's |

`Info`: `orientation`, `make`, `model`, `lens`, `software`, `taken` (`"YYYY:MM:DD HH:MM:SS"` as written:
DateTimeOriginal, else DateTime), `artist`, `copyright`, `description`, `exposure` (a fraction of seconds,
`{1, 250}`), `f_number`, `iso`, `focal` and `focal_35` (millimetres), `bias` (stops), `flash` (-1: none said; bit 0:
it fired), `pixels` (the size the camera says), `gps` with `latitude` and `longitude` (degrees, south and west
negative) and `altitude` (metres). A field the file does not have is its zero value.

`exposure_words(e)`: the exposure as a photographer says it, "1/250 s" or "2.5 s".

## Orientation

`orientation_turn(o) -> Turn`: the mirror (left to right, first) and the quarters clockwise (after) that show the
stored picture as it was held. `turn_orientation(t)` is its inverse. `image.orient(img, o)` applies it to pixels, and
`image.decode` does with `Decode_Options.orient` ([image.md](image.md)).

## Writing the orientation

`set_orientation(data, o, allocator) -> (out, result)`: the JPEG with orientation `o` (1 to 8), its pixels never
touched (a lossless turn).

- `.Changed`: the value was there; its two bytes changed, the file keeps its length.
- `.Inserted`: the file had no metadata; a block with the orientation alone is put after its start (after JFIF's
  segment, which must stay first): 36 bytes more.
- `.Refused`: not a JPEG; metadata with no orientation in IFD0 (writing one would move every offset); an orientation
  of more than one value (its entry holds an offset); a header that does not reach the scan cleanly (it may hide a
  block: a second one is never inserted). `out` is nil.

## Tests

`tests/exif`: a camera's block read whole (make, orientation, exposure, f-number, ISO, date, GPS), from a JPEG, a PNG
and a WebP; the orientation written, inserted and changed, the file still decoded; the embedded thumbnail found,
none without IFD1, refused when its length passes the block; turns and orientations inverse; every cut of a block read
as none; a doubtful header never written; a fuzz test with a fixed seed (`EXIF_FUZZ_ROUNDS`, 4000) over damaged JPEGs,
TIFF blocks and thumbnails: no read outside the bytes, no write of another length than the result says.
