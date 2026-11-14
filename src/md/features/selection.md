# Item selection

Every list whose rows can be selected has the same selection: the one a person knows from a file manager. One model,
`ui.Item_Selection` (`src/ui/item_selection.odin`), holds it. `list`, `vlist`, `list_row` and `Table` use it through
`List_State`. A program that builds its own grid or list (a thumbnail grid) uses the same procedures. The selection of
text in labels (`src/ui/selection.odin`) is another concept, with another name.

## The model

- `sel`: the active row, the cursor. The keys move it. -1: none.
- `selected`: the identities of the selected rows (`multi` only).
- `anchor`: the identity of the row where a Shift range starts.
- `base`: the selection when the anchor was set. Ctrl+Shift adds its range to it.
- `version`: it moves with each change of the selection: a row selected or no longer, one row for another at the same
  count, and the active row. A cache compares it, not the set or the count. A palette's commands source takes it (with
  the program's own counts) as the version of its `disabled`: a command that acts on the active row, or on the rows
  selected, is greyed again when it moves. A count compared instead misses a swap of one row for another. The cursor
  was first left out ("the cursor alone"); a command on the active row then showed a stale `disabled`.

The rows are not in the model. Each call gets an `Item_Rows` view: the count, the identities (nil: the index is the
identity) and which rows can be selected. The model therefore stays pure: no `State`, no event, no frame. The tests
call it directly.

A single-choice list (`multi = false`) has no set: its selection is `sel` alone. Every gesture selects one row. A key
with Ctrl or Shift is not the list's: it stays the program's, as before the model (papier reads Shift+Page Down while
its list has the keyboard). A menu, a palette, a radio list and a list of settings pages are single by nature: they
keep `multi` off.

## The rules (`multi`)

Pointer:

- A click selects the row alone. The anchor goes to it.
- Ctrl+click toggles the row. The anchor goes to it, and the base becomes the selection.
- Shift+click selects the range from the anchor to the row, alone. The anchor stays.
- Ctrl+Shift+click selects the base and the range. The anchor stays.
- A right click on a row outside the selection selects it alone. On a selected row, the selection stays: the menu acts
  on it.

Keys, while the list has the keyboard:

- Up, Down, Page Up, Page Down, Home, End move the cursor and select its row alone.
- With Shift, they select the range from the anchor to the cursor. With Ctrl+Shift, the base and the range.
- With Ctrl, they move the cursor and change nothing in the selection.
- Ctrl+Space toggles the row under the cursor (as Ctrl+click).
- Ctrl+A selects every row that can be selected.
- Escape on several rows keeps the cursor's row alone. On one row or none, Escape is the program's: the list's
  `cancelled` (clear a filter, hide, close).

## Why

- **The range replaces the range.** Each Shift gesture computes the range again from the anchor, over the base. A
  second Shift+click that is nearer to the anchor therefore makes the range smaller, as in every file manager. A
  selection that only grows was the old behaviour of the marks; it was refused.
- **Plain Shift drops the base.** The rows that Ctrl selected before go. Ctrl+Shift keeps them. This is the behaviour
  of the file managers of Windows, GNOME and KDE.
- **The set is always explicit.** The old marks were empty while one row was selected: "the marks, else the active
  row". That rule was an implicit state machine with two states, and each reader had to know it. Now `selected` is the
  selection in every state, and `sel` is only the cursor. Ctrl+arrows can then move the cursor away from the selection.
- **Identities, not indices.** A row keeps its selection through a sort and a filter. When a row leaves the ids, its
  identity leaves the set (`vlist`, `item_selection_keep`). The anchor goes with it.
- **The widget computes the target, the model gives it a meaning.** `item_selection_move(to, mods)` takes the row the
  cursor goes to. A list computes it by rows, a grid by columns. `item_selection_key` does the computation for a list
  and calls the same procedure.
- **Escape keeps the cursor's row; it never leaves none.** A list always shows the row an act will take: with nothing
  lit, Delete or Kill still acted on the cursor's row, which the person could not see. And one selected row is a list's
  normal state (each move leaves one): an Escape that cleared it would cost every program's own Escape (clear the
  filter, hide the window, close the view) a press more. "Escape clears" was the first rule; inspecteur, papier and
  opencode native each wrote this one over it, so it moved here. Whoever reads Escape first owns it: a dialog that reads
  it before its list (the file browser) closes at once. A program that reads Escape itself, its list without the
  keyboard (a filter field has it), calls `item_selection_escape` first.
- **A row's identity may change** (a row unfolded whose id carries its height, so the list measures it again):
  `item_selection_rekey` moves its selection, its place in the base and the anchor to the new id. The cursor is an
  index: it stays.
- **A program's call before the next build.** `list_select(st, i)` in a multi list selects row `i` alone at the next
  build. At the time of the call, the list can still hold the ids of the last build (`table_apply` changed them).

## Not now

- A drag that selects (a rectangle, a press drawn over rows). The node graph has its own rectangle. Classeur has its
  rubber band. A list widget gets one when a second program needs it.
