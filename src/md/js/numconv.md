# Numbers and strings (`src/js/numconv`)

`src/js/numconv` turns a `float64` into the string a script sees (`String(x)`, `Number.prototype.toString`, `toFixed`,
`toExponential`, `toPrecision`) and parses a string back into a `float64` (`Number(s)`, `parseFloat`, `parseInt`). It is
ported from QuickJS-ng's `dtoa.c` (Fabrice Bellard, MIT) and gives **the same bytes as QuickJS for every finite f64 and
every radix 2–36**.

## Bellard's algorithm, not Ryū or Grisu

The core (`dtoa.odin`) is Bellard's bignum algorithm, not a Ryū or Grisu rewrite, so that the *shortest round-tripping*
decimal is chosen the same way, including the tie-breaking that decides which of two short decimals wins for a value
exactly between them. Refused: a faster shortest-digits algorithm, which picks another decimal in those ties and makes
the engine's output differ from QuickJS's. `atod` is the correctly rounded parse (the same bignum, run the other way), so
`parse_float` rounds to nearest, ties to even, in every base.

## No allocation

The string producers write into a caller's buffer and return the length; the parsers read a string. The bignum scratch
the algorithm needs lives in fixed stack arrays (what QuickJS kept in `JSDTOATempMem`/`JSATODTempMem`). So the package
builds for `windows_amd64`, `linux_amd64` **and** `freestanding_wasm32` with no allocator and no system call.
`MAX_STR_LEN` is always large enough; `dtoa_max_len(d, radix, n_digits, format, exp_mode) + 1` is the exact size one
call needs.

## The files

- `itoa.odin`: integer to ASCII (`u32toa`, `i64toa_radix`, …), for the small-integer fast paths.
- `dtoa.odin`: the `Mpb` stack bignum, the power and log tables, `dtoa` (the exact equivalent of `js_dtoa`) and `atod`
  (`js_atod`), with Odin idioms where they are natural (slices and bit sets for the flags, `transmute` for the bit casts,
  `intrinsics.count_leading_zeros` for `clz`).
- `numconv.odin`: the ECMAScript surface, with full-Unicode white space skipping for `Number()`, `parseFloat` and
  `parseInt`.

## How we know it matches QuickJS

A differential judge (kept out of the tree) compiled QuickJS's own `dtoa.c` with `zig cc` and compared both, byte for
byte, over:

- **2 000 000+ random f64** (uniform random bits), plus every structured edge case: ±0, ±∞, NaN, the smallest and largest
  subnormals and normals, 0.1, 1/3, π, e, 1e16…1e23, and thousands of small integers and half-integers;
- **toString in radix 2–36**, and **toFixed, toExponential and toPrecision** with every digit count 0–100;
- **atod** on the shortest string of each random f64 (round trip) and on 200 000 adversarial strings made of
  `0-9 e E . + - _` and space.

Result: **0 mismatches**. Speed is the C's: `f64_to_shortest` about 1.34 µs per call and `atod` about 0.5 µs per call,
the same as QuickJS built with `-O2`.

## The contract with the runtime

The runtime calls `f64_to_shortest` where QuickJS calls `js_dtoa(..., FORMAT_FREE)`, the `f64_to_*` helpers for the four
`Number.prototype` methods (the flag mapping is in those helpers), and `parse_number`, `parse_float` and `parse_int` for
the coercions. The integer fast paths (`i32_to_string`, `i64_to_string_radix`) give `ToString` of an integer Number
without the bignum.
