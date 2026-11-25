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
- **A card's icon is half its picture's height** (`TABLE_CARD_ICON`, `table_card_icon_size`). A row with no picture (a
  folder, a file the source has no thumbnail of, a table without `Table.picture`) shows its kind's icon in the picture's
  place; at the font's size it was a dot in the middle of a large card. The picture's height is its shorter side at
  every step (the card is 0.72 of its width high, its width less two gaps), so one share of the height scales it with
  the card. Half leaves the icon a margin that reads as a frame, as the file managers show it. The table draws the lead
  under a style of that font size; a program's `picture` callback that falls back to an icon calls
  `table_card_icon_size(size)` for the same size. Refused: an icon of fixed ems per step (a new step, or a change of
  `TABLE_CARD_PICTURE`, would need its own number; the anim between steps would jump).
- **The rubber band is the table's** (`Table.rubber_band`, `Item_Band`), for a multi table in every view. A press on the
  empty part of the view and a drag select every item the rectangle touches; with Ctrl, they are added to the selection
  there was; Ctrl and a press on an item start it from that item, taking items out when the item was selected. Escape
  gives the selection there was back. A frame tests only the items the rectangle touches, found by halves in the
  list's tops (O(log n)), and those it touched at the last frame (the items it left go back to the base). The rectangle
  is kept in the content: it scrolls with the items, and a drag near an edge scrolls the view (`drag_autoscroll`).
  `Item_Band` takes `Item_Rows` and a layout: a program that builds its own view uses it too.
- **The band box belongs to `box` and compensates its scroll offset.** `item_band_update` pushes `box` as parent when
  `parent_box() != box`, builds the floating rectangle box after the items, clamps it to `box`'s inner content area
  (inside `border_inset` and `bar_room_ends`), and sets `fixed_pos = r.min - box.rect.min + off` where `off` is `view_off`
  on axes where `box` scrolls (`box_scrolls`). Because `layout_positions` subtracts `off` from floating children too,
  adding `off` keeps the rectangle on screen at every scroll offset and during `drag_autoscroll`. Building inside `box`
  clips the rectangle to `box`, draws it above every item and below `box`'s scroll bars and border, and insulates it
  from any outer scrolling parent. Its fill uses `tuned` so linear and sRGB blend spaces match.
- **Press ownership transfers to `box` when a band starts.** When a band starts from a press on a virtualized row or
  card (Ctrl+press, grid row gap, or empty part of a row), `item_band_begin` and `item_band_update` call `press_hand` to
  move the active press to `box.key`. Because `box` stays built while rows leave the virtualized range, `boxes_gone`
  does not end the drag during edge autoscroll. A band whose box no longer holds the press is over: a view hidden when
  its press was let go does not follow a later press. Whenever `item_band_update` or `item_band_cancel` changes
  `Item_Selection.version`, it sets `anim_busy` so rows built earlier in the frame repaint on the next frame.
- **Full list views start a band from the empty part of a row.** In Details and List views (and in custom full-width
  lists), rows take the full width and a full list leaves no open background. A pointer press on the empty part of a
  selectable row enters `Item_Band`'s pending state (`Item_Band_Press`, `item_band_row_press`) without changing the
  selection yet:
  - If the pointer moves past `platform.drag_threshold` while held, the pending press promotes to an active band
    anchored at the press point (`keeping = .Ctrl in mods`, `removing = .Ctrl in mods && .Shift not_in mods && selected`)
    and hands the active press to `box.key`. Starting on an already-selected row's empty part works the same way, and
    Escape restores the pre-press selection.
  - If the button releases cleanly before the drag threshold, `item_band_update` applies the deferred click
    (`item_selection_click`, calling `changed` for each row that changed).
  - A lost release (focus loss or touch cancel) or Escape clears the pending state without changing the selection.
  - Screen reader clicks (`!pointer_pressed`), double clicks, right clicks, in-place rename (`line_edit` is clickable),
    keyboard navigation, and single-select tables stay unchanged.
- **Content hit classification costs O(cells of one pressed row) and re-measures no text.** Inside `list_row`, before
  `build_box` clears the previous frame's child links, `row_content_at` walks the children of the single pointer-pressed
  row only (zero work on non-press frames). Clickable controls, fixed-width icons, visual leaves, and the rendered text
  spans of `.Draw_Text` and `rich_paragraph` boxes (`text_dim`, `rich_width`: a paragraph's `text_dim` stays the
  layout's) count as content; space past text, column padding, empty cells, spacers, and the row's own background or custom draw count as
  empty. Programs that build their own full-width rows read `List_State.pressed_empty` (or call `row_content_at`) and
  pass `item_band_row_press` to `item_band_update`, guarding item drag with `band.active || band.pending`.
- **Full lists always keep a bottom strip and a right margin.** `Virtual_List.end_space` adds empty space below the last
  row (half a row in multi-select band tables) in the scroll limit and trailing spacer without changing `vlist_total` or
  `vlist_row_top`. `table_row_end` (the room of the last rule's grip, which Details rows have) on the List rows of a band
  table keeps a narrow empty margin at the right even when long names truncate. Refused: a wider end on every table.
- **The band leaves the rows that cannot be selected as they are** (`Item_Rows.selectable`): it neither selects nor
  unselects them, and the cursor never lands on one. A row that cannot be selected is not an item (a folded group's
  title): taking it acts on what is not shown. Escape restores every row from the base, those too: they were in
  the base only if they were selected before.
- **The band says each row it changes** (`Item_Band.changed`, with `Item_Band.user`): called once per row that goes in
  or out of the selection, at the moment it does, by the update, the press that clears the selection, a deferred click,
  and Escape. A program that keeps a sum of the selection follows it row by row, without the band's internals.
  Refused: a list of the rows changed returned by `item_band_update` (it needs an owner and a lifetime, and Escape and
  the press need lists of their own); a diff of the selection by the program (a pass over the rows per frame).
  A press without Ctrl clears the selection row by row (a pass over the rows, once per gesture) only when `changed` is
  set; without it, one `item_selection_clear`.
- **The step's card size moves smoothly** (`anim`): the cards grow between the steps, as in a file manager.

## Refused

- A view as a separate widget beside `Table` (a grid widget, a columns widget): each needs the filter, the sort,
  the selection, the keys and the empty text again.
- Cards of free sizes (a slider of pixels): the steps keep the layout stable and the keys simple; four sizes cover a
  list of names to a photo's preview.
- The band in a single table: the band selects several items.
- Re-measuring cell text per frame or per press to find empty row space: duplicates layout work when `Box.text_dim`
  already holds the measured text width.
- Selecting immediately on an empty-part press and reverting on drag: loses pre-press multi-selection on Escape and
  flashes the selection before the drag threshold.
- Wrapping `list_row` in an outer container to create empty margins: breaks joined selection pills (`row_face.odin`) and
  accessibility tree geometry.
- Adding `end_space` to `vlist_total`: shifts row-extent calculations and breaks `item_band_touches`.

## Subtle points

- The view changes in a build: the box that has the keyboard changes with it. The table moves the focus to the new
  view's box when the old one had it.
- In Grid and Columns the table resets the list's per-build flags (`activated`, `changed`, ...) itself, as `vlist`
  does, and marks the selection seen at the end (`selected_changed`).
- A row of cards is built by `list_row` with `selectable = false`: it is measured by the virtual list and drawn plain;
  the cards in it are the items.
- A card's press gives the keyboard to the grid's box (`vl.key`), as a row's press gives it to its list.
- `table_keys` takes no Left or Right: a filter field keeps its caret's keys.
