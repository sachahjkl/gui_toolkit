# BigInt (`src/js/bigint`)

`src/js/bigint` is the ECMAScript `BigInt` arithmetic, in Odin. The engine used to take it from QuickJS's C inside
WebAssembly. This package gives the same numeric results and reads as Odin, not as transcribed C.

Every operation allocates its result through `context.allocator`: the engine sets the realm's allocator and frees
results with `destroy`. No system call: it builds for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`.

## Representation

Sign and magnitude, little-endian `u32` limbs, always normalized: no leading zero limb, and zero is the empty magnitude
with `neg = false`. This is the natural Odin shape and keeps the arithmetic obvious.

The one place where the choice shows is the bitwise operators. ECMAScript defines `& | ^ ~` and `>>` as if a BigInt were
an infinite two's-complement integer. So those operations convert each operand to its two's-complement limb view over a
common width, apply the operation, and convert back (`bits.odin`).

## Algorithms

- Multiplication is schoolbook below about 40 limbs and **Karatsuba** above.
- Division is **Knuth's Algorithm D**, with a single-limb fast path.
- `shr` is arithmetic (`a >> n == floor(a / 2ⁿ)`): it sign-extends negatives.
- `to_f64` rounds to nearest, ties to even.
- String conversion packs as many base-R digits as fit in a `u32` before each large multiply or divide, so parsing or
  printing a very large number stays close to linear.

## How we know it is correct

No small C oracle exists for BigInt (the QuickJS version needs the whole engine), so a differential judge checks it two
ways over **12 000 000+ checks**:

1. **Exact agreement with native `i128`/`u128`** for operands in that range: add, sub, mul, div, rem, all the bit
   operations, shifts, `asIntN`/`asUintN`, and decimal output against `%d`, plus string round trips in every base 2–36.
2. **Algebraic identities** for large operands (up to several thousand bits, well into the Karatsuba path):
   `(a+b)-b == a`, `(a*b)/b == a`, `(a/b)*b + a%b == a` with `sign(rem) == sign(a)`, `to_string`/`from_string` round
   trips, `(a<<n)>>n == a`, `pow` against repeated multiplication, and `from_f64(to_f64(a)) == a` for integers exactly
   representable in f64.

Result: **0 failures.**

## The contract with the runtime

- Division by zero and a negative exponent are RangeErrors in ECMAScript. The runtime rejects them before it calls
  `div`, `rem` or `pow`. The package returns zero and does not trap, to stay allocation-safe.
- `BigInt(string)` strips the `0x`/`0o`/`0b` prefix and the separators, then calls `from_string`.
- `BigInt(number)` checks that the number is an integer, then calls `from_f64`.
- `Number(bigint)` calls `to_f64`; `toString(radix)` calls `to_string`.
