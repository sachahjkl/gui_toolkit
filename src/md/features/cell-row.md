# A row of cells (`ui.cell_row`)

A horizontal row of equal cells of which only those in view are built. From galerie's strip under its picture
(`src/strip.odin`): a folder of ten thousand pictures built ten thousand boxes a frame before it, and each asked for its
thumbnail.

## Decisions

- **Equal cells, placed by arithmetic, not measured.** A cell's place is `i * pitch + gap - shown`; the first and the
  last built come from the view's start and width in O(1). A row of cells of any width would need `Virtual_List`'s
  Fenwick tree of measured sizes: no program has asked for one, and a thumbnail strip, a film's frames and a palette's
  swatches are all equal.
- **Each cell at its own x (`fixed_x`) inside a clipping box; no view offset.** The layout places only what is built,
  and the scroll is the program's state (`Cell_Row.scroll`), eased by `anim`. A view with a content of ten thousand
  cells' width would need a spacer and the view's scroll machinery for nothing the row uses (no bar, no drag).
- **Not `ui.strip`.** A strip is a set of choices that all exist (tabs, chips) and scrolls by arrows to the next one;
  this row is a window on a long list whose cells mostly do not exist. A strip of ten thousand tabs is not a use.
- **Two states: Following and Free.** The chosen cell is kept in the middle (Following) until the wheel moves the row
  (Free); a different chosen cell returns to Following. The person who scrolls to look at other pictures is not pulled
  back at each frame, and the arrows of a viewer still bring the row along. The state is the program's struct, so a
  command can return to Following.
- **Virtual for the focus and the screen reader, as `vlist`.** A focused cell scrolled out of view is not built, not
  gone: the row raises `virtual_depth`, so the focus waits for it. The row is a `List_Box` and each built cell an option
  with its place in the whole row and the count (`position`, `set_size`, the chosen one `selected`): a screen reader
  says "5001 of 10000". The place comes from the order of the boxes built, so the row holds one box per cell and
  nothing else. Moving the chosen cell with the keyboard stays the program's, as `chosen` is.
- **The first build builds no cell.** The row's width is the last layout's; with none, it asks for a next build at
  once (`wake_within`) rather than guessing the window's width and building cells it will drop.

## The test that breaks it

`tests/scenarios/cell_row_test.odin`: of 10 000 cells, 600 pixels wide, at most 12 built; a wheel then three quiet frames
must not pull the row back. A focused cell wheeled out of view must keep the focus, and a built cell must say its place
in the whole row.
