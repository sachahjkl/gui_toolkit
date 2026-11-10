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

```odin
slice.sort_by(names, proc(a, b: string) -> bool { return ascii.compare_fold(a, b) < 0 })
// "bash", "Chrome", "chrome", "firefox"
```
