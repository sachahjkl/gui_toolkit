# A lazy column's anchor

After each layout, a lazy column keeps the first item visible where it was on screen: the items built above the view
may not be as tall as the estimate that stood for them, and the view follows its anchor by as much (`lazy_settle`).

## Decisions

- **The move is rounded to 1/64 px.** The anchor's place in the content is a sum of `f32` heights. Near 3000 px, the
  layout's sum and the exact one differ by a few thousandths. Followed as it is, such an error left a view that a move
  brought to its top at 0.003 instead of 0 (a hundred items of 30.7 px folded to nothing). A view at 0.003 is not at its
  top: what asks whether it is (a bar's state, the next anchor's test `view_off > 0`) reads it wrong. 1/64 is exact in
  `f32` up to 2^18 px, and finer than any sub-pixel step the renderer shows.
- **The remainder is kept.** The view shifts by the rounded move, and what rounding left is subtracted from the next
  anchor's place (`anchor_top`). Tiny moves are ignored one by one, and they add up: a series of them moves the view
  once their sum is worth a step, and never drifts away from the content.
- **No threshold.** An earlier threshold (follow only moves over half a pixel) took a smaller move as the next anchor's
  place: such moves added up into a drift. Rounding with the remainder kept loses nothing.

## Tests

`tests/scenarios`: a lazy column scrolled to its top by an anchor move near 3000 px reads exactly 0.
