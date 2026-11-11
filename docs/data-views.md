# Tables, graphs and meters

What a monitor or a list of records shows: values over time and their graphs, a bar of how full something is, a
sortable table, and a filter that takes what the user types anywhere in the window. All are in the `ui` package.

## Values over time (`src/ui/line_graph.odin`)

`Value_History(N)` keeps the last `N` values pushed, oldest first. It allocates nothing.

```odin
cpu: ui.Value_History(60)
ui.value_history_push(&cpu, percent)              // once per sample
ui.value_history_last(&cpu)                       // the newest (0 when there is none)
ui.value_history_max(&cpu)
ui.value_history_at(&cpu, i)                      // 0 ..< cpu.count, oldest first
ui.value_history_values(&cpu)                     // a copy, oldest first (temp allocator): a series of a graph
ui.value_history_clear(&cpu)
```

`line_graph(id, series, opts)` draws one or more series in the box that `next` gives. Each series is an area under its
line, filled with its colour fading to the bottom. The newest value is at the right edge. The grid and the frame use the
theme's border colour; in the machined finish a graph with a grid is a well (a screen set in the surface).

```odin
ui.next({width = ui.fill(), height = ui.px(em * 12)})
ui.line_graph("###disk", {
	{ui.value_history_values(&disk.read), ui.color("accent")},
	{ui.value_history_values(&disk.write), purple},
}, {floor = 1e6, points = 60, grid = true})
```

