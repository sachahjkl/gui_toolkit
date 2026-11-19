# A table's views: intent

What a program sees and the API are in [docs/data-views.md](../../../docs/data-views.md) (section "A table's views"). This
file keeps the reasons. Classeur showed the views first (its `View_Mode`, its grid of cards, its rubber band); the
toolkit's table now has them, so the file browser and classeur share one implementation.

## Purpose

A list of files reads better in another shape for each task: the details to compare sizes and dates, the names alone
to scan, the names in columns to see a whole folder, cards with their pictures to find a photo. The person changes the
shape with one gesture (Ctrl+wheel, Ctrl+= and Ctrl+-, a control of the program) and the program keeps it.

## Decisions

- **A view is a layout of the same rows.** `Table.zoom` picks a step of `table_zoom_step`: Details, List (the names
  alone), Columns (the names column by column, scrolled sideways), then Grid at four card sizes. Every view reads
  `Table.rows` and `Table.ids` as `table_apply` made them: the filter, the sort and the folders first are the same in
  every view. Refused: a second list per view (a copy of the filter, the sort and the selection that drift apart).
- **One zoom index, not a view and a size.** The steps are ordered from the densest to the largest, so one key (in or
  out) and one control (a slider of steps) go through all of them. `table_view` derives the view. A program saves the
  step by its stable name (`table_zoom_key`, `table_zoom_from_key`): the order of the steps may change, the names do not.
- **The selection is the table's list's in every view** (`Table.vl`'s `Item_Selection`, over `Table.ids`). A program
  reads `vl.sel`, `list_selected_ids(&t.vl)` and `table_selected` whatever the view. In Grid and Columns the table keeps
  the list's rows itself (`count`, `row_ids`: the items) and gives `vl.key` the box that has the keyboard, so
  `set_focus(t.vl.key)` and the focus checks of a program still work. Refused: a selection per view (a switch of view
  would lose it), and the grid's virtual list as the selection (its rows are rows of cards, not items).
- **The grid is a virtual list of rows of cards** (`Table.grid`). A row of the grid holds `line_items` cards; its
  identity is its first card's identity mixed with the count, made again only when the ids or the count change
  (`grid_ids`, its own version). The heights, the scroll and the building of the rows in view are the virtual list's: a
  folder of 100 000 pictures builds the cards in view. Its own list state is not a selection: its active row follows
  the cursor's card only to bring it into view.
- **The columns view builds only the columns in view.** Its box scrolls sideways; the wheel, either way, scrolls it.
  The names a column holds come from the box's height at the last layout. Refused: a virtual list on X (the toolkit's
  is on Y; columns of equal width need no measures).
- **Cards per row and names per column come from the last layout's size** (`prev_box`): the first build guesses, the
  next one is right. Recomputing them costs nothing; the grid's ids are made again only when the count changes.
- **The keys move by item in Grid and Columns.** Grid: Left and Right by a card, Up and Down by a row of cards, Page Up
  and Page Down by a page of rows. Columns: Up and Down by a name, Left and Right by a column. What a move does to the
  selection is `item_selection_move` (alone, Shift, Ctrl, Ctrl+Shift), as everywhere. The other keys (Enter,
  Ctrl+Space, Ctrl+A, Escape, type-ahead) are the list's own (`list_keys` on `vl`). While the keyboard is in a filter
  field, `table_keys` moves by row of cards (Down) or by name (Columns); Left and Right stay the field's.
- **The zoom keys reach a table through a zoom zone** (`Table.zoom_keys`, `zoom-zones.md`): Ctrl+wheel over the table and
  the zoom keys while the keyboard is in it step its zoom instead of the window's. The table reads its zone's zoom as a
  number of steps (the log of the zone's factor in steps of `feel.zoom_step`), keeps the fraction (a touchpad's small
  deltas add up) and sets the zone back to 1. Ctrl+0 (the zone's reset) gives the first step back. Refused: a second
  router of the zoom keys (two routers disagree about who has the keys) and `.Ctrl_Wheel` (it takes only the wheel).
  Off by default: a table that does not ask keeps the window's zoom keys.
- **`Table_Events.zoomed` says the step changed**, by a key, the wheel or `table_set_zoom`: the program saves it.
- **A card is a picture, a name and a weak line.** The picture is `Table.picture` at the card's size, else the lead
  (the row's icon) at that size. The name takes two lines where the card has room, else one; too long, it is cut in its
  middle with its extension kept (`table_card_name`): the end of a file's name says what it is. The weak line is the
  text of `Table.card_line` (a size).
- **The rubber band is the table's** (`Table.rubber_band`, `Item_Band`), for a multi table in every view. A press on the
  empty part of the view and a drag select every item the rectangle touches; with Ctrl, they are added to the selection
  there was; Ctrl and a press on a card start it from that card, taking items out when the card was selected. Escape
  gives the selection there was back. A frame tests only the items the rectangle may touch, found by halves in the
  list's tops (O(log n)), and those it touched at the last frame (the items it left go back to the base). The rectangle
  is kept in the content: it scrolls with the items, and a drag near an edge scrolls the view (`drag_autoscroll`).
  `Item_Band` takes `Item_Rows` and a layout: a program that builds its own grid uses it too.
- **The step's card size moves smoothly** (`anim`): the cards grow between the steps, as in a file manager.

## Refused

- A view as a separate widget beside `Table` (a grid widget, a columns widget): each would need the filter, the sort,
  the selection, the keys and the empty text again.
- Cards of free sizes (a slider of pixels): the steps keep the layout stable and the keys simple; four sizes cover a
  list of names to a photo's preview.
- The band in a single table: the band selects several items.

## Subtle points

- The view changes in a build: the box that has the keyboard changes with it. The table moves the focus to the new
  view's box when the old one had it.
- In Grid and Columns the table resets the list's per-build flags (`activated`, `changed`, ...) itself, as `vlist`
  does, and marks the selection seen at the end (`selected_changed`).
- A row of cards is built by `list_row` with `selectable = false`: it is measured by the virtual list and drawn plain;
  the cards in it are the items.
- A card's press gives the keyboard to the grid's box (`vl.key`), as a row's press gives it to its list.
- `table_keys` takes no Left or Right: a filter field keeps its caret's keys.
