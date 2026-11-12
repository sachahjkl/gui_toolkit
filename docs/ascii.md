# ascii: the case of names and protocols

`import "gt:ascii"` (or the relative path of the submodule). Pure Odin, any target.

Only `A`-`Z` and `a`-`z` change case. The Kelvin sign U+212A and the long s U+017F stay what they are. Use these
procedures for names and protocols: HTTP header names, font family names, CSS keywords, file extensions, process names.
User text (a search, type-ahead) folds by Unicode with `strings.to_lower`; `tests/unicode_case` checks it
([testing.md](testing.md)).

| Procedure | Result |
|---|---|
| `lower(s)`, `upper(s)` | `s` in ASCII lower or upper case (`lower` returns `s` itself when nothing changes) |
| `lower_byte(c)`, `upper_byte(c)` | one byte |
| `equal_fold(a, b)` | the same text, case ignored |
| `has_prefix_fold(s, prefix)`, `contains_fold(hay, needle)` | the same tests, case ignored |
| `compare_fold(a, b)` | the order of two names: case ignored first, then the bytes. Less than 0 when `a` comes first, 0 when the bytes are the same. A prefix comes first |
| `lower_run(dst, s) -> int` | lowers the ASCII run at the start of `s` into `dst` and returns its length: it stops at the first byte >= 0x80 (where a Unicode fold takes over: `ui.fuzzy_text`) or at the end of the shorter of the two |
| `index_any_byte(s, set, below = 0, non_ascii = false) -> int` | the index of the first byte of `s` that is in `set`, below `below` (0x20: the control characters) or, with `non_ascii`, >= 0x80; -1 when none is |

`lower_run` and `index_any_byte` read 16 bytes at a time (one SSE2 or NEON register, `core:simd`), then one by one. A set
of more than `INDEX_ANY_SET_MAX` (8) bytes is looked for one byte at a time. The results are those of the scalar loops,
byte for byte (`src/ascii/ascii_test.odin`).

```odin
// a JSON string literal: the runs with nothing to escape are copied whole
for len(rest) > 0 {
	k := ascii.index_any_byte(rest, "\"\\", below = 0x20)
	if k < 0 { strings.write_string(&b, rest); break }
	strings.write_string(&b, rest[:k])
	// ... the escape of rest[k]
	rest = rest[k + 1:]
}
```

```odin
slice.sort_by(names, proc(a, b: string) -> bool { return ascii.compare_fold(a, b) < 0 })
// "bash", "Chrome", "chrome", "firefox"
```
