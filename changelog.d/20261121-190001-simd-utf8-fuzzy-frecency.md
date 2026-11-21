type: Added

**Portable SIMD UTF-8 validation (`gt:utf8`), SIMD `ui.fuzzy_score` and `ui.Frecency`**:
  - `gt:utf8` validates UTF-8 16 bytes at a time (`#simd[16]u8`, `base:intrinsics` only, optional `reject_controls`),
    verified against a scalar reference across 400 000 fuzz inputs and boundary windows; `gt:site` now uses it.
  - `ui.fuzzy_score` runs a portable `#simd[16]u8` fast path on ASCII candidates up to 128 bytes with bit-exact results
    verified over 200 000 fuzz inputs.
  - `ui.Frecency` adds a storage-independent frecency ranking table (`frecency_note_use`, `frecency_score`,
    `frecency_bonus`, `frecency_encode`/`frecency_decode`), sharing modus's exact decay and bonus model.
