type: Fixed

**A window closed while a font family loads no longer crashes**: `ui.destroy` waits for the family loads that still
read the fonts (at most 5 s), so the program may free its fonts once it returns.
