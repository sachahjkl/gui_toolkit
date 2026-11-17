type: Added

**Columns that go one under the other.** In a `ui.flow`, children sized as a share of the width are columns: side by side while the line holds them at the width their content needs (or their own `least`), one under the other when it does not, the rest of each line shared by their values; a column starts at the top of its line. And a row or a column puts its `gap` between its children, as CSS's `gap`: a stack of cards takes `gap = {0, em * ui.ITEM_GAP}`.
