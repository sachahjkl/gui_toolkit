type: Added

**A text selection across rows built only in view.** A selection in a diff's view or in a lazy column now stays when its first row scrolls far out, and a copy has every row between. A container declares its rows with `ui.selection_rows_begin(ui.Text_Rows{...})`, `ui.selection_row` and `ui.selection_rows_end`, builds the rows of `ui.selection_held_rows()` wherever they are, and gives a row's text by its index; `ui.lazy_begin(rows = ...)` does it for a lazy column, `gt:diff`'s view does it already.
