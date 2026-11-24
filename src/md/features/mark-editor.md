# Marks on a picture (`gt:marks`, `ui.Mark_Editor`, `ui.mark_editor_dialog`)

## Purpose

A person draws on a picture before they send it: a box around a button, an arrow to a line, a word, a hidden
password. cliche had such an editor, for its screenshots. opencode native needs one for the pictures of its image
viewer and of its composer's attachments: the picture with its marks replaces the attachment. One editor serves both:
the model and the widget are the toolkit's; a program keeps its words around it and what it does with the result.

## Layers

- **`gt:marks` (package `tk_marks`): the model, pure.** The document (the picture's size, the shapes, the selection,
  the crop, the undo steps), the view (zoom and pan), the tools and their styles, the interaction as one state machine
  (`step`), the geometry of each shape as figures, and the flattening. No window, no renderer, no font: its tests run
  with no window. It imports `gt:undo`, `gt:ink` and `gt:paint`, all pure Odin.
- **`ui.Mark_Editor`: the widget.** It builds the tool bar, the canvas and the end buttons in the box the program
  gives. It turns the pointer and the keys into the model's events, draws the figures with `gt:draw`, and runs the
  flattening on the chores. A program embeds it in a panel, a view or a dialog.
- **`ui.mark_editor_dialog`: the dialog.** The widget in a view of its own, one per window, as `ui.file_dialog` shows
  the file picker. Its answer comes once, to a procedure.

## The state machines

The model's interaction (`Mode`):

```
Idle --press--> Drawing | Moving | Resizing | Panning | Cropping | Selecting | Typing
Idle --Shift+press on a shape, Select--> Idle (the shape added to the selection, or taken from it)
Drawing, Moving, Resizing, Panning, Cropping, Selecting --release--> Idle
Typing --text end, press--> Idle
```

A gesture is one undo step: the document is copied when it starts, and the copy goes on the undo stack when it ends,
unless the gesture changed nothing. A click on a shape selects it and leaves no step.

The widget has two more machines of its own:

- The flattening: `Idle --Done--> Flattening (a chore) --pixels--> Idle (.Done, the result held)`. A second Done
  during a flattening does nothing. The result stays the editor's until `mark_editor_result` takes it.
- The filters of the screen: per Pixelate cell and per Blur radius, `asked (a chore) --pixels--> made (a texture)`.
  They are asked when the shapes change (the model's `changes` counter), never at each frame.

## Decisions

- **One geometry for the screen and the file.** `figures(doc, shape)` gives each shape as polylines to stroke and
  polygons to fill, in the picture's pixels: a rectangle's outline (its corners rounded by its radius), an ellipse's,
  a line, an arrow's shaft and heads, the dashes, a highlighter's box, a text's background box, a pen's ink. The screen
  draws them with `gt:draw` at the view's zoom; the flattening fills them with `gt:paint`. The file looks as the canvas
  did, and a new shape is written once. Refused: cliche's single painter over `gt:draw`, flattened by an offscreen
  target read back from the GPU. A test with no renderer could not check a pixel, and the readback takes frames of the
  interface's thread.
- **The flattening runs on the chores, with `gt:paint`.** Each shape is painted on a canvas of its own bounds only,
  then laid over the picture's bytes (source over). A canvas of the whole picture holds 16 bytes a pixel: 130 MB for a
  4K screenshot. Pixelate and Blur read the picture as it came, as the screen shows them: a shape under a blurred box
  is hidden by it, not blurred into it.
- **Text: outlines taken on the interface's thread, filled on a chore.** The font state is the interface thread's (as
  `licence_card_engrave.odin` knows). At Done, the widget shapes each text and takes its glyphs' outlines into paths in
  the picture's pixels: a few dozen glyphs, once. The chore fills them. The measure of a text (its box, its hit test)
  is a procedure that the program's font answers (`Measure`), so the model knows no font.
- **The pen is `gt:ink`.** A pen shape keeps its samples (position, time, pressure, tilt). The model keeps its ink
  outline as a polygon and as triangles, made again only when its samples or its width change; a move shifts them.
  The screen draws the triangles (`draw.triangle`: a long stroke passes the points that `gt:draw` takes in one fill);
  the flattening fills the polygon with the non-zero rule. The pen's look is the program's (`Options.pen`, a
  `tk_ink.Pen`); its width is the style's. cliche's pen was a polyline of constant width with an optional head: the
  head is left out, the Arrow tool draws an arrow.
- **The picture is shared, counted.** The pixels are copied once, at `mark_editor_init`, into a counted buffer. Each
  chore (a filter, the flattening) takes a count, and the last one out frees it. The editor never waits for a chore:
  destroyed during a flattening, it lets go of its count, and the chore's answer finds no editor.
- **The tools are the program's choice.** `Options.tools` says which show, `Options.tool` which is chosen first,
  `Options.styles` each tool's first style (a zero style: the toolkit's), `Options.colors` the swatches. The bar shows
  what the chosen tool or the selection can change (`props`).
