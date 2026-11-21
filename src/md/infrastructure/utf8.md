# UTF-8 validation, sixteen bytes at a time

`gt:utf8` validates UTF-8 byte slices sixteen bytes at a time using portable `#simd[16]u8` and `base:intrinsics` only
(no `core:` imports), following John Keiser and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte"
(Software: Practice and Experience 51(5), 2021; arXiv:2010.03090), ported from modus (`work/utf8simd`).

## Why

Text from outside a program (loaded files, HTML/site templates, clipboard pastes, remote calls) is checked at the
boundary. A byte-by-byte decoder runs ~480 MiB/s on ASCII and ~340 MiB/s on mixed French/CJK text. The vector form
measured in modus (`-o:speed -microarch:x86-64`):
- ASCII, 1 MiB: **17 742 MiB/s** vs 480 MiB/s (37×)
- French and CJK, 1 MiB: **5 949 MiB/s** vs 341 MiB/s (17×)
- Random invalid bytes, 64 B: **4.0 ns** vs 4.6 ns (stops on the first bad 16-byte group)

## Decisions

- **Portable `#simd[16]u8` + `base:intrinsics` only, zero `core:` imports**: compiles to SSE2 on x86-64, NEON on ARM64,
  and WASM SIMD with one source file and no target suffix. Keeps parity with modus's freestanding `text_encoding`
  package so fixes and speedups flow both ways.
- **Comparisons instead of the paper's three 16-byte lookup tables**: on baseline x86-64 (SSE2, no `pshufb`), table
  lookups lower to 16 scalar loads (~560 MiB/s vs ~5 800 MiB/s for comparisons). On SSSE3+, lookups are only 4–7 %
  faster, which is not worth maintaining two vector paths.
- **Optional control-character rejection (`reject_controls := false`)**: RFC 3629 UTF-8 accepts C0/DEL/C1 controls
  (newlines, tabs, etc. in files and text fields). Passing `reject_controls = true` rejects `U+0000..U+001F`, `U+007F`,
  and `U+0080..U+009F` (`C2 80..9F`) in the same SIMD pass at zero cost when `false` (`#force_inline` with compile-time
  `$REJECT_CONTROLS`).
- **Scalar reference kept (`valid_scalar`)**: used as the oracle in deterministic fuzz tests (400 000 random inputs in
  both modes) and 3-byte group-boundary window tests (1-in-251 by default, all 2^24 with `-define:EXHAUSTIVE=true`).
- **Reads each byte once, never past the slice**: trailing bytes (< 16) are copied into a stack block padded with ASCII
  spaces (`' '`), which never complete an open multi-byte sequence and are not control characters.

## Refused

- **Importing `simdutf` (C++)**: pulls in transcoders and base64 the toolkit does not need.
- **Per-architecture intrinsics or runtime CPU dispatch**: a second path to test for 4–7 % gain on SSSE3.
- **Delaying the error mask check until the end of the buffer**: an invalid external file fails on its first bad group.
