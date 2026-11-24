# Mermaid diagrams in Markdown

A ````mermaid``` block in any Markdown a program shows is drawn as its diagram. papier and opencode native each laid
out the blocks with `gt:mermaid`, for each theme lightness, and kept the drawings in a cache. The shared layer is in
`gt:markdown`:

- `markdown.Diagrams`: the cache, by the text's hash and the lightness, bounded.
- `View_Options.diagrams`: when set, `view` draws a closed mermaid block as its diagram.
- `markdown.diagram_block`: the same block for a program's own `View_Options.code`.
- `markdown.diagram_view`: a diagram in a `ui.preview` (zoom and pan), for a viewer.

## Decisions

- **The layout is a procedure the program gives (`Diagrams.layout`), usually `mermaid.layout`.** `gt:mermaid` links
  the native library (gt_native). If `markdown` imported `mermaid`, every program that shows Markdown would link it,
  wanted or not, and the markdown tests would need the native library on every system. With a procedure, `markdown`
  imports `svg` only (pure Odin). Dependencies: `markdown` → `svg` → `draw`, `font`, `paint`, `ascii`, `turn`;
  none of them imports `markdown` or `ui`: no cycle.
- **The layout runs on a chore (`ui.task`), never on the interface's thread.** A layout takes milliseconds to tens of
  milliseconds, in proportion to the diagram, and it runs in the native library. Until it answers, the block shows its
  text as a code block. The answer comes at a next build; the task's post wakes the window.
- **One entry per text and lightness.** The key is the FNV-1a hash of the text, with the lightness mixed in. A theme
  change from dark to light lays out again once, then both stay. The lightness is the State's theme's (`Theme.dark`).
- **A bound on the entries (`DIAGRAMS_KEPT` by default).** At the bound, the entry used least recently (by the build
  index) goes. A pending entry never goes: its task writes it. An entry the current build asked for never goes either:
  its box draws it after the build. With more diagrams on the screen than the bound, the cache keeps more for a while.
- **Each entry on the heap.** A box keeps a pointer to the drawing until the frame is drawn, and the map moves its
  values when it grows. A diagram that is not a diagram is kept too, with
  its reason: it is not laid out again at each frame.
- **Only a closed block is laid out.** A block still being written (an answer that streams) changes at each chunk: a
  layout per chunk would be lost work. It shows its text until its fence closes.
- **The cache outlives no task.** Each task holds a reference to a small link to the cache. `diagrams_destroy` cuts the
  link; an answer that comes after it frees its drawing and does nothing else. The link goes with the last reference.
  So a program can destroy the cache while layouts run.
- **The scale.** Mermaid draws its text at 14 px. The diagram is drawn at the text's size (`em / 14`), and never wider
  than its column (the column's width of the last frame: the box keeps its key).
- **The words are the program's.** A block that is no diagram shows its text, as the code block. The reason
  (`Diagram.why`) is for a program that wants to say it.

## Refused

- **A layout at load for both lightnesses** (papier's way). It lays out diagrams that are never shown in a theme, and it
  runs on the loader's thread, which `markdown.view` does not own.
- **The viewer's chrome in `markdown`** (opencode native's direction menu, copy as picture). That is the program's
  layout and words. `diagram_view` gives the zoomed drawing only.
