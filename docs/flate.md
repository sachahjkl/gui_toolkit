# flate: DEFLATE, zlib and gzip as streams

`import "gui_toolkit/flate"` (or the relative path of the submodule). Pure Odin (`core:hash` only): no platform code,
no C library, any target. Odin's `core:compress` inflates whole buffers only; this package compresses as well, and
both directions take their input in chunks of any size (a network response, a `CompressionStream`).

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

- **Inflater**: puff-style canonical Huffman decoding, one block at a time from the bit where it starts. A block whose
  input has not all arrived is decoded again from its start with the next chunk (its partial output is dropped), so a
  push never waits for more than one block's input, and the state between pushes is only the unread input and the last
  32 KiB of output. Cost: a block arriving in many small chunks is decoded once per chunk. With chunks of a few KiB
  (network reads) this is negligible; feeding a large stream **byte by byte** is quadratic in the size of a block
  (blocks are typically 16 to 100 KiB compressed). About 150 MB/s of output on text (`-o:speed`).
- **Deflater**: LZ77 over a 32 KiB window kept across pushes (hash chains of 64 candidates, greedy: no lazy matching),
  blocks of at most `BLOCK_SYMBOLS` (16 Ki) symbols. Each block is written in the cheapest of the three types, by exact
  bit count: stored (incompressible data grows by 5 bytes per 64 KiB), fixed codes, or **dynamic Huffman codes** built
  for the block (length-limited to 15 bits, code lengths run-length coded). On text: about 17 % smaller than fixed
  codes only (`CHANGELOG.md`, 122 KB: 48.3 KB against 58.2 KB) for 20 % more time (5 ms); zlib's level 6 is a few
  percent smaller still (lazy matching). No compression levels, no preset dictionary, no `SYNC_FLUSH`: a push's last
  bits (under a byte) wait for the next push or `deflate_finish`.
- Positions are kept in `i32`: one Deflater compresses at most 2 GiB.
- Allocations: `inflater_init` / `deflater_init` take an allocator (default `context.allocator`) for their buffers; an
  inflate push also uses `context.temp_allocator` for the block being decoded.

Tests: `odin test tests/flate -vet` (a .NET gzip with dynamic codes in chunks of 1, 7 and 100 bytes, cut, corrupted and
followed by junk; round trips of every format in chunks; dynamic codes checked by `core:compress/zlib` too; stored
blocks for noise; the output bound).
