type: Changed

**The fuzzy matching folds once**: `ui.fuzzy_needle`, `ui.fuzzy_text` and `ui.palette_entry` fold a query and a text once, and `fuzzy_find`, `fuzzy_score`, `fuzzy_words`, `fuzzy_typos` and `palette_match` take them as well as strings, with the same results. A `ui.Fuzzy_Cache` keeps them from one frame to the next: the palette folds its query once per query and each command once while it stays the same, where it folded both for every command, up to five times, every frame. The fold of the ASCII runs goes 16 bytes at a time.
