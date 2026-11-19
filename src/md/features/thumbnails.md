# Thumbnails: intent

What a program sees and the API are in [docs/file-browser.md](../../../docs/file-browser.md) (section "Thumbnails").
This file keeps the reasons. The cards of a table's grid ([view-modes.md](view-modes.md)) show a picture of each
file: classeur made them first (its `thumbs.odin`); the toolkit's file browser and classeur now share one way.

## Decisions

- **A thumbnail is a call of the source** (`File_Source.thumbnail`, answered by `file_reply_thumbnail` with RGBA
  pixels). A server's source makes its pictures where the files are and sends small pixels; the browser does not read
  a whole photo over the network to shrink it. The answer is pixels, not a file: the source chooses how it makes them
  (a decoder, the system's cache, a server's own thumbnails). A source without the call: the cards show the kind's
  icon.
- **A thumbnail's answer goes to the browser's cache whatever the dialog** (no serial check, unlike the other
  replies). A thumbnail of a file is good for any dialog that shows the file; the ticket finds its entry, or nothing
  (dropped). A source answers every ask, a failure too (`file_reply_failed` with the reply): an ask without an answer
  holds one of the cache's slots.
- **The local source decodes what `gt:image` reads, else asks the system.** PNG, JPEG, BMP, WebP and a GIF's first
  frame are decoded on the chores and reduced (a box filter: each pixel the mean of what it covers, the fastest
  reduction and good enough at a card's size). A picture larger than `FILE_THUMB_CACHED_BYTES` is read from the
  system's cache first (`desktop.thumbnail_cached`) and kept there once decoded (`desktop.thumbnail_store`): decoding
  it again costs more than reading the cached one. Another type, or a picture larger than `FILE_THUMB_DECODE_BYTES`,
  gets the system's thumbnail (`desktop.thumbnail`: its cache, else its thumbnailer). The key of a file's thumbnail is
  its path, its size and its date: a file changed gets a new one. A picture `gt:image` fails to decode (a WebP in a
  program built without `IMAGE_WEBP`, a damaged file) asks the system's thumbnailer too: listing WebP by the build
  was refused, a damaged file needs the same way out.
- **The local work is public: `file_thumbnail_make(path, side, system, allocator)`.** The local source calls it on the
  chores; a program with its own pool of workers (classeur) calls it there, so the rules above are written once.
  `system` false never reads nor writes the system's cache and never runs its thumbnailer: a test, or a program
  headless, leaves the person's cache alone. It does disk work: never on the interface's thread. It answers a
  `File_Thumbnail` with the picture's own size beside the pixels, so an inspector that shows that size decodes once;
  `file_thumbnail_decodes` is the extensions it decodes, so a program keeps no copy of the list.
- **`thumb_cache_clear` forgets what was made** (Ready and Failed): the cards shown ask again (a command "Clear
  thumbnails", a thumbnailer installed since). The asks waiting and in flight stay: an ask out holds one of the `asks`
  slots until its answer, so forgetting it would let more than `asks` run at once; its answer lands as any answer (its
  work started after the file was as it is now). The entries go at the cache's next `thumb_cache_get` or
  `thumb_cache_frame`, not at the call; when a card took an entry in the build of the call, at the first of a later
  build: the draw of this frame may still read it (the rule of the trim). Refused: destroy and init (it loses the asks
  in flight, and an answer then finds an entry asked after it).
- **`ui` imports `gt:desktop`** for that. `desktop` imports neither `ui` nor what imports it, so there is no cycle;
  its install code is not reached from the browser.
- **The cache is in `ui` (`Thumb_Cache`), not `gt:pictures`.** `gt:pictures` imports `ui` (its answers come through
  `ui.task`): `ui` cannot import it. Moving it into `ui` was refused: it takes encoded bytes and decodes them itself,
  by size classes, while a thumbnail comes from its source as pixels already at its size (a remote source's too).
  Giving `gt:pictures` a pixels input was refused too: its ask is a key and bytes at each frame, a source's answer is a
  reply that comes once. The two caches share their rules: textures made on the interface's thread, a budget, what is
  shown never evicted, the last asked first.
- **Only the cards built ask** (`thumb_cache_get`), at each build that shows them. The asks wait in a stack and leave it
  newest first, at most `asks` at a time (`Thumb_Options.asks`): the cards on screen do not wait behind a folder
  scrolled past. A waiting ask whose card was not built for `THUMB_STALE_FRAMES` builds is dropped when its turn comes:
  it is asked again if its card comes back. The test is on the interface's thread, on the cache's own frame count:
  no counter shared with a worker, and a remote source gets the same rule.
- **The budget is a count and bytes** (`most_count`, `most_bytes`). Over either, `thumb_cache_frame` drops the entries
  used least lately down to three quarters of the limits (one sort per crossing, not per frame), never one asked in
  this build nor in the last `THUMB_KEEP_FRAMES`, never one asked and not answered.
- **A texture is made at its first draw.** The build has no renderer; the draw callback has it (as the preview's
  picture). The pixels go once the texture is made. A thumbnail drawn is fitted in its box, centred, never larger than
  it is.
- **The cache outlives the dialog.** A thumbnail closed with a dialog would be made again at the next one; the budget
  bounds what it holds meanwhile. A draw may still read an entry in the frame a dialog closes: the cache frees entries
  only in its own `thumb_cache_frame`, after the build that used them.

## Refused

- A decode on the interface's thread, or a texture made on a worker (the renderer is not shared with the workers).
- A thumbnail per ask without a key: two cards of one file, or a grid and its preview, share one.
- A pool of threads for thumbnails: the chores are the toolkit's; `asks` bounds what the thumbnails take of them.

## Subtle points

- The system's thumbnailer can take seconds (a long video): `asks` keeps the chores free for the folder's readings.
- An entry asked and evicted cannot be: an ask in flight holds its entry until its answer.
- A file renamed is another key: its old thumbnail ages out.
