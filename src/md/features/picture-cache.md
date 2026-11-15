# Picture cache

`gt:pictures` keeps the textures of picture files (PNG, JPEG, WebP, BMP, a GIF's first frame) under a byte budget. A
program asks for a picture each frame it shows it. The cache decodes it off the interface's thread and gives its texture
once it is ready. opencode native kept one for its images, and Wren one each for pages' images, favicons and system
icons; the toolkit's replaces them.

## Decisions

- **A key is the caller's.** A hash of the bytes, a URL, an origin: the cache does not hash. The bytes are copied at the
  first ask of a size, so the caller can give a slice it does not keep.
- **Size classes.** A place asks for the longest side it shows, in frame pixels. The cache decodes at the class of that
  side: powers of two from 32 up to 256, then multiples of 256, never more than `max_side` nor than the renderer's
  largest texture. Two places of nearly one size share one texture. A window resized by a few pixels does not decode
  again. A thumbnail decoded at its size is sharper than a large texture sampled down, and it holds far less memory.
- **The whole picture is another class.** `need_px` 0 asks for the picture at `max_side` with mipmaps: a viewer zooms
  it, so its texture is sampled at every scale.
- **The last asked first.** The decodes wait in a stack. A view that scrolled past a hundred pictures shows the last
  ones asked, so these decode first.
- **What is no longer shown is not decoded.** When its turn comes, a picture not asked in the last `keep_frames` frames
  leaves the stack and the cache. It is asked again if it shows again.
- **At most `decoders` decodes at a time.** On the chores (`ui.task`): a long list does not take every thread of the
  program.
- **Upload on the interface's thread.** The worker decodes and resizes; the texture is made when the answer arrives at
  the next build. The renderer is not shared with the workers.
- **The budget.** The bytes of every texture count (width × height × 4, a third more for mipmaps). Over the budget,
  `frame` drops the pictures shown longest ago. It never drops one asked in the last `keep_frames` frames, nor one that
  waits: what is on the screen stays, even over the budget.
- **Textures are destroyed between frames.** `forget` and eviction destroy a texture in `frame`, never during a build: a
  texture drawn in the frame being built stays valid until its draw ends.
- **A serial per ask.** A picture forgotten and asked again while its old decode runs gets a new serial. The old answer
  finds another serial and is dropped: the caller's new bytes win.
- **A failed picture stays failed.** It keeps its `why` and is not decoded again each frame. `forget` clears it.
- **The cache outlives no State.** The answers come back through `ui.task` to the State given. A cache destroyed while
  decodes run lets them end and drops their answers.

## Refused

- **A decode in the frame.** A photo takes tens of milliseconds to decode: the frame would stop.
- **One texture per place.** Every thumbnail of a long conversation at 2048 pixels held a gigabyte.
- **A cache per program.** Three copies with three sets of bugs (a find that decoded every image at once, textures
  that never left).
- **Pixels already decoded as input.** A system icon arrives as pixels; it does not need a decoder and stays with its
  owner for now.
