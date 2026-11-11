# flate: DEFLATE, zlib and gzip as streams

`import "gt:flate"` (or the relative path of the submodule). Pure Odin (`core:hash` only): no platform code,
no C library, any target. Both directions take their input in chunks of any size (a network response, a
`CompressionStream`), which Odin's `core:compress/deflate` does not: it compresses and inflates whole buffers (faster:
see [Against core:compress](#against-corecompress)).

| Format | Wrapping |
|---|---|
| `.Gzip` | RFC 1952: 10-byte header (FEXTRA, FNAME, FCOMMENT and FHCRC read and skipped), CRC-32 and size trailer |
| `.Zlib` | RFC 1950: 2-byte header (no preset dictionary), Adler-32 trailer |
| `.Raw` | RFC 1951 alone (HTTP's `Content-Encoding: deflate` as some servers send it, `deflate-raw`) |

## Whole buffers

```odin
packed := flate.deflate(.Gzip, data)                    // []u8, context.allocator
out, err := flate.inflate(.Gzip, packed, limit = 64 << 20)
if err != .None { ... }                                  // Bad_Data, Junk_After_End, Truncated, Too_Large
```

## Streams

```odin
z: flate.Inflater
flate.inflater_init(&z, .Gzip, limit = 0)               // limit: the most output one push may make (0: no bound)
defer flate.inflater_destroy(&z)
out := make([dynamic]u8)
for chunk in chunks {
	if err := flate.inflate_push(&z, chunk, &out); err != .None { /* stop */ }
	// `out` has everything the chunks so far allow
}
err := flate.inflate_finish(&z)                          // Truncated when the data had not ended

d: flate.Deflater
flate.deflater_init(&d, .Gzip)
defer flate.deflater_destroy(&d)
for chunk in chunks { flate.deflate_push(&d, chunk, &packed) }   // appends its blocks at once
flate.deflate_finish(&d, &packed)                        // the final block and the trailer
```

Errors: `Bad_Data` (a malformed header, block, code table, a distance before the start, a wrong checksum or size),
`Junk_After_End` (bytes after the trailer), `Truncated` (from `inflate_finish`: the stream did not end), `Too_Large`
(a push would pass `limit`: a decompression bomb).

## How it works, and its limits

- **Inflater**: puff-style canonical Huffman decoding. A block whose input has not all arrived resumes at its last complete
  symbol with the next chunk, and what it has decoded comes out as the input arrives, so feeding a stream in small chunks
  costs no second decoding. Nothing goes through the temporary allocator.
- **Deflater**: LZ77 over a 32 KiB window kept across pushes (hash chains of 64 candidates, greedy: no lazy matching),
  blocks of at most `BLOCK_SYMBOLS` (16 Ki) symbols. Each block is written in the cheapest of the three types, by exact
  bit count: stored (incompressible data grows by 5 bytes per 64 KiB), fixed codes, or **dynamic Huffman codes** built
  for the block (length-limited to 15 bits, code lengths run-length coded). On text: about 17 % smaller than fixed
  codes only (`CHANGELOG.md`, 122 KB: 48.3 KB against 58.2 KB) for 20 % more time (5 ms); zlib's level 6 is a few
  percent smaller still (lazy matching). No compression levels, no preset dictionary, no `SYNC_FLUSH`: a push's last
  bits (under a byte) wait for the next push or `deflate_finish`.
- Positions are kept in `i32`: one Deflater compresses at most 2 GiB.
- Allocations: `inflater_init` / `deflater_init` take an allocator (default `context.allocator`) for their buffers.

## Against core:compress

Odin dev-2026-11 rewrote `core:compress` (`core:compress/deflate`: Deflate at levels 1 to 10, a new Inflate). Measured
on 2026-11-03 (`-o:speed`, best of 5, one thread of a desktop x64; zlib streams; every output read back by both
decoders):

| Input | `flate.deflate` | core level 1 | core level 6 | core level 10 |
|---|---|---|---|---|
| a 1400x925 screenshot, Sub-filtered rows (5.2 MB) | 6.0 %, 74 ms | 6.9 %, 7.9 ms | 6.0 %, 15.6 ms | 5.9 %, 191 ms |
| a 1400x897 screenshot (5.0 MB) | 10.4 %, 83 ms | 11.8 %, 11.8 ms | 9.9 %, 29.8 ms | 9.7 %, 332 ms |
| `CHANGELOG.md` (208 KB) | 37.8 %, 9.1 ms | 40.2 %, 1.6 ms | 36.6 %, 3.8 ms | 36.4 %, 7.2 ms |
| an HTML page (123 KB) | 19.7 %, 5.8 ms | 24.4 %, 0.6 ms | 19.0 %, 2.8 ms | 17.7 %, 6.3 ms |
| a JavaScript file (106 KB) | 24.3 %, 2.9 ms | 27.3 %, 0.5 ms | 23.4 %, 1.3 ms | 22.9 %, 3.9 ms |
| Roboto-Regular.ttf (159 KB) | 48.8 %, 5.3 ms | 50.8 %, 1.2 ms | 48.7 %, 2.1 ms | 46.3 %, 5.7 ms |

Since 2026-11-12 `flate.deflate` compares the bytes of a match 16 at once (one SSE or NEON register), skips a candidate
that cannot be longer than the best one, and writes a block's symbols 8 bytes at once: on the same kind of machine the
two screenshots take 23 ms and 36 ms and `CHANGELOG.md` a third less, their output unchanged. `flate.inflate` reads a
code of up to 9 bits in one look in a table and copies a match in one piece: 560 to 680 MB/s on the two screenshots
(360 to 440 before), 370 MB/s on `CHANGELOG.md` (190 before).

Inflating the same streams (core level 6), output rate: `flate.inflate` 130 to 445 MB/s (`inflate_push` in 16 KiB
chunks the same), `core:compress/deflate` 400 to 1530 MB/s. A picture as `png.encode(.., .Fast)` makes it (Sub filter,
`deflate_runs`): 609 KB in 3.0 ms and 957 KB in 5.1 ms for the two screenshots; `core:image/png`'s `save_to_buffer`
at level 1 with the same filter 358 KB in 8.9 ms and 592 KB in 12.8 ms.

So a whole buffer is better compressed or inflated by `core:compress/deflate` (level 6: 2 to 5 times as fast as
`flate.deflate` for the same size or smaller). It stays here for what it lacks: streams in both directions (a chunk in,
what it allows out at once, the bound per push), which Wren's `CompressionStream` and `DecompressionStream` need, and
`deflate_runs` for pictures taken while a program runs (2.5 to 3.5 times as fast as core's level 1, for an output 1.6 to
1.7 times its size).

Tests: `odin test tests/flate -vet` (a .NET gzip with dynamic codes in chunks of 1, 7 and 100 bytes, cut, corrupted and
followed by junk; round trips of every format in chunks; dynamic codes checked by `core:compress/deflate` too, and
its streams at every level read here in chunks; stored blocks for noise; the output bound).
