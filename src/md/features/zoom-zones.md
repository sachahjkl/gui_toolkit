# Zoom zones

A program can have more than one zoom: the interface's (the window's `State.zoom`), and the zoom of one area (a
conversation, a document, a terminal's grid). The person has one set of keys for all of them: the standard zoom keys
act on the zoom of what they work in. The area's zoom belongs to the thing it shows (a session, a shell), and comes
back with it. The code is `src/ui/zoom_zone.odin`; the routing is in `process_events` (`src/ui/events.odin`).

## The model

- A `Zoom_Zone` is the program's, kept between builds. At each build, `ui.zoom_zone(&z, key)` marks the next box as the
  zone, sets what it shows (`key`), and gives its zoom. The mark lives one build, as `next` does.
- The program scales what the zone draws by that zoom (its font size, its em). The toolkit never scales the content of
  a zone itself: what a zoom means is the program's (a text size, a grid's cell, a picture's scale).
- A `Zoom_Memory` holds the zooms by key: a `store.Kept` (a key → number map, written through a `store.Store` on its
  worker when the program gives one with `zoom_memory_load`), a default, bounds. Several zones can point at one memory.
- With a memory and a key, the zone's zoom is the memory's for that key, else the memory's default. With no memory or no
  key, the zone has its own zoom (`Zoom_Zone.zoom`), 0 being the default.

## The routing

One rule, for every program:

- **A key** of `ZOOM_IN_KEYS`, `ZOOM_OUT_KEYS` or `ZOOM_RESET_KEYS` acts on the innermost zone that holds the box with
  the keyboard focus. The walk goes up the parents of the focused box, in the last build's tree.
- **Ctrl+wheel** acts on the innermost zone under the pointer: the box drawn in front at the pointer, then its
  parents. If nothing is drawn there, the deepest box under the pointer (last siblings first) is the start.
- If no zone is found, the window's zoom takes the key or the wheel, as before zones existed.
- In, out: the zoom is multiplied or divided by the Feel's `zoom_step`, then clamped to the bounds (the zone's, else the
  memory's, else `ZOOM_MIN` and `ZOOM_MAX`). A zone change makes the build that follows a whole one (`pointer_only` off).
- A box with `.Ctrl_Wheel` (a node graph, a preview) under the pointer keeps Ctrl+wheel, in a zone or not.
- `Build_Params.disable_zoom` gives every zoom key and Ctrl+wheel to the program: the window's and every zone's.

## The default and Reset

- A key never zoomed follows the memory's default. The program sets `Zoom_Memory.default` (a preference's value); the
  zoom is read through it at each `zoom_zone_value`, so a new default reaches every key that follows it, at once.
- Reset (Ctrl+0) forgets the key: it follows the default again. It does not set the key to 1, nor to the default's
  value of now: a later change of the default must reach it.
- A zoom set to the default is a forgotten key too (`store.Kept` keeps no value at its rest). A zoom within
  0.005 of the default is the default: steps in and out come back near it, not to it, and a key left at 1.0000001
  would keep a line in the file and stop following the default.

## Decisions

- **The memory is the toolkit's.** opencode native kept a zoom per session and per shell with its own procedures over
  two `store.Kept` (the key, the default from a preference, the reset that forgets), and handled the keys before the
  build. Every program with a zoom per document needs the same: one memory type, one rule of default and reset.
- **A memory wraps `store.Kept`, not a new store.** `Kept` already is a key → number map, read once, written on the
  Store's worker, a value at its rest not kept. The memory adds what a zoom needs: the default and the bounds. The
  interface's thread does no file work: `kept_set` hands the line to the Store, whose worker writes it.
- **The key is set at each build** (`zoom_zone(&z, key)`): a pane that shows another session shows that session's zoom
  in the same build, with no event to send. The zone keeps a copy of the key: the box and the routing read it at the
  next frame's events, after the build's temporary memory is gone.
- **A Box field, not a State map.** The walk reads each ancestor of a box; a field is one load per ancestor, a map one
  lookup. The field is written by `build_box` for every box, so a box built without the mark has no zone: nothing to
  clear at the start of a build. The scroll marks (`Box.bar_marks`) keep a program's pointer the same way.
- **One reading of a zoom key, for the window and the zones.** `zoom_key_action` decides what a key press is: Ctrl
  without Alt on =, keypad +, -, keypad - or 0, whatever Shift says. That holds every chord of the standard tables
  (Ctrl+Shift+= is AZERTY's Ctrl++), and the Shift forms the window took before zones (Ctrl+Shift+-), so a program
  without zones behaves as it did.
- **The terminal's grid is a zone.** `gt:term` had its own zoom keys and Ctrl+wheel in `term.event`, before the
  interface: a second routing. Its `View` now holds a zone; `event` leaves the zoom keys and Ctrl+wheel to the
  interface; `build` marks its box and follows the zone's zoom, with the rest before a new grid size as before.

## Refused alternatives

- **Two sets of keys** (Ctrl+= for the area, Ctrl+Shift+= for the window, as opencode native had): a person must learn
  which is which, and Ctrl++ on AZERTY is Ctrl+Shift+=, so one keyboard loses one of the two zooms.
- **Keys routed by the pointer.** The keyboard acts where the keyboard is. The pointer rests anywhere while a person
  types: a zoom key that follows it changes an area the person does not look at. The wheel is a pointer's input, so the
  pointer routes it.
- **The toolkit scales the zone's content** (a scale on the box's subtree). The window's scale is in every size of the
  build; a second scale in a subtree must reach every widget's pixel constant, the text cache and the hit tests. Each
  program already knows what its own zoom changes.
- **A zone found by the last focused zone** (a memory of where the person was). It is one more state that can disagree
  with the focus. The focus is already that memory.
- **Reset to 1, or a reset that keeps the default's value.** The key would stop following the preference.
- **A memory per zone.** Two panes on one session would show two zooms of the same thing.

## Subtle points

- **A menu or a dialog over a zone.** A menu does not take the keyboard focus (what opened it keeps it), so a menu
  opened from inside a zone leaves the keys to the zone. A field of a menu (a search) and a dialog take the focus, and
  their boxes are not in the zone's subtree: the keys zoom the window. The wheel over a dialog is the dialog's box in
  front: the window zooms, not the zone under it.
- **A zone that was not built in the last build.** The walk starts only from a box of the last build, and the parents
  of a built box are built. A box of an earlier build keeps a stale pointer, which nothing reads. A focused box out of a
  virtual list's built range is not walked: the window zooms.
- **The keyboard focus nowhere** (`focus_key` 0, or a box that is gone): no zone holds it; the window zooms.
- **The press that moves the focus.** The events of one batch are read in order: a click into a zone, then Ctrl+=,
  zooms the zone.
- **A zone's lifetime.** The zone and its memory must stay valid from the build that marks the box until the next
  `begin_build`, where the events of that next frame are read.
- **A key that is empty** (a home page that shows no session) has the zone's own zoom, not remembered.
