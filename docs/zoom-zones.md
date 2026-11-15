# Zoom zones: an area with its own zoom

A window has the interface's zoom (`ui.zoom`, `ui.set_zoom`). A program can also give one area a zoom of its own: a
conversation, a document, a terminal's grid. The person uses the same keys for both: the standard zoom keys act on the
zone that has the keyboard focus, and Ctrl+wheel on the zone under the pointer. Elsewhere, they zoom the window. A
program with no zone has only the window's zoom. The design is in
[src/md/features/zoom-zones.md](../src/md/features/zoom-zones.md).

```odin
app.zone: ui.Zoom_Zone                  // kept between builds
app.zone.memory = &app.zooms            // optional: a zoom per thing shown, remembered

// each build: the next box is the zone; its zoom scales what the program draws in it
zoom := ui.zoom_zone(&app.zone, app.chat.id)
ui.next({width = ui.fill(), height = ui.fill()})
if ui.column(id = "###conversation") {
	ui.next({font_size = ui.font_size() * zoom})
	...
}
```

The toolkit never scales the content of a zone: the program applies the zoom to what it draws there (a text size, a
grid's cells, a picture).

## The keys and the wheel

| Input | Acts on |
|---|---|
| `ZOOM_IN_KEYS`, `ZOOM_OUT_KEYS`, `ZOOM_RESET_KEYS` (Ctrl+= and Ctrl+Shift+=, Ctrl+-, Ctrl+0, the keypad's + and -) | the innermost zone that holds the box with the keyboard focus; else the window |
| Ctrl+wheel | the innermost zone under the pointer (the box drawn in front there); else the window. A box with `.Ctrl_Wheel` keeps it |

In and out multiply or divide the zoom by the Feel's `zoom_step` ([feel.md](feel.md)). Reset forgets the zone's zoom:
it follows its default again. `Build_Params.disable_zoom` gives all these keys and Ctrl+wheel to the program: no zone and
not the window takes them. `ui.zoom_key_action(key, mods)` says what a key press does to a zoom (`Zoom_Action`: `None`,
`In`, `Out`, `Reset`).

## The zone

| | |
|---|---|
| `Zoom_Zone{memory, key, zoom, min, max, serial}` | the program's, kept between builds. `memory`: where its zooms are remembered (nil: its own). `zoom`: its own zoom with no memory or no key, 0 the default. `min`, `max`: its own bounds (0: the memory's, else `ZOOM_MIN` and `ZOOM_MAX`). `serial` moves at each change made through it |
| `zoom_zone(&z, key = "") -> f32` | marks the next box built as the zone, showing `key`, and gives its zoom. For this build; `z` stays valid until the next `begin_build` |
| `zoom_zone_value(&z) -> f32` | its zoom now: the key's in the memory, else the memory's default; or its own |
| `zoom_zone_set(&z, zoom)`, `zoom_zone_by(&z, factor)` | a zoom given by the program (a menu's Zoom in: `zoom_zone_by(&z, ui.feel(s).zoom_step)`), within the bounds. A zoom within 0.005 of the default is the default: the key is forgotten |
| `zoom_zone_reset(&z)` | forgets its zoom: it follows the default (Ctrl+0) |
| `zoom_zone_destroy(&z)` | frees its key |

## The memory

A `Zoom_Memory` holds the zooms of the things some zones show, by key (a session's id, a shell's). Several zones can
share it: two zones that show two keys keep two zooms, and the same key in two zones is one zoom.

| | |
|---|---|
| `Zoom_Memory{kept, default, min, max, serial}` | `kept`: the zooms by key (`store.Kept`). `default`: what a key never zoomed or reset follows; the program sets it, from a preference for example, and a change reaches every key that follows it. 0: 1. `min`, `max`: the bounds of its zooms. `serial` moves at each change |
| `zoom_memory_load(&m, &file)` | reads the zooms from a `store.Store` the program opened, each within the bounds; each change is then written through it, on the Store's worker. Without it, the zooms last for the run |
| `zoom_memory_forget(&m, key)` | the thing is gone (a session deleted, a shell closed): its zoom too |
| `zoom_memory_destroy(&m)` | frees the zooms (the Store is the program's to close) |

A key at the default is never kept: its line leaves the file, and it follows the default when the default changes.

## What a zone does not do

- A menu does not take the keyboard focus: a menu opened from inside a zone leaves the keys to the zone. A dialog and a
  menu's search field take it, and are not in the zone: the keys zoom the window.
- The keys start from the focused box of the last build. A focus nowhere, or on a box the last build did not make, zooms
  the window.