| `Line_Graph_Opts` | |
|---|---|
| `top` | the value at the top. 0: `graph_top` of the largest value shown, at least `floor` |
| `floor` | what the found top is at least (0: 1). A disk at rest with a floor of 1 MB/s does not fill the graph with noise |
| `points` | values across the width (0: the longest series'). A history that is not full yet starts at the right |
| `grid` | grid lines and a frame |
| `columns`, `rows` | spaces of the grid (0: 10 and 4) |

`line_graph_top(series, opts)` is the top the graph shows: the caption of the graph says it. `graph_top(v, floor)` is a
round value at or above `v`: 1, 2 or 5 times a power of ten, at least `floor`.

`sparkline(id, series, top, points, floor)` is a line graph with no grid and no frame, for a list of devices.

## A meter bar

`meter_bar(id, used, alert)` is a flat bar of how full something is (`used` from 0 to 1): the theme's accent on its border
colour. Past `alert` the bar takes the colour of the `bad` tag. It has no animation: it shows the last sample. Screen
readers read it as a progress indicator in percent. In the machined finish it is a slot carved in the surface, its run a lit face.

```odin
ui.next({width = ui.fill(), height = ui.px(max(3, em * 0.25))})
ui.meter_bar("###memory", used_share, 0.9)
```

Tests: `tests/status/line_graph_test.odin`.

## Sortable tables (`src/ui/table.odin`)

A table has two layers. A program that builds its own rows (groups, tinted cells) uses the first; a table of texts uses
both.

### The layout, the header and the cells

`Table_Layout` holds the columns (`Table_Column`), their widths now in ems, which are shown, the sort column and its
direction. A program saves it and reads it back.

| `Table_Column` | |
|---|---|
| `title` | the header's text |
| `width` | in ems; 0: the room the other columns leave (one column has it) |
| `number` | right-aligned; sorted by the row's number; the first click sorts the largest first |
| `low_first` | a number that the first click sorts from the lowest (an id) |
| `weak` | its text in the weak colour (details beside the name) |
| `hidden` | not shown until the user asks for it |

| Procedure | |
|---|---|
| `table_layout_init(l, columns, sort, descending)`, `table_layout_destroy(l)` | the widths and the shown columns from the columns' own |
| `table_layout_reset(l)` | the columns' own widths and visibility back (the "Default columns" of a menu) |
| `table_layout_toggle(l, k)` | shows or hides column `k` (never the first); true when the sort moved to the first column |
| `table_header(id, l, lead_em)` | the titles: a click sorts by a column, a second click reverses it, a third comes back to the table's own sort (`table_sort_click`); the rule at a column's right edge, dragged, resizes that column and moves those after it (the fill column takes its width of the moment at the first drag: then the table scrolls when wider than its room); the sort's arrow at the title's end. Returns `sorted`, `resized` (a rule let go: save the layout) and `menu` (a right click on the header). `next` may set the header's background and height |
| `table_widths_text(l, keys)`, `table_widths_apply(l, keys, text)` | the widths that are not the columns' own, as a preference's text (`pid=6.5,command=30`, in ems; `keys[k]` names column k), and back (bounded; a name it does not know is skipped) |
| `table_sort_text(l, keys)`, `table_sort_apply(l, keys, text)` | the sort as a text (`memory`, `-memory` when descending), and back (only to a column shown) |
| `table_column_items(l)` | the columns' menu items, in the caller's `ctx_menu`: each column but the first, checked when shown |
| `table_min_width(l)`, `table_scroll_sync(l, header, list)` | the least width of a row (the columns shown, the fill column's least, the scroll bar's room); the rows' sideways scroll given to the titles in the same build. A table narrower than its columns scrolls sideways (Shift+wheel, a touchpad): `table_build` does it; a program that builds its rows gives its list `View_Scroll_X`, `Allow_Overflow_X` and its rows `fill_least(table_min_width(l))`, then calls `table_scroll_sync` |
| `table_width(l, k)` | a column's width: its own, or for the fill column what the others leave, never under `TABLE_FILL_MIN_EM` (`fill_least`, resolved in the same build) (too narrow a window: the last columns go past the edge, cut, instead of the fill column going to nothing). A cell a program builds itself takes it |
| `table_cell(l, col, text, bg, fg, border)` | a cell under its title, clipped to the column, on a background `bg` with its text in `fg` and a 1 px outline in `border` (each optional: a busy cell's tint, the text that reads on it, a stronger shade of the tint). True when the pointer is on it and its text is cut |
| `table_cell_tip(row, text)` | the cut text, in a tooltip beside the pointer after `TABLE_TIP_DELAY_S` |
| `table_row_end()` | the room of the scroll bar at the end of a row |
| `text_cut_under_mouse(b, text, pad)` | the test of `table_cell`, for a cell a program builds itself |
| `text_shown(text)` | a text with a zero-width space between two `#`: a `##` would end the shown part of an id |

### More than one row (`src/ui/list.odin`)

A list (`list`, `vlist`, the rows a program builds with `list_row`) has one active row, `sel`. With `multi` set on its
state, rows can be marked besides it: a Ctrl click marks a row or unmarks it (the active row joins the marks first), a
Shift click marks the rows from the last one clicked to this one, a click alone clears the marks, and Ctrl+A marks every
row while the list has the keyboard (a move with the keys alone clears them). A marked row is drawn as the active one. A
right click on a row outside the marks clears them; on a marked row, the marks stay (the menu acts on them). A row is
marked by its identity: a `vlist`'s id (a mark goes when its row is no longer in the ids: gone or filtered out), a
`list`'s index. The selection a program acts on is the marked rows, or the active row when none is marked.

| Procedure | |
|---|---|
| `list_is_marked(st, i)`, `list_mark_count(st)` | whether row `i` is marked; how many are (0: the active row alone) |
| `list_mark(st, i, on)`, `list_mark_all(st)`, `list_marks_clear(st)` | the program's own changes (its Ctrl+A when another field has the keyboard); `marks_changed` says the frame changed them |
| `list_row_id(st, i)` | the identity a row is marked by |

### Stripes, rules and a row's tint

Two fields of the list's state (`List_State`, so a `vlist`'s and a `Table`'s `vl` too) set the look of its rows:
`zebra` shades every second row (the theme's `list_row zebra background`, a step off the page toward the text), `rules`
draws a hairline under each row (`rule border`). The active and the marked rows keep the selection's colours.
`list_row(st, i, label, selectable, tint)` takes a `tint`: the row's background in place of its stripe (a row that just
came, a row in alert).

```odin
app.table.vl.zebra, app.table.vl.rules = true, true
row := ui.list_row(&app.vl, i, label, tint = is_new ? green_flash : nil)
```

A program's own motion (that flash fading) asks `animations_on()` first (false when the desktop asks for less motion),
draws from the clock (`now_ms`) and calls `keep_animating()` while it still moves: the frames stop when it stops.

### The table of texts

`Table_Data` holds the rows of one reading: each cell's text (in the data's arena), the number a numeric column sorts by,
each row's identity, what the filter looks in, and its tone (`Normal`, `Dim`: the `weak` tag, `Bad`: the `bad` tag).
`Table` is a `Table_Layout` with the rows shown and the virtual list that builds only the rows in view.

```odin
SERVICE_COLUMNS := [?]ui.Table_Column{{title = "Name", width = 18}, {title = "Description", width = 0, weak = true}, {title = "PID", width = 5, number = true}}
ui.table_init(&view.table, SERVICE_COLUMNS[:])

// a new reading
ui.table_data_reset(&view.data, len(SERVICE_COLUMNS))
for u in units {
	ui.table_data_row(&view.data, id_of(u.name), strings.join({u.name, u.description}, " ", context.temp_allocator), u.failed ? .Bad : .Normal)
	ui.table_data_cell(&view.data, u.name)
	ui.table_data_cell(&view.data, u.description)
	ui.table_data_cell(&view.data, pid_text(u.pid), f64(u.pid))
}
ui.table_apply(&view.table, &view.data, query)

// in the build
key_ev := ui.table_keys(&view.table)                   // when no menu or dialog is open
ev := ui.table_build("###services", &view.table, &view.data, query != "" ? "Nothing matches." : "No service.")
if ev.sorted { ui.table_apply(&view.table, &view.data, query) }
if ev.menu || key_ev.menu { open_menu(ev.menu ? ev.menu_at : key_ev.menu_at) }
```

| Procedure | |
|---|---|
| `table_data_reset(d, cols)`, `table_data_destroy(d)`, `table_data_count(d)` | |
| `table_data_row(d, id, search, tone)`, then `table_data_cell(d, text, num)` once per column | a row; `search` is what the filter finds it by |
| `table_data_text(d, row, col)`, `table_data_clone(d, text)` | a cell's text; a copy that lives as long as the rows |
| `table_init(t, columns, sort, descending)`, `table_destroy(t)` | |
| `table_apply(t, d, query)` | filters (the query in each row's search text, case ignored) and sorts again: texts with `ascii.compare_fold`, numbers by their value, ties by the first column. The selected row stays selected when it is shown; a new filter selects its first row |
| `table_selected(t)` | the data row selected, -1 for none |
| `table_select_id(t, id)` | selects a row by its identity and brings it into view |
| `table_keys(t)` | Up, Down, Page Up, Page Down, Ctrl+Home, Ctrl+End move the selection while the keyboard is elsewhere (a filter field); Enter activates; the Menu key and Shift+F10 ask for the row's menu under the selected row (`keyboard` is true) |
| `table_build(id, t, d, empty)` | the header and the rows. A cut cell shows its whole text in a tooltip. The selection is drawn strong while the window is the user's (`inactive` is false), whatever has the keyboard. `empty`: what the table says with no row |
| `table_label(d, row)` | what a screen reader says of a row: its first two cells |

`Table_Events`: `menu` and `menu_at` (a right click on a row selects it), `keyboard`, `activated` (a double click or
Enter), `sorted`, `resized`, `columns` (a right click on the header). `Table.lead(t, row, size)`, when set, builds what
goes before the first cell's text (an icon `size` wide); `lead_user` is the caller's. `Table.lead_em` is the room
before the first title and the first cell (0: 0.6 em). `Table.header_bg` is the header's background (nil: none).

## Type to filter (`src/ui/type_to_field.odin`)

`type_to_field(field)` gives the keyboard to one field (a filter, a search box) when a printable character was typed in
this build and no text field has the keyboard. The field takes the character in the same build. A list that has the
keyboard does not keep the character for its type-ahead: the field gets it. Call it in the build before the field is
built; the field's key is its box's key from the build before.

```odin
if !dialog_open { ui.type_to_field(view.search_key) }
view.search_key = ui.line_edit("###search", &view.search, "Filter").box.key
```

## A tooltip per segment

`segmented(id, labels, selected, tips)` shows `tips[i]` when the pointer rests on segment `i` ("" or a missing entry: no
tooltip). A screen reader reads it as the segment's description.

Tests: `tests/data_views` (the table, type to filter, a segment's tooltip).

## Sections, tiles, stacked bars, title strips

Pieces of a dense dashboard (`sections.odin`). `hue(.Cyan)` is a hue of the theme shown (`Hue`: accent, blue, purple,
green, yellow, red, cyan, rose), for what a program colours by meaning.

```odin
ui.section_header("###mem", "Memory", "what the boot program left", "462 MiB", ui.hue(.Cyan))
ui.stacked_bar("###time", {{20.6, ui.hue(.Yellow), "20.6 ms"}, {33.2, ui.hue(.Blue), "33.2 ms"}})
if ui.flow({4, 4}) { for f, i in files { ui.tile(fmt.tprintf("###f%d", i), f, ui.hue(.Green)) } }
if ui.title_strip("###boot", "Boot") { open = false }
```

| Procedure | What it is |
|---|---|
| `section_header(id, title, note, value, color)` | a stripe of the colour, the title in capitals and bold in it, a weak note, a large value at the right |
| `tile(id, text, color, clickable)` | a tile of the colour over what is under it, its words light; as wide as they are |
| `stacked_bar(id, parts)` | a well cut in `Bar_Part`s (share, colour, words), the words of each in it when they fit; full width, 1.9 lines |
| `title_strip(id, title, closable)` | a title, white and bold, on the accent fading to the bar's colour; a red block closes (true) |

In the machined and edged finishes a tile, a part and the strip are lit along their top and shaded along their bottom.
