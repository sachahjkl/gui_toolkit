# Image decoding

`image.decode` is the one decoder of picture files for every program: PNG, JPEG, WebP, BMP and GIF, the format read
from the first bytes (`image.file_format`), never from a name. A program keeps no decoder of its own: opencode native
drops its Rust `image` crate for it (ROADMAP, "One image decoder").

## Decisions

- **The decoders.** PNG is `gt:png`; JPEG and BMP are the Odin core's; WebP is libwebp, built into the program; GIF is
  `gt:gif` (`gif.decode`), pure Odin. GIF is the toolkit's own because the core has no GIF decoder and `gt:gif`
  already holds its LZW and its block format (the encoder); a native library for it was refused: one more library to
  ship on Windows, for 200 lines.
- **`decode` gives a GIF's first frame; `gif.Decoder` gives them all.** Most programs show a picture as a still
  texture: opencode native's thumbnails, its project icons, the clipboard. galerie plays animations, so the frames API
  came as planned: `gif.Decoder` with `next_frame` beside `decode`, the disposal methods decoded, `decode` its first
  call (one code path). The canvas is the decoder's and `next_frame` lends it: a player uploads it, a list of frames
  (`decode_frames`) copies it, within a byte budget (768 MiB) past which the frames so far are kept. The clock of an
  animation stays the program's: the toolkit gives frames and delays, not a player. `image.decode` stays one picture.
- **A later frame's damage ends the animation; the first frame's refuses the file.** A file whose third frame is cut
  plays its first two, as browsers do. A delay under 20 ms is 100 ms: browsers slow such files, and a GIF made for
  them expects it. A frame is clipped to the canvas, which the first frame fixes; its rows below the canvas are not
  decoded (interlaced ones are: their rows come out of order).
- **The first frame as a browser shows it.** The canvas is the logical screen, grown to the frame when the frame passes
  its edge (browsers do; files with a zero screen exist). What the frame does not cover is transparent, not the
  background colour: browsers ignore it. An index past the colour table is transparent black.
- **Damage is refused; a short stream is not.** Every read is checked against the end of the data: a file cut before
  its first frame's data ends gives `ok = false`, never a panic or a read past the data. A code stream that reaches its
  terminator before its end code and before it fills its frame keeps what came, the rest transparent: encoders that
  write such files exist and browsers show them. A code that names no string is damage.
- **A size limit before any allocation.** A GIF declares its sides (up to 65535 each, 16 GiB of RGBA) before its
  pixels. `gif.MAX_DECODE_PIXELS` (8192 x 8192, 256 MiB) refuses a larger canvas, and a larger frame, before it is
  allocated: a hostile file of a few bytes must not take the memory of the program. Every format does the same through
  `image.file_dimensions`: the header's size is checked against `Decode_Options.max_pixels` and `max_bytes` before
  a decoder runs. A GIF's size is its canvas (`gif.canvas_size`: the screen grown to the first frame), not its screen:
  a screen of one pixel with a frame of 8192 x 8192 passed `max_pixels` and then the gate.
- **The orientation on request, in `decode`.** A phone stores a photo lying and says in its EXIF how it was held;
  classeur's thumbnails showed them sideways. `Decode_Options.orient` applies it (`image.orient`, `exif.orientation`
  with no allocation), after a scaled decode so the turn moves the smaller picture. It is an option, not the default:
  an editor that writes the file back (cliche, galerie's lossless turn) needs the pixels as stored. The thumbnails and
  the picture cache ask for it, as browsers show a photo.
- **The core's cap stays a define.** `core:image`'s PNG, JPEG and BMP decoders refuse more than `MAX_DIMENSIONS` (8192
  x 8192) whatever the caller says; it is a `#config`, so a program raises it with `-define:MAX_DIMENSIONS=n` in
  `toolbox.Project.defines` (every odin command of the program gets them). `DECODE_MAX_PIXELS` is that value, so the
  toolkit's default and the core's never disagree. Refused: a copy of the core's decoders without the cap.
- **The gate: a process's byte budget for large decodes.** A cache's decoders, a viewer's and the chores decode at
  once; four 200-megapixel photos held together ended the process. Each decode acquires the bytes it will hold
  (`decode_bytes`: the RGBA, the core decoders' own picture before the copy, a progressive JPEG's coefficients of the
  whole picture, which both native decoders keep whatever the scale, and the copies of a turn) before it starts, and waits while the
  budget is taken. One gate for the process, because memory is the process's; a gate of its own in the options for a
  test or a program that splits its budget. A decode under 4 MiB passes freely: a thumbnail never waits behind a
  giant. One decode past the whole budget is admitted alone when nothing is held, so it is slow, never stuck. Refused:
  a count of decodes (a thumbnail and a giant are not the same weight); refusing what does not fit now (the caller
  would retry in a loop). Not fair: a large decode can wait behind a stream of medium ones; no program has shown it.
- **Fast JPEG: zune-jpeg, and jpeg-decoder for scaled decodes.** `core:image/jpeg` takes 356 ms for 24 MP at
  `-o:speed`; a viewer's next photo must come sooner. In the native library (`native/jpeg`, `IMAGE_JPEG`): zune-jpeg
  0.5.15 (MIT, Apache-2.0 or Zlib; pure Rust with SIMD) decodes the whole picture in 138 ms. zune-jpeg has no scaled
  decode (its issue 103 is open), so jpeg-decoder 0.3.2 (MIT or Apache-2.0, image-rs's), whose scaled IDCT makes a
  block of 8 x 8 coefficients 4 x 4, 2 x 2 or one pixel, decodes 1/2, 1/4, 1/8 in 89, 79, 78 ms and never makes the
  96 MB of the whole picture. The entropy decoding is most of the time at 1/8; only skipping it (a progressive file's
  first scan) would go lower. A CMYK or YCCK file (Photoshop's, a print shop's) is jpeg-decoder's at every scale:
  zune-jpeg 0.5.15 gets its colours wrong (a 1024 x 670 CMYK tiger: mean 113, 126, 88 against ImageMagick's 96, 136,
  47; jpeg-decoder 94, 134, 46). Refused: libjpeg-turbo (C and assembly: a C compiler and NASM in every build, on Windows
  too), the zgx-zune-jpeg fork with a scaled IDCT (a month old, one publisher, 246 downloads when it was looked at),
  zune-jpeg whole then a resize for a thumbnail (138 ms plus a pass, and the 96 MB held). The calls are
  `gt_jpeg_size` and `gt_jpeg_decode_rgba` into the caller's buffer: the pixels are made once, in the caller's
  allocator. The limits were checked against `file_dimensions`' walk to the first frame header, not the decoder's
  own parse: a size from `gt_jpeg_size` other than that one (a crafted file the two walks read apart) is refused
  before the buffer is made. Both decoders refuse a second frame header, so a file with two cannot pass.
- **The camera's own thumbnail at once.** A camera embeds a small JPEG (often 160 x 120) in IFD1; `exif.thumbnail`
  finds it with no allocation, so a viewer shows it before the picture decodes. It is not used for a thumbnail of the
  file manager: its ratio is often 4:3 with black bands for a 16:9 photo.
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
