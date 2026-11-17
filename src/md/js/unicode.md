# Unicode data (`src/js/unicode`, package `ucd`)

An Odin port of QuickJS-ng's `libunicode`: the Unicode data that the regexp engines and the JavaScript lexer need.
Character-set intervals, case conversion and folding, the ECMAScript regexp `canonicalize`, the identifier and white
space predicates, the `\p{}` property, general-category and script sets, and the four normalization forms.

The package is named `ucd`, not `unicode`, so that it does not collide with `core:unicode`.

It compiles for `windows_amd64`, `linux_amd64` and `freestanding_wasm32`. Nothing on the runtime path makes a system call,
and every allocation goes through an allocator the caller gives (an arena frees a whole build at once). The only hosted
file is `settings.odin` (the preference registry needs a system); a `#+build` tag leaves it out of the freestanding build.

## Data: generated, pinned, never copied

The tables are **generated** from the authoritative Unicode Character Database, not copied from QuickJS's
`libunicode-table.h`:

- `tk gen_js_unicode` downloads the UCD files of a fixed release (17.0.0, the release QuickJS-ng 0.17 ships), checks
  each file's SHA-256, then runs `tools/js_unicode_gen`.
- The generator parses the UCD text and writes `tables_generated.odin`: sorted half-open interval runs for every
  property, category and script, simple and full case and fold tables, and the decomposition, combining-class and
  composition tables for normalization.
- `tables_generated.odin` is committed, so a build needs no network. To move to another release, change the pins and run
  the command again. The release shows as the `unicode.version` preference.
- The pin follows QuickJS-ng's release, so that the identifier, case-folding and property data agree with the reference
  engine the judges compare against ([regexp.md](regexp.md): a data skew showed as mismatches).
- Wren's URL parser reads the same pinned files, and two more of the table (`DerivedJoiningType.txt`,
  `DerivedBidiClass.txt`), for the rules of UTS #46 that Lexbor's IDNA leaves out. Those files are pinned here with the
  rest; their use is Wren's.

## Subtleties

- `Char_Range` is a set of code points as a sorted, non-overlapping list of half-open `[lo, hi)` intervals. It is the
  `v` flag's set-notation primitive and the shape every property lookup fills.
- `is_id_start` and `is_id_continue` return the raw Unicode property (as QuickJS's `lre_is_*`). The lexer's helpers
  (`js_is_ident_first`, `js_is_ident_next`) add `$`, `_`, ZWNJ and ZWJ.
- `canonicalize` is the ECMAScript regexp `i`-flag rule, which differs from Unicode's simple case folding outside unicode
  mode.
- Normalization is the standard algorithm: recursive canonical or compatibility decomposition, canonical ordering by
  combining class, then canonical composition for the C forms, with the algorithmic Hangul rules built in.

## Checking it

Wren's `wrentool engine rx-diff` compares this package with QuickJS-ng 0.17's `libunicode.c` over every code point and
thousands of random normalization inputs ([regexp.md](regexp.md) gives the results).
