# A row of cells

`ui.cell_row` is a row of equal cells of which only those in view are built: a folder's pictures under a viewer, a
film's frames, a long row of swatches. A row of ten thousand cells builds the same few boxes as a row of ten. The chosen
cell stays in the middle of the row; the wheel moves the row, and it stays where the person put it until another cell is
chosen. The intent: [src/md/features/cell-row.md](../src/md/features/cell-row.md).

```odin
// the program's, kept between builds
strip: ui.Cell_Row

ui.next({width = ui.fill(), height = ui.px(em * 5)})
if cells, ok := ui.cell_row("###strip", &app.strip, len(app.pictures), {cell = em * 4.4, gap = em * 0.3, chosen = app.index}); ok {
	for i in cells.first ..< cells.last {
		ui.cell_row_next(&app.strip, i)                 // the next box is cell i, at its place
		cell := ui.build_box({.Clickable, .Draw_Hot_Effects}, fmt.tprintf("###cell%d", app.pictures[i].id))
		if ui.signal(cell).clicked { go_to(app, i) }
		if ui.parent(cell) { thumbnail(app, i) }         // only the cells built ask for their thumbnail
	}
}
```

## What it does

| Input | The row |
|---|---|
| Its first build | its box only: it was never laid out, so it does not know its width; the next build (at once) builds the cells |
| `chosen` changes | the view eases to put that cell in the middle, clamped to the row's ends |
| The wheel, Shift+wheel, a sideways delta | the row moves by `wheel_cells` cells a notch (down and right: toward the end); it stays there |
| Fewer cells than the width holds | they start at the left, one gap in |
| `count` shrinks | the view is clamped to the new end |

Build one box per cell, each after `cell_row_next`, and nothing else in the row: a screen reader is told each cell's
place in the whole row ("5001 of 10000", the chosen one selected) by their order. A focused cell that scrolls out of
view keeps the focus, as in a virtual list. The keys that move the chosen cell are the program's.

Give each cell an identity of the item it shows, not its index: a cell that keeps its key keeps its hover and its
animations when the row moves.

## API

| Call | What it does |
|---|---|
| `if cells, ok := ui.cell_row(id, &st, count, o); ok { ... }` | The row's box (width `fill()`, height one cell and two gaps, unless `next` says otherwise) and the cells in view, `cells.first ..< cells.last`. ok is false in its first build and with no cell. |
| `ui.cell_row_next(&st, i)` | The next box built is cell `i`: at its x, one gap from the top, `cell` wide, the row's height less two gaps tall. |
| `ui.cell_row_left(&st, i)` | Where cell `i` starts in the row, logical pixels (a test; a program that draws over the row). |

`Cell_Row_Options`: `cell` (a cell's width, logical pixels), `gap` (between cells and around them), `chosen` (the cell kept
in the middle; -1: none), `rate` (how fast the view follows, halvings a second; 0: `ui.CELL_ROW_RATE`, 18),
`wheel_cells` (0: `ui.CELL_ROW_WHEEL_CELLS`, 2).

`Cell_Row` is the program's: `scroll` (where the view goes), `free` (the wheel moved it), and what the build placed
by. A program may set `scroll` and `free` itself (a "show the chosen one" command sets `free = false`).

## Tests

`tests/scenarios/cell_row_test.odin`: of 10 000 cells 600 pixels show, 10 to 12 are built; the chosen one is in the
middle; the wheel moves the row toward its end and it stays; a click on a cell, made the chosen one, brings it to the
middle; three cells start at the left. A built cell says its place and the count; a focused cell wheeled out of view
keeps the focus.
