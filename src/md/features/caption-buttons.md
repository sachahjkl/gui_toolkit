# Caption buttons

The window's minimize, maximize or restore and close (`window_buttons`; a panel stack's own through `caption_row`) are
the toolkit's boxes in the program's title bar, drawn with the system's look. Their boxes are the window's hit regions:
`chrome_collect` gives each drawn box to `platform.set_chrome_regions`, so Windows' `HTMAXBUTTON` (Snap Layouts) and
the Linux frame's buttons are the drawn rectangles, edge for edge, at every scale.

## Their size follows the interface scale

A button is `CAPTION_BUTTON_WIDTH` (46) wide with a `CAPTION_GLYPH_SIZE` (10) glyph, times `State.scale`: the system's
DPI times the person's zoom, as every other logical size. Its height is its row's, which the program already sizes with
the same scale. `caption_button_size` gives both numbers; the drawing and the panel stack's width test use it.

- At 100 % (DPI 1, zoom 1) the buttons are the system's, pixel for pixel: 46 px wide, a 10 px glyph.
- At a system DPI of 125 % and no zoom they are the system's buttons at 125 % (58 px, a 13 px glyph).
- A zoom of 125 % on a 100 % screen gives the same 58 px: the zoom and the DPI are one scale.

## Refused: the system's size whatever the zoom

The buttons once took `scale / zoom` ("the UI zoom does not apply"), to match the buttons of the system's own title
bars beside the window. Refused: in a title bar the program draws, the buttons sit beside its toolbar and tabs, which
follow the zoom. At 125 % zoom they stayed 46 px with a 10 px glyph inside a taller bar, smaller than the icons next to
them (Wren's report). The window's own consistency wins over the neighbouring windows'. A program that wants the
system's size keeps the zoom at 1.

The hit regions never needed the old rule: they come from the drawn boxes, so they follow any size.
