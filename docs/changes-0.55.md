# gui_toolkit 0.55: what changed, for an application

Notes for an application of the toolkit (Wren, opencode native) moving to 0.55: what is new, what behaves
differently, what to change. `examples/whatsnew` shows each item live (`odin build examples/whatsnew -vet
-out:build/whatsnew.exe -subsystem:windows`, `--page=N` to open on one).

## Changes that need nothing, but show

- **A frame less between input and screen (Direct3D 11).** The renderer takes one of the swap chain latency object's
  counts for good at creation: a frame starts when the last one is on screen instead of queueing behind it. Measured in
  opencode native (RENDER_PROBE, a fast hand over a list, six runs each): 49 ms input to screen before, 34 after, still
  60 frames a second. The price: a frame that takes longer than a refresh waits for the next one (keep frames light: a
  lazy column for long content).
- **Do not show input after a rest at once.** Presenting that frame without a wait for the refresh (and latency 2) left
  the swap chain a frame deeper for the rest of the session: 45 to 60 ms instead of 30, every run. `render.pace_frame`
  does not do it; an application with its own pacing should not either.
- **Emboss direction (Gradient finish themes only).** The engraving of a button's text is chosen by the text against
  what is under it (its background, else the nearest opaque one up, else the theme's `background`), not by the text
  alone. Screenshots of Bootstrap-like themes may change by a pixel on grey text.
- **The wheel moves the hover.** A wheel event makes the pointer position valid again: rolling without moving the mouse,
  the hovered row is the one now under the pointer (it stayed on the row scrolled away). Code that relied on the hover
  not changing while scrolling: none known.
- **WebGPU first frame.** On Direct3D 12 without DXC next to the program the first frame compiles its pipelines with FXC
  (seconds); the renderer presents the background first instead of leaving the window white, and prints a hint on
  stderr when the first frame took over a second with FXC. Ship `dxcompiler.dll` + `dxil.dll` (tools/fetch_wgpu.ps1).
- **Layout warnings on stderr (debug builds).** `ui: layout: <box>: its height is 80% of <ancestor>'s ...`: a `pct()`
  size inside a box sized by its children resolves against a distant ancestor (often the window). Printed once per box,
  only when the result exceeds half the window. On when `ODIN_DEBUG`; `ui.set_layout_warnings(&state, false)` silences
  it. Each one is a real layout bug worth fixing (give the box `px`/`text_size`, or give the parent a size).

## New API

### Frame pacing, ready-made: `render/pacer.odin`

```odin
pacer: render.Pacer              // in the app, one per window
slept: bool                      // set when the loop waited for an event before this frame

at_once := render.pace_frame(&pacer, &r, win, idled = slept, dragging = ui.active_key() != 0)   // before poll_events
events := platform.poll_events(win, false)
// ... build, draw ...
render.frame_end(&r, !at_once)
render.paced_present(&pacer)
```

`inner = true` for a frame made from a loop of the system (`on_frame` during a live resize). It replaces the hand-written
`display_info` / `cadence_adopt` / `frame_decision` / `wait_for_frame` / `set_max_frame_latency` / `cadence_presented`
sequence; opencode native's `pace()` is now one call. Also new, for an application that measures otherwise:

- `platform.input_pending(w) -> bool`: input waits in the queue (polls, keeps the events for the next `poll_events`).
- `platform.event_is_input(kind) -> bool`.

### Lazy column: `ui/lazy.odin`

```odin
ui.next({width = ui.fill(), height = ui.fill()})
if ui.scroll_y("###list") {
    ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
    if ui.column(id = "###col") {
        lz := ui.lazy_begin(all = searching)            // returns ^Lazy
        for m, i in items {
            if ui.lazy_item(lz, fmt.tprintf("###m%s", m.id), always = i == len(items) - 1) {
                item(m)                                  // built in a box of its own: full width, as tall as its content
            }
        }
    }                                                    // the space of the last items skipped is added at the end
}                                                        // of the block lazy_begin was called in
```

Only items near the view (a screen above and below) are built; a run of skipped items is one space of their last
measured heights. An item never built stands as the mean height of those that were; one built at another width keeps
its old height until it comes near the view. When a height changes above the view, the view follows (after the layout,
in the same frame): the first item visible keeps its place on screen. `all = true` builds every item (find in page needs
the text). `always`: an item that grows (streaming) or holds the focus. 5000 wrapped paragraphs: a first frame of 12 ms
(1.4 s when everything was built), 3 ms a frame after, a resize no longer rebuilds them all.

**The trap**: like `row()`, the item is the block of the `if` (`@(deferred_out)`). `if !ui.lazy_item(...) { continue }`
closes the item immediately: it stays empty (height 0), its content lands in the column, and nothing is ever skipped.
Debug builds warn when every built item of a column is empty. opencode native made this mistake; fixed by moving the
item body into a procedure: `if ui.lazy_item(lz, id) { message(app, &m, i) }`. Also: Odin refuses a call with a deferred
procedure inside `||` / `&&`.

Put `lazy_begin` in a block that ends where the list ends (a bare `{ }` if needed), so the trailing space goes before
what follows the list.

### Rich paragraph versions

`ui.rich_paragraph(id, runs, max_lines = 0, version: u64 = 0)`. With `version != 0` the layout cache finds the paragraph
by (box key, version) and skips hashing every run's text each frame. The caller promises: same version, same runs (text
and styles). The toolkit mixes in the box key, so versions need only be unique per box. Change it when the text, the
styles or the font size change. opencode native derives it from where the Markdown block's bytes lie in the message
(`src_version` in markdown.odin: address of the first line, end of the last, the size). `0` keeps the old behaviour.

