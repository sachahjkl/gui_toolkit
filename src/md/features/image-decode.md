# Image decoding

`image.decode` is the one decoder of picture files for every program: PNG, JPEG, WebP, BMP and GIF, the format read
from the first bytes (`image.file_format`), never from a name. A program keeps no decoder of its own: opencode native
drops its Rust `image` crate for it (ROADMAP, "One image decoder").

## Decisions

- **The decoders.** PNG is `gt:png`; JPEG and BMP are the Odin core's; WebP is libwebp, built into the program; GIF is
  `gt:gif` (`gif.decode`), pure Odin. GIF is the toolkit's own because the core has no GIF decoder and `gt:gif`
  already holds its LZW and its block format (the encoder); a native library for it was refused: one more library to
  ship on Windows, for 200 lines.
- **A GIF's first frame only, no frames API.** Every program shows a picture as a still texture: opencode native's
  thumbnails, its viewer, its project icons, the clipboard. Its Rust crate (`image::load_from_memory`) also gave the
  first frame. A frames API would bring the state machine of an animation (disposal methods 1 to 3, the canvas kept
  between frames, the delays, a clock in the interface) with no program to show it. When a program plays a GIF, its
  API is `gif.Decoder` with `next_frame`, beside `decode`; the disposal methods are then decoded, and `decode` becomes
  its first call.
- **The first frame as a browser shows it.** The canvas is the logical screen, grown to the frame when the frame passes
  its edge (browsers do; files with a zero screen exist). What the frame does not cover is transparent, not the
  background colour: browsers ignore it. An index past the colour table is transparent black.
- **Damage is refused; a short stream is not.** Every read is checked against the end of the data: a file cut before
  its first frame's data ends gives `ok = false`, never a panic or a read past the data. A code stream that reaches its
  terminator before its end code and before it fills its frame keeps what came, the rest transparent: encoders that
  write such files exist and browsers show them. A code that names no string is damage.
- **A size limit before any allocation.** A GIF declares its sides (up to 65535 each, 16 GiB of RGBA) before its
  pixels. `gif.MAX_DECODE_PIXELS` (8192 x 8192, 256 MiB) refuses a larger canvas before it is allocated: a hostile
  file of a few bytes must not take the memory of the program.
- **What a caller does after.** Scaling to the size shown is `image.resize` (opencode native: `.Bilinear`, the crate's
  `Triangle`); base64 and data URLs are `core:encoding/base64` in the program. `decode` stays one job: bytes in, RGBA8
  out.

## Subtle points

- The LZW decoder writes each string from its last index to its first along its chain of prefixes. A prefix is always a
  smaller code, so the walk ends; the code equal to the next free one is the string being defined (the previous string
  and its own first index). The width grows when the next free code reaches `1 << width`, below 12 bits; at 4096 codes
  the table stops growing until a clear code, as the encoder expects (`src/gif/lzw.odin`).
- The decoder stops reading as soon as its frame is full: the end code, the terminator and the trailer are not needed.
  A file cut after its last pixel's code reads.
- WebP is libwebp, built into the program on every system: a program is standalone, with no DLL beside it and no
  system library to find. `native/webp` builds libwebp's and sharpyuv's C sources with the target's compiler
  (libwebp-sys, pinned by Cargo.lock), as the part `webp` of the one static native library `gt_native`. A program asks
  for it with `toolbox.Feature.Webp`: the part in `tk build_native` and `-define:IMAGE_WEBP=true`. Without the define,
  `gt:image` links nothing and `webp_available` is false: a program that does not write WebP does not pay for libwebp.
  Its calls are `gt_webp_*`, never libwebp's names: another libwebp linked into the same program never clashes with
  them. Refused: Google's prebuilt archive (its static `libwebp.lib` calls `SharpYuv*`, and `libsharpyuv.lib` is not in
  it); loading at run time (a DLL beside the program on Windows, the system's libwebp on Linux: one more file to ship,
  and a program that says WebP is not available on a system without it); and a pure Odin WebP codec (libwebp's lossy
  encoder is the work of years). The DLL existed because programs on Windows did not build the toolkit's Rust
  libraries; since every program links `gt_native`, that reason is gone.
