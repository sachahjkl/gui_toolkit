# Locks

Every mutex of the toolkit (tests and tools aside): what it guards, who takes it, how often, for how long. Only the font
package takes locks on a path that runs per glyph or per word; the others are taken per event, per frame at most, or once.
A lock is replaced only when a measure shows a win: a shared (reader) lock lost to the mutex it replaced where it was
held for a few nanoseconds per glyph, and won where a whole run of glyphs or a word's copy is read under it.

## The hot ones: the font package

| Lock | Guards | Taken by | Rate | Held for |
|---|---|---|---|---|
| `Word_Shard.mu` (`font/shape.odin`, 64 shards, `RW_Mutex`) | the shaped words of one shard (two generations) | layout threads (`measure`), any thread that shapes (`shape`: paint, carets, hit tests) | per word not in the thread's own width cache (words over 30 bytes, or pushed out of it), per word shaped | **shared**: a map lookup, a string compare, the copy of the word's glyphs (`shape`); **alone**: a word found in the old generation goes back to the current one, a word added, a clear |
| `Atlas.mu` (`font/raster.odin`, `RW_Mutex`) | glyph bitmaps, atlas pages, the Slug store (`slug_cache.odin`), the atlas clock and its users | threads that draw (`draw.glyph_run`), the color glyph thread (`color_async.odin`), the COLR interpreter (`colr_glyph.odin`, around its drawing) | **shared once per run** (`glyph_images`, `slug_glyphs`); alone per glyph made, per page synced (`atlas_sync_page`, `slug_sync_page`), per frame (`atlas_begin_frame`, `atlas_end_frame`) | shared: a map lookup per glyph; alone: a rasterization (DirectWrite, Direct2D: up to milliseconds for a color glyph drawn in the drawing thread) |
| `State.mu` (`font/font.odin`) | the font slots' writes, the shared-face keys | the interface thread (loading, cascades), shaping threads on a word miss that needs the system fallback (Windows: per fallback span; elsewhere per character no face has) | rare once the words are cached | a map lookup or insert; `unload` scans the keys and releases the font |
| `Color_Queue.mu` (`font/color_async.odin`) | the color glyph jobs, the worker's state | drawing threads (under the atlas lock: order atlas then queue), the color glyph thread | per color glyph queued (an atlas miss) | an append or a removal; the drawing is outside |
| `Color_Raster.mu` (`font/color.odin`) | the one Direct2D / WARP context | the color glyph thread, or a drawing thread (synchronous color glyphs, inside the atlas lock) | per color glyph drawn by Direct2D | a Direct2D draw and readback: milliseconds |
| `Face_Colr.mu` (`font/colr_glyph.odin`, one per COLR face) | the face's outline cache | whoever draws a COLR glyph | per COLR glyph drawn, per outline it needs | a map lookup or insert; a flush of the cache when it is over budget |
| `Emoji_Source.mu` (`font/emoji.odin`) | the emoji font's source and its loading | shaping threads until the font is loaded (then an atomic load), the interface thread | once (a load), or per emoji while no source is set | the whole font load the first time |
| `memory_mu` (`font/com.odin`) | the fonts loaded from memory and their references | loads, derived faces, unloads, DirectWrite's own threads opening a stream | rare | a map change |
| `loader_mu` (`font/font_windows.odin`) | the registration of the memory font loader | `init`, `destroy` | once per state | a counter, the registration call |

## The others

