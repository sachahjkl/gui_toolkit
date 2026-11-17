# base: what every package stands on

`import base "gt:base"` (the package is named `gt_base`, so a program keeps its own `base`). Pure Odin, any target. It
holds the interface thread's check (`base.blocking`, [tasks.md](tasks.md)), the opt-in performance checks
(`base.perf_enabled`, `base.perf_skip`, [testing.md](testing.md)) and the readers of binary formats below.

## Big-endian integers

| Procedure | Result |
|---|---|
| `read_be16(d, at) -> (v: int, ok: bool)` | the unsigned 16 bits at `at` of `d` |
| `read_be32(d, at) -> (v: int, ok: bool)` | the unsigned 32 bits at `at` of `d` |

A read that starts before `d` or ends past it gives `0, false`, never a panic: a font or a file is untrusted input. Both
are `#optional_ok`: a reader that checked the lengths takes the value alone, one that did not ends with `or_return`.

```odin
count := base.read_be16(table, 2)                 // the lengths were checked before
offset := base.read_be32(table, at) or_return     // the procedure gives up on a short table
```
