type: Fixed

**A lazy column's view stays still while an item grows**: when an item is measured (one that streams in, below the view), the estimated height of the items never built changes. Those items above the view no longer move what it shows, not even by a pixel. The column builds the items where the view will be, follows its anchor for any move, and keeps its estimate on whole pixels.