### `ui.next_merge(m)` and `ui.merge_mod`

`next_merge` adds fields to the pending `next` instead of replacing it: a helper can size and colour its box while the
caller's `width` or `fixed_x/y` stay. Fields already set by the caller win. `merge_mod(a, b)` is public and now merges
every `Style_Mod` field (`b` wins where set; flags are added) — it merged only some before.

### `ui.box_at(ids: ..string) -> ^Box`

The box of the last build at a path of ids from the root (each id as given to `build_box`/`row`/`scroll_y`:
`ui.box_at("###main", "###page", "###content")`), nil when none. Every container on the path needs an id. For tests,
tools, overlays that need a rect from outside a build.

### `ui.layout_warnings() -> []string`, `ui.set_layout_warnings(s, on)`

The messages given so far (temp memory), for a tool or a test.

## Fixed

- **Find in page with a scope no longer built** (a page left while the needle stays) read the freed frame memory of
  that subtree and crashed at the next layout. Such a scope now finds nothing. Still: call `ui.find("")` when the
  search goes away.

## Tests

`tests/{keyboard,status,states,ui_robust,a11y}` now fail to compile without `-define:ODIN_TEST_THREADS=1` (a
`#assert` in `single_thread.odin`): they drive the global UI state, and on several threads they failed with bad frees
or hung. An application test package that uses `ui` state the same way can copy the guard:

```odin
#assert(#config(ODIN_TEST_THREADS, 0) == 1, "run these tests with -define:ODIN_TEST_THREADS=1")
```

## Docs

- docs/pacing.md: the pacer, and why it does not show input after a rest at once.
- docs/font-backend.md: one Rust standard library per program — build `native/text` (and `native/a11y`) into your own
  crate, `-define:FONT_NATIVE_LINK=false`; wgpu-native is prebuilt and cannot join it (Linux:
  `--allow-multiple-definition`; Windows: use Direct3D 11 or build wgpu-native in your workspace).
- docs/text.md: find in page, its theme entries and limits (no match across boxes; text not built is not searched —
  build a lazy column fully while searching; matches arrive one frame after a new needle).