- **Styles are in logical pixels.** `Options.scale` is the picture's pixels per logical pixel: on a screenshot taken at
  200 %, a stroke of 4 is 8 of its pixels.
- **A run of one field is one undo step.** The values that a slider runs through on one selection merge into the step
  that its first value made, as in cliche.

## Subtle points

- The selection is a flag on each shape (`Shape.picked`): it moves with the shape when the order changes. `selected` is
  the picked shape whose style the bar shows. The handles show when one shape is picked.
- A shape drawn smaller than 4 window pixels was a click: it is dropped, and no undo step remains. A pen's dot stays:
  a dot is a mark.
- A text emptied, or left blank, is no text: its end removes it.
- An undo snapshot holds the shapes and the crop, nothing else: an undo selects nothing.
- `changes` counts every change that the screen must show (a gesture's move too); the undo stack counts the kept ones.
- Pixelate's cells are on one grid for the whole picture: two boxes side by side make one mosaic.

## What cliche keeps, and the migration

cliche keeps its words, its window (the title bar, the palette, the sheet of keys, the menus), and what it does with
the picture: Copy, Save, Save as, Upload, Pin, Print, the workflow's Done, the files dropped, the history. These are
the parts of a screenshot tool, not of an annotator.

`gt:marks` does not have these parts of cliche's editor: speech balloons, step numbers, the smart eraser, the
magnifier, the pictures pasted or inserted, the mouse pointer, the stickers, the shadows, the picture's own operations
(turn, mirror, resize, margins, cut out a band), the auto crop and the pen's head. A program that needs one adds it to
`gt:marks` first, with its figures and its tests; then cliche uses it there.

| cliche | The toolkit |
|---|---|
| `editor_model.odin` (`Edit_Model`, `edit_step`, the undo) | `gt:marks` (`Model`, `step`, `undo`, `redo`) |
| `editor_model_test.odin` | `src/marks/marks_test.odin` (ported); cliche keeps the tests of what it adds |
| `editor_export.odin` (the painting, the GPU export, the mosaics, the blurred copies) | `marks.figures`, `marks.flatten`, `marks.mosaic_make`, `marks.blur_make`; the screen's painting is the widget's |
| `editor.odin` (the canvas, its input, the text field, the tool and property bars) | `ui.mark_editor` in cliche's window; cliche keeps its title bar, palette, menus and actions bar |
| `editor_output.odin` (Save as, Upload, Print, the files dropped) | cliche's own: it starts from the result of `.Done` |

The steps:

1. cliche builds its window around `ui.mark_editor` with `hide_end_buttons`. Its own actions (Copy, Save, Done...)
   call `mark_editor_done` and remember which action asked; the result of `.Done` goes to that action.
2. Its saved tool and styles (`edit_choices_*`) read and write `Mark_Editor.model.tool` and `.styles`.
3. It deletes `editor_model.odin`, `editor_model_test.odin`, `editor_export.odin` and the canvas parts of
   `editor.odin`. What it gives up (the list above) waits for `gt:marks` to have it.

## Refused

- **The widget as a window of its own.** A program embeds it where its picture is (a view, a panel, a dialog); a
  window of its own is a view shown as a window.
- **A callback per change.** The build returns its events (`.Changed`, `.Done`, `.Cancelled`, `.Failed`), as the other
  widgets do. The dialog alone answers to a procedure, as `ui.file_dialog` does.
- **The flattened picture encoded by the editor.** The program wants RGBA (a texture, an upload, a PNG): it encodes
  what it needs on its own chore.
