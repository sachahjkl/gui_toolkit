# Where a tooltip goes

A tooltip (`src/ui/popups.odin`) is a floating box over everything, not clickable, measured on the frame it opens and
shown on the next. Three calls place it; all keep it inside the window.

- `tooltip()`: below the pointer, right of its arrow; above it when it does not fit below. For a box the pointer rests
  on.
- `tooltip_beside(at)`: to the right of the pointer, or of the box `at`; to the left when there is no room. For the rows
  of a list or a table, where a tooltip below covers the next rows.
- `tooltip_near(at, avoid)`: about a rectangle of the window that is not a box (a node's header in a graph, a part of a
  drawing), or a box reached by the keyboard. It tries below, above, right and left of `at`, then its four corners
  (above right, above left, below right, below left), each moved inside the window. It takes the place that covers the
  least of `at`; on equal cover, the one that touches the fewest rectangles of `avoid`'s first list, then of its
  second, and so on; then the first in that order. A tooltip that fits below covers nothing and stays below; at the
  bottom edge, above; along a tall rectangle that fills the window's height, beside it.

## Decisions

- **Cover is measured on the anchor, then on what the program names, in its order.** The toolkit does not know what
  else matters around `at`; a program that knows says it in `avoid`: lists of rectangles, the first list worth more
  than all the others. A curve is given as points (rectangles of no size), a title as its rectangle. A graph's link
  tooltip avoids the hovered link around the pointer, then the nodes' headers, then the other links. A rectangle counts
  once, touched or not (with the gap around the tooltip), not by its area: a header half covered is unread as much as
  one fully covered. The lists only break a tie of the anchor's cover.
  Refused: a cover of every box under the tooltip (costly, and a box is not always what the person reads); one list
  with weights (a weight says how many links a title is worth, which nobody can say); points and rectangles as two
  parameters (a point is a rectangle of no size).
- **Corners after the sides.** Around a pointer in a crossing, each side often lies on something: a link along it, a
  title beside it. The four corners stay as near (`at`'s corner, the gap away) and often find the free quarter. They
  come after the sides, so a tooltip with nothing to avoid stays below as before.
- **The order is fixed, not an option.** Below first reads as the other tooltips; a program that needs another side
  uses `tooltip_beside`. A preference option had no caller.
- **Centred on the anchor along its side**, then moved inside the window: a tooltip about a wide header sits under its
  middle, not under its left edge.
