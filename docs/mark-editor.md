# Mark editor: draw on a picture

A person draws on a picture before they send it: boxes, ellipses, arrows, lines, ink, a highlighter, text, pixelated
or blurred parts, and a crop. `gt:marks` is the model (no window); `ui.Mark_Editor` is its widget, which a program puts
in any box; `ui.mark_editor_dialog` shows it in a dialog with one call. The design and the migration of cliche are in
[src/md/features/mark-editor.md](../src/md/features/mark-editor.md).

## In a program's layout

```odin
import "gt:ui"
import "gt:marks"

App :: struct { marks: ui.Mark_Editor, open: bool }

// When the picture comes (straight RGBA8; copied):
ui.mark_editor_init(&app.marks, rgba, w, h, {tool = .Arrow})
app.open = true

// In the build, where the editor goes (it fills the box that next gives):
if app.open {
	ev := ui.mark_editor("marks", &app.marks)
	if .Done in ev {
		pixels, size, _ := ui.mark_editor_result(&app.marks)   // heap: the program frees it
		attachment_replace(app, pixels, size)
	}
	if .Done in ev || .Cancelled in ev {
		ui.mark_editor_destroy(&app.marks)
		app.open = false
	}
}
```

The editor builds a bar of tools and properties, the canvas, and a bar with undo, redo, delete, the zoom, Cancel and
Done. Done flattens the picture on the chores: the build that has it returns `.Done`. `mark_editor_result` takes it
once. Nothing reads or writes a pixel on the interface's thread.

## In a dialog

```odin
done :: proc(rgba: []u8, size: [2]int, ok: bool, user: rawptr) {
	if !ok { return }   // (cancelled, or the picture could not be flattened)
	app := (^App)(user)
	attachment_replace(app, rgba, size)   // rgba is the procedure's: free it with delete(rgba, runtime.heap_allocator())
}

ui.mark_editor_dialog(app.ui_state, rgba, w, h, {}, done, app, i18n.tr("Draw on the screenshot"))
```

One dialog per window. A dialog asked while another shows answers that one first, with `ok` false. The person's
close (the close cross, Escape) is Cancel. `done` comes once, at a later build of that window.

The dialog opens at the picture's size: the picture at 100 % with the bars around it, at least
`MARK_DIALOG_MIN_WIDTH_EM` by `MARK_DIALOG_MIN_HEIGHT_EM`, at most 90 % of the window (`MARK_DIALOG_MOST`). A larger
picture is fitted in it. `size_em` gives another first size, in ems:

```odin
ui.mark_editor_dialog(app.ui_state, rgba, w, h, {}, done, app, size_em = {80, 50})
```

The person can resize the dialog. The program's views memory keeps that size (`dialog=` in its line,
[views.md](views.md)), and the next opening uses it instead of the first size.

## API