| Lock | Guards | Taken by | Rate | Held for |
|---|---|---|---|---|
| `Wgpu_State.pipe_lock` (`render/wgpu_core.odin`) | a renderer's pipelines | its render thread, its pre-warming thread | per draw batch (a scan of a few entries) | a scan; a pipeline compile on a miss (startup) |
| `g_compile_lock` (`render/wgpu_core.odin`) | the shader compiler (DXC crashes when devices compile at once) | render and pre-warming threads of every renderer | per pipeline made: startup, a new format, an app shader | a compile: milliseconds to seconds |
| `readback_lock` (`render/readback.odin`) | the readback table | render threads, the map callback | per readback | a map change; buffer release |
| `preload.lock` (`render/device_preload.odin`) | the device made early | the starting thread, renderers' init | a few times per process | a thread join (the device creation) |
| `Server.lock` (`devtools/devtools.odin`) | the inbox and the connections | the accept and connection threads, the interface thread | twice per frame while devtools runs, per message | an append, a swap, a join of an ended thread |
| `Conn.write` (`devtools/server.odin`) | a connection's socket writes | the interface thread, the connection's thread, picture encoders | per message sent | a socket send (a screencast frame: a large one) |
| `Virtual_Machine.mutex` (`platform/virtual.odin`) | the virtual screen of the offscreen windows | `virtual_screen_set`, `display_info` of an offscreen window | per frame of an offscreen window | a copy of the screen's size and rate |
| `Clip_Store.mutex` (`platform/clipboard.odin`) | the process's clipboard contents | the interface thread; on Linux the Wayland / X11 transfer | per copy, paste or request | string copies; a PNG encode / decode; a pipe write (Wayland) |
| `Post_Queue.spill_lock` (`ui/post_queue.odin`) | calls that did not fit the lock-free ring | posting threads, the interface thread draining | only while the ring is full | an append, a chunk copied out |
| `owners_mu` (`instance/instance_linux.odin`) | the instance owners | the owner, its message pump | per pump | a scan of a short list |
| `Ports.lock` (`testkit/ports.odin`) | the test port block | test code | per port asked | an environment read, a map lookup |

These stay mutexes: taken rarely or held for work far longer than the lock.

## Measures

`odin run tools/text_bench -o:speed -- -threads` (a few seconds) times the font package's hot paths, warmed, with 1 to 8
threads doing the same work at once, as the threads that lay out and paint a page do; nanoseconds per operation as each
thread sees it (flat across a row: no contention). 16 logical cores, Windows 11, DirectWrite, Segoe UI 16 px; medians of
three runs. Before: one mutex per shard, one mutex per glyph.

| Path | Before: 1 / 2 / 4 / 8 threads | After |
|---|---|---|
| `measure`, short word (the thread's own cache) | 15.8 / 16.0 / 19.4 / 29.5 | 15.2 / 15.6 / 17.5 / 29.2 |
| `measure`, long word (shared cache) | 74.7 / 95.4 / 105.7 / 134.5 | 74.3 / 92.5 / 94.9 / 107.4 |
| `shape`, per word of a line | 47.0 / 78.7 / 170.3 / 441.8 | 41.2 / 73.5 / 129.1 / 193.6 |
| bitmap per glyph (`glyph_image` each; after: `glyph_images` per run) | 10.7 / 22.6 / 48.3 / 119.6 | 7.1 / 7.9 / 9.3 / 16.9 |
| Slug data per glyph (`slug_glyph` each; after: `slug_glyphs` per run) | 9.7 / 18.6 / 38.3 / 93.4 | 5.4 / 6.1 / 7.0 / 8.3 |
| `measure`, new word (a miss: shaped) | 3995 / 4258 / 4420 / 6162 | 3879 / 4043 / 4341 / 5448 |

What was tried and left:

- **The atlas's lock shared per glyph** (`glyph_image` looking up under a reader lock): 14 / 50 / 202 / 527 ns. A lookup
  holds the lock a few nanoseconds; a reader lock still writes its cache line twice per glyph, and eight threads doing
  that lose to eight threads queueing on a mutex. Shared once per run, the same lookups no longer meet.
- **The atlas's mutex taken once per run** (no reader lock): 7.2 / 14.0 / 40.9 / 91.0 ns. Fewer acquisitions, the same
  queue: the lookups of the threads still run one at a time.
- A thread's own front for the atlas or the shared word cache (a cache per thread, no lock on a hit) was not needed: the
  shared lock per run is flat to eight threads, and a hit of the shared word cache is mostly its hash and map lookup, which
  a second cache would only move.

`glyph_image` and `slug_glyph` (one glyph) stay for callers that have one; between builds of the same code they measure
10 to 17 ns alone and 115 to 205 ns with eight threads (where the threads queue, the timing of the queue decides).
`draw.glyph_run` looks up its whole run at once.
