# SIMD fuzzy matching and frecency

Two pieces ported from modus (`work/fuzzymatch`) into `gt:ui`:
1. **A portable SIMD vector fast path** (`src/ui/fuzzy_vectors.odin`) for `ui.fuzzy_score` (`fuzzy_score_folded`).
2. **A storage-independent frecency model** (`src/ui/frecency.odin`: `ui.Frecency`), matching modus's exact rules so
   both systems rank frequent and recent choices the same way.

## Vector fuzzy match

`ui.fuzzy_score_folded` uses fzf v1's two-pass tightest-window algorithm (forward to leftmost match end, backward to
latest start, then score). For pure-ASCII candidates up to 128 bytes and pure-ASCII needles up to 64 bytes (nearly
every command, filename, setting and symbol), `fuzzy_score_vectors` runs the exact same algorithm using `#simd[16]u8`
and `base:intrinsics`:
1. Load `h.low` in 16-byte blocks (at most 8 blocks, trailing block zero-padded on stack — never reads past the slice)
   and OR them to check bit 7 (`simd_extract_msbs`): any non-ASCII byte falls back immediately to `fuzzy_score_scalar`.
2. For each byte of `needle.want`, compute a 128-bit bitmask across all blocks with `simd_lanes_eq` + `simd_extract_msbs`
   and run the forward pass via `count_trailing_zeros`. Any missing letter rejects the candidate on the spot (frizbee's
   prefilter idea).
3. Run the backward pass via `count_leading_zeros` to recover the exact byte positions, then compute the exact same
   `FUZZY_SCORE_*` score and `Fuzzy_Range` runs as the scalar path.

Contract: **bit-exact identical score, ranges, and match boolean** to `fuzzy_score_scalar` for every input, verified by
a 200 000-input deterministic fuzz test in `tests/fuzzy`.

## The frecency model

Follows modus's `src/md/features/fuzzy_match.md` ("## The frecency model") verbatim so one model works with modus's
private palette store and `gui_toolkit`'s program/LMDB stores:
- **Key**: 64-bit FNV-1a hash of the name bytes (`0xCBF29CE484222325`, prime `0x100000001B3`), mapping 0 to 1.
- **Use**: up to `FRECENCY_NAMES_PER_USE` (16) distinct non-empty names per use; destructive actions do not count;
  empty use still decays.
- **Decay and saturation**: `W = 1024`, `D = 5`, `L = 32768`. Each use first decays every kept entry by
  `ceil(score / 32) = (score + 31) >> 5` (evicting entries that hit 0), then adds `W` to each used name (clamped to
  `L - 1`; halves in 22 uses, no clock read).
- **Capacity**: `FRECENCY_CAPACITY` (64) entries sorted by key (binary search in ≤ 6 steps). Full table evicts lowest
  score outside the current use, ties broken by lowest key.
- **Bonus**: `min(bit_length(score >> 7), 8)` — 0 for `< 128`, 4 after one use, 8 at `>= 16384`. Added only to matched
  names, strictly below every structural match bonus (`FUZZY_SCORE_CHAR = 16`, `FUZZY_SCORE_CAMEL_START = 14`,
  `FUZZY_SCORE_WORD_START = 18`, `FUZZY_SCORE_TEXT_START = 20`, `FUZZY_SCORE_ADJACENT = 24`).
- **Stored records (`frecency_encode` / `frecency_decode`)**: on decode, scores above `L - 1` clamp to `L - 1`, key 0
  or score 0 are dropped, entries are sorted and deduplicated; malformed data returns an empty table and `ok = false`.

## Refused

- **Smith–Waterman best alignment (fzf v2)**: O(M×N) matrix per candidate and changes existing palette rankings.
- **Clock-based decay**: depends on system clock jumps and makes tests non-deterministic; use-count decay keeps order
  across a week of power-off.
- **Replacing `ui.fuzzy_score`'s existing scoring weights**: keeping the toolkit's weights preserves every existing
  palette and menu ranking while gaining the 5–8× SIMD speedup.
