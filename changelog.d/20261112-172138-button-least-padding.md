type: Fixed

**A shared-width button keeps its padding**: the least width of `button_icon` with `width = fill()` now counts its label as the layout measures it (its text and its text padding), so a long label no longer runs against the button's right edge.
