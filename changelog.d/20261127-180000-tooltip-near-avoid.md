type: Added

**`ui.tooltip_near` avoids what it must not cover.** Its new `avoid` argument takes lists of rectangles by priority (a
point is a rectangle of no size): the tooltip takes the side or corner next to its anchor that covers the fewest of the
first list, then of the next. A graph's link tooltip stays off the hovered link, the nodes' titles and the other links.
