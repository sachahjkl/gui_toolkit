type: Fixed

**Readable details and search highlights on selected rows**: secondary (`weak`, `faint`, `soft`) and coloured text inside
a selected row now adapt their ink to the selection's background (at least 4.5:1 contrast at rest and hovered, in every
theme), matched letters in a selected row (`match_runs`, `label_fuzzy`, palette) are underlined in the row's ink instead
of tinted with `match_bg`, and find-bar matches switch their text ink to black or white when a theme's tint over a
selection would leave `find_text` hard to read.
