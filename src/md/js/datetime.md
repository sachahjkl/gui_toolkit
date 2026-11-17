# Date (`src/js/datetime`, package `jsdate`)

`src/js/datetime` is the ECMAScript `Date` calendar and its strings, in Odin. It is ported from QuickJS-ng and gives the
same results as QuickJS over the whole valid range, so `Date` behaves the same without the C that ran in WebAssembly.
The package is named `jsdate` so that it never collides with `core:time/datetime`.

- A time value is milliseconds since the Unix epoch as `f64`, `NaN` for an invalid Date. The valid range is
  ±8.64 × 10¹⁵ ms (about ±273 790 years).
- Fields use the ECMAScript order `[year, month(0–11), day(1–31), hour, min, sec, ms, weekday, tz-minutes]`.
- The package allocates nothing and makes no system call: it builds for `windows_amd64`, `linux_amd64` and
  `freestanding_wasm32`.

## The time zone is the host's

The one thing it cannot compute alone is the local time zone offset: a `Timezone_Offset`, a contextless callback that
returns minutes west of UTC for an instant (`getTimezoneOffset(t)`). When it is nil, local time is UTC, so UTC-only
code and tests work with no host. The clock is the host's too: `Date.now` and `new Date()` read
`Host_Config.date_now_hook` of the runtime.

The callback is a parameter of each procedure that reads local time (`get_date_fields`, `set_date_fields`, `parse`).
The runtime passes its own, `Host_Config.timezone_offset_proc`. Refused: a package global. It was one in Wren, where
each runtime had a Wasm instance of its own; natively it would be every runtime's ([README.md](README.md), State).

## Subtleties

- `get_date_fields` returns `ok = false` for a `NaN` time when `force` is false: the caller then gives "Invalid Date", or
  a RangeError for `toISOString`.
- `set_date_fields` makes the specification's MakeDay, MakeTime and MakeDate in `f64`, in the order of operations
  ECMAScript requires, so out-of-range months and days roll over exactly as required (and the fp-evaluation-order
  test262 case passes).
- `parse` tries the strict ISO form first, then the legacy format: weekday and month abbreviations, `GMT±HHMM`, named
  zones (`GMT`, `UTC`, `PST`, `CET`, …), `AM`/`PM`, comments in parentheses, and the loose day/month/year orders old
  browsers accept. Input is folded to ASCII first (U+2212 → `-`, anything else above 255 → `x`) and capped at 127 bytes,
  as in QuickJS.
- Local time is not invertible when the offset changes with the instant, exactly as in QuickJS. The UTC calendar is.

## How we know it is correct

A differential judge compiled QuickJS's Date calendar and parser (copied verbatim from `quickjs.c`) with `zig cc`, with
the same deterministic, instant-dependent time-zone rule on both sides, and compared **1 500 000+ cases**:

- `set_date_fields` on random fields, including out-of-range months and days and years over ±300 000, in UTC and in
  local mode;
- `get_date_fields` on random time values, the ±8.64e15 limits and `NaN`, in UTC and local, with and without `force`;
- the UTC calendar inverse (`set(get(t)) == t`);
- `parse` on ISO and UTC strings made from random times, a set of hand-written legacy forms, and the extreme-year ISO
  boundaries.

Result: **0 mismatches.**

## The contract with the runtime

The runtime backs `Date` objects with the `f64` time value. It calls `set_date_fields` for the `Date` constructor,
`Date.UTC` and the setters, `get_date_fields` for the getters, `format_date` for the `toString` family, and `parse` for
`Date.parse` and `new Date(string)`.
