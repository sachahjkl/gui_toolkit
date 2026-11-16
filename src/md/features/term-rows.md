# A terminal's rows as pictures

`term` draws each row of the grid as a retained picture (`draw.Picture`). A frame replays the pictures of the rows that
did not change and records only the rows that did. Before, every frame drew every run of every row again: a grid at rest
cost 0.21 ms of the interface's thread for nothing (opencode native's grid, an optimised build).

## Decisions

- **A picture is keyed by the row's content, not by its position.** A terminal's typical change is a scroll: a new
  line at the bottom moves every row up by one. Keyed by position, every row would differ from its picture and record
  again: a line printed costs as much as a full redraw. Keyed by content, a row moved up finds the picture its content
  had one line lower, and only the new line records. Two equal rows (two empty prompts, two lines of a box) share one
  picture.
- **The key is a sum, made when the row is built.** `sink_close` hashes the row's text, runs, fills and marks into
  `Row.sum`, field by field (a struct's padding is no part of it). A row that is not built again keeps its sum: a frame
  where nothing changed hashes nothing. The draw mixes the sum with the row's *look*, what decides its pixels other than
  its cells: the face, the size, the cell, the spacing, the selection's colour, and where the grid starts within a
  pixel. A change of any of them records the rows again.
- **Recorded inside one pixel, replayed moved by whole pixels.** A row is recorded with the grid's sub-pixel position
  (the fraction of its origin) and replayed under a translation by whole pixels. Its glyphs then fall on the sub-pixel
  positions a direct draw gives them: a replay is the direct draw, byte for byte. A grid that moves by a fraction (a
  layout of fractional sizes) is another look, and records again.
- **What no row showed goes.** At the end of a draw, the pictures that no row asked for are released. Their pictures go
  to a spare list (at most as many as rows) and are recorded over: the scrollback that scrolls by does not allocate a
  picture per line. A picture lives as long as a row shows it, so the memory is that of the screen, not of the
  scrollback.
- **Stale: once again, then direct.** A replay says `.Stale` when an atlas page its glyphs are on was reused. The row
  records once more and replays. If it is still stale (the grid drawn under a scale: a dialog that opens grows from
  0.95), the row is drawn directly: a picture recorded under a scale would record again at every frame of the animation.
- **The pictures belong to no window.** A grid moved to a window of its own replays its pictures in another draw
  context. The picture knows the context that holds its GPU ranges (`Picture.owner`) and uploads again in the new one:
  the widget does not track contexts ([../infrastructure/picture-owner.md](../infrastructure/picture-owner.md)).
- **The cursor is drawn directly.** It blinks and moves at every key: a picture of it would record at every frame.

## Measured

opencode native's grid of a shell, an optimised build, the interface's thread (the prototype's timer over 300 draws):

| Frame | Each run drawn | Rows as pictures |
|---|---|---|
| At rest | 0.21 ms | 0.009–0.019 ms |
| A line printed (one row records, the rest move) | 0.66 ms | 0.47 ms |

The toolkit's bench (`tests/term/bench_test.odin`, opt-in): 40 rows of 120 cells of coloured words, the box's draw alone,
an optimised build, the median of 300 draws over three runs. "Printing" includes reading the 4800 cells of the screen
again (`refresh`).

| Frame | Each run drawn | Rows as pictures |
|---|---|---|
| At rest | 0.85–1.06 ms | 0.019–0.028 ms |
| A line printed at each draw | 0.86–0.90 ms | 0.077–0.083 ms |

## Refused

- **A picture of the whole grid.** One letter typed would record every row.
- **Pictures keyed by position.** A scroll records every row (above).
- **Slots per row in one picture.** A slot moves a row without recording it, but the rows of a scroll change content
  as well as place: the content key does both without a slot table to keep in step with the source's rows.
- **A picture per row kept for the scrollback.** The memory of thousands of lines, for a scroll that records a few rows
  per frame anyway.

## Tests

`tests/term`: one line printed records one row, not the screen; a draw at rest records none; a scroll records only the
row that comes in. `rows_recorded` counts the recordings.
