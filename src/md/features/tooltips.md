# Where a tooltip goes

A tooltip (`src/ui/popups.odin`) is a floating box over everything, not clickable, measured on the frame it opens and
shown on the next. Three calls place it; all keep it inside the window.

- `tooltip()`: below the pointer, right of its arrow; above it when it does not fit below. For a box the pointer rests
  on.
- `tooltip_beside(at)`: to the right of the pointer, or of the box `at`; to the left when there is no room. For the rows
  of a list or a table, where a tooltip below covers the next rows.
- `tooltip_near(at)`: about a rectangle of the window that is not a box (a node's header in a graph, a part of a
  drawing), or a box reached by the keyboard. It tries below, above, right and left of `at`, each moved inside the
  window, and takes the one that covers the least of `at`; on equal cover, the first in that order. A tooltip that
  fits below covers nothing and stays below; at the bottom edge, above; along a tall rectangle that fills the window's
  height, beside it.

## Decisions

- **Cover is measured on the anchor only.** The toolkit does not know what else matters around `at`, the program does
  not have to say it. Refused: a cover of every box under the tooltip (costly, and a box is not always what the person
  reads).
- **The order is fixed, not an option.** Below first reads as the other tooltips; a program that needs another side
  uses `tooltip_beside`. A preference option had no caller.
- **Centred on the anchor along its side**, then moved inside the window: a tooltip about a wide header sits under its
  middle, not under its left edge.