| | |
|---|---|
| `mark_editor_init(&e, rgba, w, h, options) -> bool` | The editor shows the picture (copied). False: no picture (a size of 0, too few bytes). |
| `mark_editor(id, &e) -> Mark_Editor_Events` | One build of the editor in the box `next` gives (else it fills its parent). |
| `mark_editor_done(&e)` | Flattens the picture, as the Done button does (a program with its own Done). |
| `mark_editor_cancel(&e)` | The next build returns `.Cancelled` (a program with its own Cancel). |
| `mark_editor_busy(&e) -> bool` | A flattening is under way. |
| `mark_editor_result(&e) -> (rgba, size, ok)` | The flattened picture of the last `.Done`, taken: the caller frees it with `delete(rgba, runtime.heap_allocator())`. |
| `mark_editor_destroy(&e)` | Everything freed. A chore still running finishes on its own. |
| `mark_editor_dialog(s, rgba, w, h, options, done, user, title, size_em) -> bool` | The editor in a dialog over the window of `s`. `size_em`: its first size in ems (`{}`: the picture's). |
| `mark_editor_dialog_shown(s) -> bool` | Its dialog is open. |

`Mark_Editor_Events` holds `.Changed` (a kept change: an undo step, an undo, a redo), `.Done`, `.Cancelled` and
`.Failed`.

`Mark_Editor_Options` (a zero field takes the toolkit's choice):

| Field | |
|---|---|
| `tools` | The tools offered (`{}`: every one). |
| `tool` | The tool chosen first (nil: Arrow, or the first one offered). |
| `styles` | Each tool's first style (`[marks.Tool]marks.Style`; a zero style: the toolkit's). |
| `colors` | The swatches, 0xRRGGBB (nil: `marks.COLORS`). |
| `scale` | The picture's pixels per logical pixel: 2 for a screenshot at 200 %. Widths and text sizes are logical. |
| `pen` | The pen's ink, a `tk_ink.Pen` (nil: `marks.PEN_DEFAULT`). Its width is the style's. |
| `hide_end_buttons` | The program shows its own Done and Cancel. |

`e.model` is the `marks.Model`: a program reads its tool and styles to keep the person's choice, and sets them after
`mark_editor_init`.

## The tools and keys

| Key | |
|---|---|
| V, R, E, A, L, P, H, T, B, G, C | Select, Rectangle, Ellipse, Arrow, Line, Pen, Highlighter, Text, Pixelate, Blur, Crop |
| Shift while drawing | A square or a circle; a line at a multiple of 45° |
| Shift+click (Select) | A shape added to the selection, or taken from it |
| Ctrl+Z, Ctrl+Shift+Z or Ctrl+Y | Undo, redo |
| Delete, Backspace | Delete the selection |
| Ctrl+A, Ctrl+D | Select every mark, duplicate the selection |
| Home, Page Up, Page Down, End | The selection to the front, forward, backward, to the back |
| Arrows (Shift: ten) | Move the selection a pixel |
| Ctrl+wheel, the wheel, middle drag, Space+drag | Zoom about the pointer, pan |
| Ctrl+1 | Actual size |
| Ctrl+Enter | Done |
| Escape | Deselect; with nothing selected, Cancel |

A double click on a text, or a click with the Text tool, types in it again. A right click on a shape opens its menu.
The keys act while the keyboard is in the editor (its canvas takes it at the first build).

## gt:marks without the widget

`gt:marks` (package `tk_marks`) is pure Odin: a program that draws its own canvas uses the model alone.

- `init(&m, size, options)`, `destroy(&m)`; `step(&m, event)` for the pointer (`Press`, `Move`, `Release`, `Wheel`,
  `Typed`, `Type_End`, in window pixels); `view_place(&m, canvas)` each frame.
- `to_picture(view, p)` and `to_window(view, p)` convert between window pixels and picture pixels. `to_canvas(view, p)`
  gives a picture point from the canvas's top left: use it for a box laid out inside the canvas, because the layout
  places a child against its parent.
- The operations: `undo`, `redo`, `delete_selection`, `delete_all`, `duplicate`, `nudge`, `order`, `select_all`,
  `deselect`, `style_set`, `tool_set`, `crop_set`, `crop_clear`. Each returns false when it changes nothing.
- `figures(&m.doc, &shape, &out, allocator)`: a shape as polylines to stroke and polygons to fill, in picture pixels.
  A text's letters and the boxes of Pixelate and Blur are the painter's.
- `flatten_input_make(&m, rgba, size)`, then `flatten(&input)` on a worker: the picture with its marks, cropped. A
  text's letters come as paths (`Flatten_Text`) that the program takes from its fonts.
- `mosaic_make`, `blur_make`: what Pixelate and Blur show, made once per picture and size.
- `changes` counts every change that the screen shows; `doc.edits` counts the kept changes.

## Limits

- A picture larger than the renderer's largest texture shows grey on the screen; its flattening is whole.
- The mosaic is drawn as one rectangle per cell: a pixelated box over a large picture with small cells draws many.
- Speech balloons, step numbers, the magnifier, stickers, shadows and the picture's own operations (turn, mirror,
  resize) are not in `gt:marks` yet.
