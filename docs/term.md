# term: a terminal's grid

`import "gt:term"`. The grid of a terminal as a widget: the cells of a screen, a selection made with the pointer, the keys
and the mouse turned into bytes, the scrollback under the toolkit's scroll bar, a zoom of its own, a cursor. It emulates
nothing: a `Source` gives it the screen and takes what it sends back. An emulator stands behind it (opencode native uses
libghostty-vt), or a program's own model of a screen (a command's output, a log with colours).

```odin
v: term.View
term.init(&v, my_source(&screen), cols = 80, rows = 24)   // the size until the grid is laid out
defer term.destroy(&v)

// each build: all the room it is given, a box with the id "###term_box"
term.build(&v, style, take_focus = asked)

// before the interface sees the frame's events: the keys to the view with the keyboard, the pointer to the one that
// holds a press (v.press != .None), else to the one under it (term.contains)
switch term.event(&v, e) {
case .Ignored: // the interface sees it too
case .Taken:
case .Copy:    clipboard_set(term.selection_text(&v))
case .Paste:   term.paste(&v, clipboard_get())
case .Menu:    // the program's menu at e.pos (term.select_all, term.has_selection...)
case .Zoomed:  // keep v.zoom if it is kept; a frame after term.ZOOM_REST_MS
}
```

## The source

`Source` is a pointer (`data`) and procedures. The optional ones may be nil.

| Procedure | What |
|---|---|
| `picture(data) -> (Picture, ok)` | the screen now: `dirty` (`None`, `Rows`, `All`), the colours of a cell without its own, the `cursor` (shown, cell, `Block` / `Bar` / `Underline`, colour) |
| `rows(data, sink)` | the rows of that picture, top to bottom: `sink_row(sink, changed)` for each, and when it returns true, `sink_cell(sink, cell)` for each of its cells; then the source takes its dirty flags as read |
| `scrollbar(data) -> (Scrollbar, ok)` | rows: `total`, the first shown (`offset`), how many are shown (`len`) |
| `scroll(data, delta, bottom)` | the rows shown move by `delta` (up: below 0), or to the last ones |
| `resize(data, cols, rows, cell, changed)` | the grid laid out, at each build; `changed`: another size than the last one |
| `write(data, bytes)` | optional: what is typed, pasted, or the mouse. nil: a grid to read |
| `modes(data) -> Modes` | `Bracketed_Paste`, `App_Cursor` (read by `xterm_key`), `Mouse_Tracking` |
| `encode_key(data, key, buf) -> int` | optional: a key's bytes. nil: `xterm_key` |
| `encode_mouse(data, mouse, buf) -> int` | optional: a mouse event's bytes, with the grid's geometry (`Mouse_Input`). nil: the mouse is never reported |
| `select(data, op, cell) -> bool` | optional: the selection (`Begin`, `Extend`, `End`, `All`, `Drop`, `Has`), in cells of the rows shown |
| `selection_text(data, allocator) -> string` | the text selected |

A `Cell` is its grapheme (UTF-8, read during the call), `fg`, `bg` and `has_bg`, and `flags`: `Bold`, `Faint`, `Inverse`,
`Invisible`, `Underline`, `Strike`, `Selected`. The widget swaps an inverse cell's colours, draws a faint one at
`Style.faint`, a selected one in `Style.selection`.

The selection is the source's: an emulator knows where its ends go when rows come, when the scrollback drops its
oldest rows, when the grid is wrapped again. The widget makes the gesture: a press begins a drag on a cell (`Begin`), the
selection starts once the pointer leaves that cell (`Extend`), the release ends it (`End`); typing drops it.

## The rows drawn

The widget keeps each row as it draws it, in columns: runs of text of one look (`Run`), background rectangles (`Fill`),
underlines and lines through (`Mark`). `refresh` (the draw calls it) takes the picture and builds again only the rows the
source says changed: a frame where nothing changed reads no cell and builds no row. A new zoom or face moves the rows
without building them. `recolour(&v)` (a new theme: the source's colours moved) builds every row at the next draw.
`v.hold = true` keeps the picture drawn last (a program that awaits a whole new screen after a resize).
`rows_built` counts the rows built, and `row_text(&v, y)` gives a row's text as drawn: what a test reads.

## Input

- Keys: a printable key alone gives nothing, its `Text` event types the character; Ctrl with Alt is AltGr. Ctrl+Shift+C
  and Ctrl+Insert copy (Ctrl+C alone where nothing is typed, `read_only`), Ctrl+Shift+V and Shift+Insert paste,
  Shift+Page Up and Page Down scroll a page. Ctrl+=, Ctrl+- and Ctrl+0 zoom (`ZOOM_STEP`, between `ZOOM_MIN` and
  `ZOOM_MAX`). What is typed goes to the last rows and drops the selection.
- `paste_text` puts a paste in brackets when the program asks for them; else its line ends are returns.
- The pointer: a press on the toolkit's scroll bar is the interface's (`on_bar`). A program that tracks the mouse gets
  the presses, the moves and the wheel (Shift: the pointer selects, and a right click opens the menu); the release of a
  press it was told of comes wherever the button is let go, or when the press is taken away (`press_end`).
- The wheel scrolls the rows shown by the lines the system says; Ctrl and the wheel zoom.
- The grid keeps its size while the zoom moves and takes its new number of columns once the zoom has rested for
  `ZOOM_REST_MS`: each new number wraps every row of the scrollback again.

## Tests

`tests/term` drives the widget on a screen of its own, without a window or a font: the row cache, the selection, the
keys, the paste keys, the press held and let go, the zoom keys.
