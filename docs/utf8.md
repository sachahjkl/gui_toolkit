# utf8: portable SIMD UTF-8 validation

`gt:utf8` validates UTF-8 byte slices sixteen bytes at a time using portable `#simd[16]u8` and `base:intrinsics` only
(no `core:` imports). Algorithm: John Keiser and Daniel Lemire, "Validating UTF-8 In Less Than One Instruction Per Byte"
(2021). Design: [src/md/infrastructure/utf8.md](../src/md/infrastructure/utf8.md).

```odin
import tk_utf8 "gt:utf8"

if !tk_utf8.valid(bytes) { return }
if !tk_utf8.valid_string(text, reject_controls = true) { return }
```

| Procedure | Result |
|---|---|
| `valid(bytes, reject_controls := false) -> bool` | true when `bytes` is well-formed UTF-8 (RFC 3629); with `reject_controls = true`, also refuses `U+0000..U+001F`, `U+007F`, and `U+0080..U+009F` (`C2 80..9F`) in the same SIMD pass |
| `valid_string(s, reject_controls := false) -> bool` | `valid` on a `string` |
| `valid_scalar(bytes, reject_controls := false) -> bool` | scalar RFC 3629 reference oracle |
