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
theme's border colour.

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
readers read it as a progress indicator in percent.

```odin
ui.next({width = ui.fill(), height = ui.px(max(3, em * 0.25))})
ui.meter_bar("###memory", used_share, 0.9)
```

Tests: `tests/status/line_graph_test.odin`.
