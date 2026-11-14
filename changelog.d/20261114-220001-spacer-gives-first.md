type: Fixed

**An empty `fill()` spacer no longer takes a label's room**: in a row that is too narrow, an empty spacer (no children, no text, nothing drawn) now gives all its width before a label is cut. A row of a name and a `spacer(fill())` that asks for the whole row keeps the name whole while the row holds it. With room, `label … spacer(fill()) … buttons` lays out as before.
