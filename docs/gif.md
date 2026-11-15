# gif

An animated GIF encoder (GIF89a) for screen recordings, and a decoder of a GIF's first frame. Pure Odin, any target.

```odin
import "gt:gif"

e: gif.Encoder
gif.begin(&e, width, height, loop_count = 0)        // 0: loops for ever
for frame in frames {
	gif.add_frame(&e, frame.bgra, frame.stride, delay_cs = 4)   // BGRA, straight alpha; delay in 1/100 s
}
data, ok := gif.end(&e)                               // the file, in the encoder's allocator
```

With a writer (`begin(..., write = proc(user, data) -> bool, user = ...)`), the bytes go to it as they are made and
`end` returns nil: a long recording is never held whole in memory.

## What makes it small

- **Only what changed.** Each frame after the first is the rectangle that differs from the frame before, its unchanged
  pixels transparent (disposal 1: the decoder keeps what is below). A still screen costs nothing, a moving cursor a few
  bytes.
- **An unchanged frame is not written.** Its delay is added to the frame before (up to 655.35 s, then one transparent
  pixel carries the rest).
- **Exact colours when they fit.** Screen content often has fewer than 256 colours in a changed rectangle: they are kept
  exactly.

## Encoder_Options

| Field | Default | What it does |
|---|---|---|
| `quantizer` | `.Median_Cut` | `.Median_Cut`: per frame, the exact colours when they fit, else Heckbert's median cut, in a local table. `.Fixed`: one global table (6 x 7 x 6 levels and 3 greys), the fastest. |
| `dither` | `false` | Ordered (Bayer 4 x 4) dithering of the colours the palette lacks. Off, text stays crisp. |
| `full_frames` | `false` | Every frame whole: no changed rectangle, no transparency, no merging of unchanged frames. |

## Decoding

```odin
rgba, width, height, ok := gif.decode(data)   // the first frame, RGBA8 with straight alpha, in the allocator
```

`decode` reads GIF87a and GIF89a: global and local colour tables, the transparent index, interlaced frames. The picture
is the logical screen (grown to the frame when the frame passes its edge), the first frame laid on it, the rest
transparent. Only the first frame: no program plays an animation (the reasons:
[src/md/features/image-decode.md](../src/md/features/image-decode.md)). A program reads any picture file with
`image.decode` ([image.md](image.md)), which calls this one for a GIF.

`ok` is false for no GIF, a file cut before its first frame's data ends, a damaged code stream, a frame with no colour
table, or a canvas past `gif.MAX_DECODE_PIXELS` (8192 x 8192), refused before it is allocated. A code stream that stops
before it fills its frame keeps what came, the rest transparent. The decoder never reads past its data.

## Tests

`tests/gif`: the encoder's files read back by a decoder of the test's own (every frame, as a browser shows it), and
`gif.decode` on files made by hand (one pixel, both tables, transparency, interlace at every height up to 16, a frame
off the screen's corner, a short stream), on the encoder's files pixel for pixel, and on damage: every cut of a file,
every byte of it changed, codes that name no string, bad code sizes, a screen past the limit.
