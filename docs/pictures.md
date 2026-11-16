# pictures: a cache of decoded pictures

`import pictures "gt:pictures"`. The textures of picture files (PNG, JPEG, WebP, BMP, a GIF's first frame:
`image.decode`), kept under a byte budget. A program asks for a picture at each frame that shows it. The decode runs on
the chores; the texture is made on the interface's thread at the next build, and that frame shows it. The design is in
[src/md/features/picture-cache.md](../src/md/features/picture-cache.md).

```odin
c: pictures.Cache
pictures.cache_init(&c, &app.renderer, &app.state)       // Options{} : the defaults
defer pictures.cache_destroy(&c)

// each frame, in the build
pictures.frame(&c)
p := pictures.get(&c, key, bytes, 96 * ui.scale())       // a place of 96 logical pixels
switch {
case p == nil:              // no bytes and not known
case p.state == .Pending:   // draw a placeholder; the next frames show it
case p.state == .Ready:     draw.image(dc, p.texture, rect)   // p.size: its pixels
case p.state == .Failed:    ui.label(pictures.failure_words(p.why))
}
```

## Calls

| Call | What it does |
|---|---|
| `cache_init(c, renderer, state, o)` | a cache whose textures are `renderer`'s and whose decodes answer to `state` |
| `get(c, key, data, need_px, prepare = nil) -> ^Picture` | the picture of `key` for a place whose longest side is `need_px` frame pixels; 0: the whole picture, mipmapped. `prepare` (a `Prepare`): `data` is not the file yet (base64, a data URL), and it makes the file on the chores, before the decode; not ok: `Unknown_Format` |
| `frame(c)` | once a frame, before the asks: textures let go are destroyed, then the least recent go while over the budget |
| `forget(c, key)` | every size of `key` leaves the cache (its bytes changed, or it is gone) |
| `held_bytes(c)` | the bytes the textures hold |
| `class_side(need_px, most)` | the longest side decoded for a place (pure) |
| `failure_words(why)` | why a picture failed, in the person's language |
| `cache_destroy(c)` | every texture destroyed; decodes still out drop their answers |

- **The key is the caller's**: a hash of the bytes, a URL. The first ask of a size copies `data`; later asks may give
  `nil`.
- **Size classes**: 32, 64, 128 and 256 pixels, then multiples of 256, up to `max_side` and the renderer's largest
  texture. A picture larger than its class is scaled down to fit it; a smaller one keeps its size.
- **The pointer** `get` returns stays valid until `forget` of its key or its eviction by `frame`. Take it again at each
  frame; do not keep it.
- **What is shown stays.** A picture asked in the last `keep_frames` frames is never evicted, even over the budget.
  A picture that waits for its decode and is no longer asked when its turn comes is not decoded.

## Options

| Field | Default | What it is |
|---|---|---|
| `budget_bytes` | 96 MiB | the bytes of every texture together (a mipmapped one counts a third more) |
| `decoders` | 3 | decodes at a time; the last asked decodes first |
| `keep_frames` | 2 | a picture asked this many frames ago counts as shown |
| `max_side` | 2048 | the longest side decoded |

Call every procedure on the interface's thread of `state`. Nothing in a frame reads a file or decodes.
