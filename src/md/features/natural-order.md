# Natural order of names

"file 2" comes before "file 10" in every list of names: the file picker's rows and its path bar's entries, the
settings' path completion, every text column of a `ui.Table`. `ascii.compare_natural(a, b)` is the order.

## The rule

- A run of digits compares by its value. The run is never made a number: its leading zeros are skipped, a longer run
  is larger, then the first digit that differs decides. A name with 100 digits compares as well as one with 2, and no
  integer overflows.
- The other bytes compare as `compare_fold` does: ASCII case ignored.
- Two names equal so far: the run with fewer leading zeros comes first ("a1" before "a01"), then `compare_fold` ("Chrome"
  before "chrome"). The result is 0 only for the same bytes, so a sort is the same at every run.

## Case: ASCII, not Unicode

classeur's `name_compare` folds Unicode letters and strips Latin accents ("é" with "e"). The toolkit folds ASCII
(`tests/unicode_case`): names compare by their bytes past ASCII. An accented name sorts after the unaccented ones. A
Unicode fold for display order is a separate decision (a collation, per language), and it is not this one.

## The default for text columns

`ui.Table` sorts every text column in natural order, and no option turns it off. What text columns hold:

- names (files, processes, programs, people): natural order is what a person expects;
- versions ("0.9.0", "0.10.0"): natural order is right, `compare_fold` is wrong;
- dates and times written with zero-padded fields ("2026-11-24 09:05"): runs of the same length compare as before;
- identifiers in hexadecimal: no order is meaningful, and natural order keeps equal names together.

No case was found where `compare_fold` is right and natural order is wrong. An option (`Table_Column.natural`) would be
a setting that every program sets the same way. The ties by the first column use the same order.

## Refused

- **A number parse of each run** (`strconv`): it overflows on a long run and allocates nothing more for no gain.
- **Unicode folding here**: see above.
- **A per-column option**: see above.
