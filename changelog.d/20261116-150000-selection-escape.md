type: Changed

**Escape on several selected rows keeps the cursor's row**: in a list with `multi`, Escape takes several rows back to the cursor's row alone; on one row or none it is the program's Escape (`cancelled`: clear its filter, hide, close), where it first cleared the selection. A list never shows no row while an act still takes the cursor's. `ui.item_selection_escape` gives the same rule to a program that reads Escape itself, and `ui.item_selection_rekey` keeps a row's selection when its identity changes (a row unfolded whose id carries its height).
