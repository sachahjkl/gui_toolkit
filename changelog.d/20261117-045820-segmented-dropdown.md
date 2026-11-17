type: Added

**A segmented control too wide for its row becomes a dropdown.** With no width given, `ui.segmented` asks for its labels' width and gives way to a dropdown's: in a row that cannot hold its labels it shows a dropdown of the same choices, and its segments again when the row holds them. `ui.dropdown_width` gives a dropdown's own width.
