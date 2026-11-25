type: Fixed

**The selection rectangle shows wherever the view is scrolled**: `ui.item_band_update` builds it in the view's own box, at its scroll, so it is no longer drawn out of a scrolled list or of Columns. A drag started with Ctrl on an item goes on when that item scrolls out, the rows repaint at once, and a band whose view was hidden does not follow a later press.
